-- Combined Attendance + TreasurePool addon for Ashita v4
-- Provides: /odddrop attendance now -> save CSV, optional Discord webhook
--           /odddrop treasurepool show -> save CSV of pool, optional Discord webhook

addon.name    = 'OddDrop'
addon.author  = 'combined'
addon.version = '0.3'
addon.desc    = 'Combined attendance logger and treasure pool viewer with CSV + optional Discord webhook'

require('common')
local chat = require('chat')

-- Settings
local settings = {
    webhook_url  = 'Discord_WEBHOOK_ID/WEBHOOK_TOKEN', -- set your Discord webhook URL here
    save_csv     = true, -- set to true to enable CSV saving
    post_discord = false, -- set to true to enable Discord posting
    auto         = true, -- set to true to enable automatic saving
    log_filename = 'odddrop.csv', -- single shared log file
}

-- Autosave state
local prev_party_sig = ''
local prev_pool_sig  = ''
local last_auto_time = 0
local auto_min_interval = 3 -- seconds between autosave checks/actions

-- Minimal jobs table
local jobs = {
    [0] = { id = 0, en = '---' }, [1] = { id = 1, en = 'WAR' }, [2] = { id = 2, en = 'MNK' },
    [3] = { id = 3, en = 'WHM' }, [4] = { id = 4, en = 'BLM' }, [5] = { id = 5, en = 'RDM' },
    [6] = { id = 6, en = 'THF' }, [7] = { id = 7, en = 'PLD' }, [8] = { id = 8, en = 'DRK' },
    [9] = { id = 9, en = 'BST' }, [10] = { id = 10, en = 'BRD' }, [11] = { id = 11, en = 'RNG' },
    [12] = { id = 12, en = 'SAM' }, [13] = { id = 13, en = 'NIN' }, [14] = { id = 14, en = 'DRG' },
    [15] = { id = 15, en = 'SMN' }, [16] = { id = 16, en = 'BLU' }, [17] = { id = 17, en = 'COR' },
    [18] = { id = 18, en = 'PUP' }, [19] = { id = 19, en = 'DNC' }, [20] = { id = 20, en = 'SCH' },
    [21] = { id = 21, en = 'GEO' }, [22] = { id = 22, en = 'RUN' }
}

-- Helpers
local function job_name(id)
    if jobs[id] and jobs[id].en then return jobs[id].en end
    return '---'
end

local function ensure_dir(path)
    local ok = pcall(function() ashita.fs.create_dir(path) end)
    if not ok then
        pcall(function() os.execute('mkdir "' .. path .. '" >NUL 2>&1') end)
    end
end

local function logs_path()
    local path = (AshitaCore:GetInstallPath() or '') .. '\\addons\\odddrop\\logs\\'
    ensure_dir(path)
    return path
end

local function csv_escape(s)
    s = tostring(s or '')
    if s:find('[,"\r\n]') then
        s = '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

local function write_csv(filename, lines)
    local full = logs_path() .. filename
    local fh, err = io.open(full, 'a')
    if not fh then
        print(chat.header(addon.name):append(chat.error('Could not open file: ' .. tostring(err))))
        return false
    end
    for _, ln in ipairs(lines) do
        fh:write(ln .. '\n')
    end
    fh:close()
    print(chat.header(addon.name):append(chat.message('Wrote CSV: ' .. full)))
    return true
end

local function json_escape(s)
    s = tostring(s or '')
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\r', '\\r'):gsub('\n', '\\n')
    return s
end

local function post_discord_webhook(content)
    if not settings.post_discord or not settings.webhook_url or settings.webhook_url:match('WEBHOOK_ID') then
        print(chat.header(addon.name):append(chat.message('Discord posting disabled or webhook not set.')))
        return false
    end
    local ok, http  = pcall(require, 'socket.http')
    local ok2, ltn12 = pcall(require, 'ltn12')
    if not ok or not ok2 then
        print(chat.header(addon.name):append(chat.error('LuaSocket/http not available; cannot post webhook.')))
        return false
    end
    local payload = '{"content":"' .. json_escape(content) .. '"}'
    local response_body = {}
    local _, code = http.request{
        url = settings.webhook_url,
        method = 'POST',
        headers = {
            ['Content-Type']   = 'application/json',
            ['Content-Length'] = tostring(#payload),
        },
        source = ltn12.source.string(payload),
        sink   = ltn12.sink.table(response_body),
    }
    if code and (code >= 200 and code < 300) then
        print(chat.header(addon.name):append(chat.message('Posted to Discord webhook.')))
        return true
    else
        print(chat.header(addon.name):append(chat.error('Failed to post webhook. code=' .. tostring(code))))
        return false
    end
end

local function resolve_zone_name(zoneid)
    local zonestr = tostring(zoneid or '')
    local resources = AshitaCore:GetResourceManager()
    if resources and resources.GetZoneNameByIndex then
        pcall(function() zonestr = resources:GetZoneNameByIndex(zoneid) end)
    end
    return zonestr
end

-- Build a compact signature of the current party/alliance for change detection.
local function build_party_signature()
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then return '' end
    local t = {}
    for i = 0, 17 do
        if party:GetMemberIsActive(i) ~= 0 then
            local n  = party:GetMemberName(i) or ''
            local mj = tonumber(party:GetMemberMainJob(i)) or 0
            local sj = tonumber(party:GetMemberSubJob(i)) or 0
            local ml = tonumber(party:GetMemberMainJobLevel(i)) or 0
            local sl = tonumber(party:GetMemberSubJobLevel(i)) or 0
            table.insert(t, string.format('%s:%d.%d/%d.%d', n, mj, ml, sj, sl))
        end
    end
    table.sort(t)
    return table.concat(t, ';')
end

-- Treasure pool fetch (detailed for display).
local function get_treasure_pool()
    local pool = {}
    local resources = AshitaCore:GetResourceManager()
    local inventory = AshitaCore:GetMemoryManager():GetInventory()
    if not inventory then return pool end
    for i = 0, 9 do
        local titem = inventory:GetTreasurePoolItem(i)
        if titem ~= nil and titem.ItemId ~= nil and titem.ItemId ~= 0 then
            local rItem = nil
            if resources and resources.GetItemById then
                pcall(function() rItem = resources:GetItemById(titem.ItemId) end)
            end
            local name = (rItem and rItem.Name and rItem.Name[1]) or ('ItemId:' .. tostring(titem.ItemId))
            table.insert(pool, { Name = name, item = titem })
        end
    end
    table.sort(pool, function(a, b)
        local at = (a.item and a.item.DropTime) or 0
        local bt = (b.item and b.item.DropTime) or 0
        if at == bt then return ((a.item and a.item.ItemId) or 0) < ((b.item and b.item.ItemId) or 0) end
        return at < bt
    end)
    return pool
end

-- Compact treasure pool signature for change detection.
local function build_pool_signature()
    local pool = get_treasure_pool()
    if #pool == 0 then return '' end
    local t = {}
    for _, v in ipairs(pool) do
        local id     = (v.item and v.item.ItemId) or 0
        local lot    = (v.item and v.item.WinningLot) or 0
        local winner = (v.item and v.item.WinningEntityName) or ''
        local dt     = (v.item and v.item.DropTime) or 0
        table.insert(t, string.format('%d|%d|%s|%d', id, lot, winner, dt))
    end
    return table.concat(t, ';')
end

-- Attendance logging -> shared logfile
local function do_attendance_now()
    local party = AshitaCore:GetMemoryManager():GetParty()
    if not party then
        print(chat.header(addon.name):append(chat.error('Could not get party info')))
        return
    end
    local logdate = os.date('%Y-%m-%d')
    local logtime = os.date('%H:%M:%S')
    local utc_offset = os.date('%z')
    local lines = {}
    for i = 1, 18 do
        local idx = i - 1
        if party:GetMemberIsActive(idx) ~= 0 then
            local charactername = party:GetMemberName(idx) or ''
            local zone = party:GetMemberZone(idx) or 0
            local mainjob = job_name(party:GetMemberMainJob(idx))
            local subjob  = job_name(party:GetMemberSubJob(idx))
            local mainlvl = ''
            local sublvl  = ''
            if mainjob ~= '---' then mainlvl = tostring(party:GetMemberMainJobLevel(idx) or '') end
            if subjob  ~= '---' then sublvl  = tostring(party:GetMemberSubJobLevel(idx) or '') end
            local jobstr = mainjob .. (mainlvl ~= '' and tostring(mainlvl) or '') .. '/' .. subjob .. (sublvl ~= '' and tostring(sublvl) or '')
            local zonestr = resolve_zone_name(zone)
            local row = table.concat({
                csv_escape('ATT'),
                csv_escape(charactername),
                csv_escape(jobstr),
                csv_escape(logdate),
                csv_escape(logtime),
                csv_escape('UTC' .. utc_offset),
                csv_escape(zonestr)
            }, ',')
            print(chat.header(addon.name):append(chat.message('[ATT] ' .. charactername .. ', ' .. jobstr .. ', ' .. logdate .. ' ' .. logtime .. ', UTC' .. utc_offset .. ', ' .. zonestr)))
            table.insert(lines, row)
        end
    end
    if settings.save_csv and #lines > 0 then
        write_csv(settings.log_filename, lines)
    end
    if settings.post_discord and #lines > 0 then
        local content = 'Attendance log (' .. logdate .. ' ' .. logtime .. '):\n' .. table.concat(lines, '\n')
        post_discord_webhook(content)
    end
end

-- Treasure pool display -> shared logfile
local function do_treasurepool_show()
    local pool = get_treasure_pool()
    if #pool == 0 then
        print(chat.header(addon.name):append(chat.message('Treasure pool empty')))
        return
    end
    local lines = {}
    for i, v in ipairs(pool) do
        local timeRem = '-'
        if v.item and v.item.DropTime then timeRem = tostring(v.item.DropTime) end
        local lot = (v.item and v.item.WinningLot and v.item.WinningLot > 0) and ((v.item.WinningEntityName or '') .. ':' .. tostring(v.item.WinningLot)) or ''
        local line = table.concat({
            csv_escape('TRES'),
            csv_escape(tostring(i)),
            csv_escape(v.Name),
            csv_escape(lot),
            csv_escape(timeRem)
        }, ',')
        print(chat.header(addon.name):append(chat.message('[TRES] ' .. tostring(i) .. ', ' .. v.Name .. ', ' .. lot .. ', ' .. timeRem)))
        table.insert(lines, line)
    end
    if settings.save_csv and #lines > 0 then
        write_csv(settings.log_filename, lines)
    end
    if settings.post_discord and #lines > 0 then
        local content = 'Treasure Pool:\n' .. table.concat(lines, '\n')
        post_discord_webhook(content)
    end
end

-- Autosave loop
local function autosave_tick()
    if not settings.auto then return end
    local now = os.time()
    if last_auto_time ~= 0 and (now - last_auto_time) < auto_min_interval then
        return
    end
    last_auto_time = now

    local party_sig = build_party_signature()
    if party_sig ~= prev_party_sig then
        prev_party_sig = party_sig
        if party_sig ~= '' then
            do_attendance_now()
        end
    end

    local pool_sig = build_pool_signature()
    if pool_sig ~= prev_pool_sig then
        prev_pool_sig = pool_sig
        if pool_sig ~= '' then
            do_treasurepool_show()
        end
    end
end

-- Commands
ashita.events.register('command','odddrop_command', function(e)
    local args = e.command:args()
    if #args == 0 then return end
    local cmd = args[1]:lower()
    if cmd ~= '/od' and cmd ~= '/odddrop' and cmd ~= '/odd' then
        return
    end
    e.blocked = true
    if #args >= 2 then
        local sub = args[2]:lower()
        if sub == 'log' then
            do_attendance_now()
            do_treasurepool_show()
            return
        elseif sub == 'att' or sub == 'attendance' then
            do_attendance_now()
            return
        elseif sub == 'tres' or sub == 'treasure' or sub == 'treasurepool' then
            do_treasurepool_show()
            return
        elseif sub == 'auto' then
            settings.auto = not settings.auto
            print(chat.header(addon.name):append(chat.message('Auto-save is now ' .. (settings.auto and 'ENABLED' or 'DISABLED'))))
            if settings.auto then
                prev_party_sig = ''
                prev_pool_sig  = ''
                last_auto_time = 0
            end
            return
        elseif sub == 'help' then
            print(chat.header(addon.name):append(chat.message('Commands:')))
            print(chat.header(addon.name):append(chat.message('/od log         - Save attendance + treasure pool')))
            print(chat.header(addon.name):append(chat.message('/od att         - Save attendance')))
            print(chat.header(addon.name):append(chat.message('/od tres        - Save treasure pool')))
            print(chat.header(addon.name):append(chat.message('/od auto        - Toggle autosave (PT/Alliance names + treasure pool drops)')))
            print(chat.header(addon.name):append(chat.message('Set settings.log_filename to choose the shared CSV file.')))
            print(chat.header(addon.name):append(chat.message('Edit webhook in the addon file to enable Discord posting.')))
            return
        end
    end
    print(chat.header(addon.name):append(chat.message('Usage: /od help')))
end)

-- Load/unload
ashita.events.register('load','odddrop_load', function()
    logs_path()
end)

ashita.events.register('unload','odddrop_unload', function() end)

-- Frame tick for autosave
ashita.events.register('d3d_present', 'odddrop_present', function()
    autosave_tick()
end)

-- End of addon
