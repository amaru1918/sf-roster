script_name('SF Capture')
script_author('SF')
script_version('1.8')
script_description('Синхронный флуд /capture волной. Запуск лидером через /fc.')

require 'lib.moonloader'
local sampev   = require 'lib.samp.events'
local vkeys    = require 'vkeys'
local dlstatus = require('moonloader').download_status

-- Меню сделано на mimgui. Если библиотеки нет, скрипт работает через команды.
local hasImgui, imgui = pcall(require, 'mimgui')
local ffi, u8
if hasImgui then
    ffi = require 'ffi'
    local encoding = require 'encoding'
    encoding.default = 'CP1251'
    u8 = encoding.UTF8
end

-- Ники лидеров и ростер, а также основные настройки хранятся в конфиге:
--   moonloader\config\sf_capture.ini
-- Если файла нет, скрипт создаст его сам при первом запуске.
-- Значения ниже - запасные, на случай если в конфиге чего-то не хватает.

-- ============================ НАСТРОЙКИ ============================
local CFG = {
    leaders        = {},          -- из конфига, секция [leaders]
    roster         = {},          -- из конфига, секция [roster]
    nick_notes     = {},          -- комментарии после ников в конфиге
    roster_version = 1,
    roster_url     = '',          -- ссылка, которая реально используется ('' - без ссылки)
    roster_url_cfg = '',          -- что вписано в конфиге
    -- Общий ростер на GitHub. Используется, если в конфиге roster_url пустой.
    default_roster_url = 'https://raw.githubusercontent.com/amaru1918/sf-roster/main/sf_roster.txt',
    -- Автообновление: отсюда скачивается новая версия скрипта.
    update_url      = 'https://raw.githubusercontent.com/amaru1918/sf-roster/main/sf_capture.lua',
    auto_update     = true,
    update_interval = 1800,       -- как часто проверять обновления, с
    -- Лидеры на случай, если в общем списке нет секции [leaders] или он ещё не скачан.
    -- При общем списке лидеры из локального конфига НЕ учитываются.
    default_leaders = { 'Escay_Eastwood' },
    roster_refresh = 120,         -- как часто перепроверять ростер по ссылке, с (когда нет флуда)

    chat_cmd          = '/fc',       -- чат управления
    code_prefix       = '#SF',       -- метка служебных сообщений
    debug             = false,       -- то же, что /sf debug
    flood_cmd         = '/capture',  -- что флудим
    default_countdown = 3,           -- отсчёт до старта, с (если лидер не указал)
    min_delay         = 20,          -- допустимая задержка на игрока, мс
    max_delay         = 10000,
    max_duration      = 120,         -- автостоп через N секунд после старта
    stop_key          = vkeys.VK_END,-- экстренный локальный стоп
    chat_pause        = 0.7,         -- пауза перед сообщением лидера в чат после своего /capture, с
    confirm_timeout   = 1.5,         -- сколько ждать своё сообщение обратно из чата, с
    go_tries          = 2,           -- попыток отправить код запуска
    stop_tries        = 5,           -- попыток отправить стоп

    -- Ответ сервера, после которого флуд останавливается
    stop_patterns = {
        'уже в состоянии войны',
    },
    -- Прятать ли ответы сервера из списка ниже во время флуда (true - прятать)
    hide_responses = false,
    -- Стартовать раньше на свой пинг, чтобы /capture всех доходили до сервера по плану
    ping_compensation = true,
    hide_patterns = {
        'будет доступна через несколько секунд',
    },
}
-- ==================================================================

local TAG       = '{C9A227}[SF]{CFCFCF} '
local TAG_COLOR = 0xC9A227

-- leaders - лидеры из общего списка (nil, если там их нет или используется локальный ростер)
local roster = { version = CFG.roster_version, list = CFG.roster, leaders = nil }

local state = {
    phase     = 'idle',   -- idle | countdown | running
    leader    = nil,
    delay     = 0,        -- мс, интервал у каждого игрока
    startAt   = 0,
    nextSend  = 0,
    stopAt    = 0,
    slot      = 0,
    active    = 0,
    sent      = 0,
    lastShown = -1,
    hideUntil = 0,
    lastSendAt = -10,     -- когда скрипт последний раз что-то отправил на сервер
    lastStopAt = -10,     -- когда пришёл последний стоп от лидера
    codeAt    = 0,        -- когда получен код запуска
    planMs    = 0,        -- через сколько мс после кода мой первый /capture должен быть на сервере
    pingComp  = 0,        -- поправка на пинг, мс
    measured  = true,     -- замер синхрона уже показан
}

local PHASE_NAME = { idle = 'ожидание', countdown = 'отсчёт', running = 'флуд' }

-- ----------------------------- утилиты -----------------------------
local function msg(text)
    sampAddChatMessage(TAG .. text, TAG_COLOR)
end

local function lower(s)
    return (s or ''):lower()
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Ник без учёта регистра и с пробелом вместо '_' (многие сервера пишут "Name Surname")
local function norm(s)
    return (lower(s):gsub('_', ' '))
end

local function dbg(text)
    if not CFG.debug then return end
    msg('{888888}debug: ' .. text)
    print('[debug] ' .. text)
end

local function myNick()
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not ok then return nil end
    return sampGetPlayerNickname(id)
end

-- Свой пинг до сервера, мс (туда и обратно)
local function myPing()
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not ok then return 0 end
    local p = tonumber(sampGetPlayerPing(id)) or 0
    return math.max(0, math.min(1000, p))
end

local function isOnline(nick)
    if not nick then return false end
    local ln = norm(nick)
    local me = myNick()
    if me and norm(me) == ln then return true end
    for id = 0, sampGetMaxPlayerId(false) do
        if sampIsPlayerConnected(id) and norm(sampGetPlayerNickname(id)) == ln then
            return true
        end
    end
    return false
end

-- Действующий список лидеров. При общем ростере по ссылке - только из него (или встроенный),
-- локальный конфиг не учитывается, чтобы никто не мог назначить себя лидером.
local function leaderList()
    if CFG.roster_url ~= '' then
        return roster.leaders or CFG.default_leaders
    end
    return CFG.leaders
end

local function isLeader(nick)
    local ln = norm(nick)
    for _, n in ipairs(leaderList()) do
        if norm(n) == ln then return true end
    end
    return false
end

-- Позиция ника в строке как отдельного слова (обе строки уже через norm)
local function findWord(hay, needle)
    local init = 1
    while true do
        local a, b = hay:find(needle, init, true)
        if not a then return nil end
        local before = a > 1 and hay:sub(a - 1, a - 1) or ''
        local after  = hay:sub(b + 1, b + 1)
        if not before:match('%w') and not after:match('%w') then return a end
        init = b + 1
    end
end

-- Отправитель = игрок, чей ник встречается в строке раньше всех.
-- Не зависит от формата чата и не даёт подделать код, вписав ник лидера в текст.
local function detectSender(head)
    local h = norm(head)
    local bestPos, bestNick
    local function try(nick)
        if not nick or nick == '' then return end
        local p = findWord(h, norm(nick))
        if p and (not bestPos or p < bestPos or (p == bestPos and #nick > #bestNick)) then
            bestPos, bestNick = p, nick
        end
    end
    try(myNick())
    for id = 0, sampGetMaxPlayerId(false) do
        if sampIsPlayerConnected(id) then try(sampGetPlayerNickname(id)) end
    end
    return bestNick
end

-- Мой слот среди тех, кто из ростера сейчас онлайн
local function computeSlot()
    local me = myNick()
    local active, slot = 0, nil
    for _, n in ipairs(roster.list) do
        if isOnline(n) then
            if me and norm(n) == norm(me) then slot = active end
            active = active + 1
        end
    end
    return slot, active
end

-- ------------------------------ флуд -------------------------------
local function stopFlood(reason)
    if state.phase == 'idle' then return end
    local was = state.phase
    state.phase = 'idle'
    state.hideUntil = os.clock() + 2
    if was == 'running' then
        msg(string.format('Стоп: %s. Отправлено %s: %d.', reason, CFG.flood_cmd, state.sent))
    else
        msg('Запуск отменён: ' .. reason .. '.')
    end
end

local loadRemoteRoster  -- объявлены ниже, в разделе "ростер"
local applyCachedRoster

-- codeAt - когда пришёл код запуска (если подключаемся с опозданием после обновления ростера)
local function beginCountdown(leader, delay, cd, ver, codeAt)
    if ver ~= roster.version then
        if ver < roster.version then
            msg(string.format('{FF6060}У лидера устаревший ростер (v%d, у тебя v%d) - пусть наберёт /sf reload.',
                ver, roster.version))
        else
            msg(string.format('{FF6060}Ростер не совпадает: у лидера v%d, у тебя v%d. Набери /sf reload.',
                ver, roster.version))
        end
        return
    end
    local slot, active = computeSlot()
    if not slot then
        msg('Тебя нет в ростере, в этом запуске не участвуешь.')
        return
    end
    delay = math.max(CFG.min_delay, math.min(CFG.max_delay, delay))

    -- Сервер рассылает код всем одновременно. Мой /capture идёт до сервера ещё полпинга,
    -- а код шёл ко мне полпинга, поэтому стартую раньше на весь свой пинг: тогда команды
    -- всех игроков приходят на сервер ровно по плану, независимо от их пинга.
    local now    = codeAt or os.clock()
    local ping   = CFG.ping_compensation and myPing() or 0
    local offset = (delay / 1000) * slot / active
    state.phase     = 'countdown'
    state.leader    = leader
    state.delay     = delay
    state.slot      = slot
    state.active    = active
    state.sent      = 0
    state.codeAt    = now
    state.pingComp  = ping
    state.planMs    = (cd + offset) * 1000
    state.measured  = false
    state.startAt   = now + cd - ping / 1000
    state.nextSend  = state.startAt + offset
    state.stopAt    = now + cd + CFG.max_duration
    state.lastShown = -1

    msg(string.format('Флуд %s от %s: задержка %d мс, слот %d/%d (шаг %.0f мс), старт через %d с, пинг %d мс.',
        CFG.flood_cmd, leader, delay, slot + 1, active, delay / active,
        math.max(0, math.ceil(state.startAt - os.clock())), ping))
end

-- -------------------- сообщения лидера в чат -----------------------
-- Сервер отбрасывает сообщение в чат, если перед ним игрок только что отправил /capture
-- (антифлуд). Поэтому код запуска и стоп уходят после паузы, а если лидер не увидел
-- своё сообщение в чате - отправляются повторно.
local outbox = nil

local function queueLeaderMessage(kind, text, maxTries)
    local now = os.clock()
    outbox = {
        kind = kind, text = text, tries = 0, maxTries = maxTries,
        sendAt = math.max(now, state.lastSendAt + CFG.chat_pause), confirmUntil = nil,
    }
end

-- true, если это подтверждение моего сообщения; второе значение - номер попытки
local function confirmOutbox(kind)
    if outbox and outbox.kind == kind and outbox.tries > 0 then
        local tries = outbox.tries
        outbox = nil
        return true, tries
    end
    return false
end

local function processOutbox(now)
    if not outbox then return end
    if outbox.sendAt and now >= outbox.sendAt then
        outbox.sendAt = nil
        outbox.tries = outbox.tries + 1
        outbox.confirmUntil = now + CFG.confirm_timeout
        state.lastSendAt = now
        dbg(string.format('отправка %s, попытка %d: %s', outbox.kind, outbox.tries, outbox.text))
        sampSendChat(outbox.text)
    elseif outbox.confirmUntil and now > outbox.confirmUntil then
        if outbox.tries < outbox.maxTries then
            outbox.confirmUntil = nil
            outbox.sendAt = now
            dbg(outbox.kind .. ' не вернулся из чата, повторяю')
        else
            local kind = outbox.kind
            outbox = nil
            if kind == 'GO' then
                msg('{FF6060}Код не вернулся из ' .. CFG.chat_cmd ..
                    ' или не распознан. Включи /sf debug и повтори запуск.')
            else
                msg('{FF6060}Стоп не прошёл в ' .. CFG.chat_cmd ..
                    '. Повтори /sf stop, иначе остальные остановятся по автостопу.')
            end
        end
    end
end

-- Разбор служебного кода. Возвращает true, если код распознан (тогда строка скрывается).
-- Формат: "#SF GO <задержка> <отсчёт> <версия ростера>" и "#SF STOP" - без двоеточий,
-- чтобы антиреклама сервера не приняла цифры за IP:порт.
-- Код запуска с более новой версией общего ростера: скачиваем список прямо сейчас.
-- Лидер ли отправитель, решает уже новый список (так подхватываются и новые лидеры),
-- а к волне подключаемся с учётом времени, ушедшего на загрузку.
local lastForeignCatchUp = -100

local function catchUpAndStart(sender, delay, cd, ver)
    local receivedAt = os.clock()
    if isLeader(sender) then
        msg(string.format('У лидера ростер новее (v%d, у тебя v%d), обновляю...', ver, roster.version))
    else
        dbg(string.format('код от %s с версией v%d, проверяю общий список', sender, ver))
    end
    loadRemoteRoster(false, function()
        if not isLeader(sender) then
            dbg('после обновления ростера ' .. sender .. ' всё равно не лидер - игнор')
        elseif roster.version ~= ver then
            msg(string.format('{FF6060}Не удалось получить ростер v%d, в этом запуске не участвуешь.', ver))
        elseif state.lastStopAt >= receivedAt then
            msg('Пока обновлялся ростер, лидер уже остановил запуск.')
        elseif state.phase == 'idle' then
            beginCountdown(sender, delay, cd, ver, receivedAt)
        end
    end)
end

local function handleCode(clean, codePos)
    local head   = clean:sub(1, codePos - 1)
    local rest   = clean:sub(codePos + #CFG.code_prefix)
    local sender = detectSender(head)

    if not sender then
        dbg('код получен, но ник отправителя в строке не найден')
        return false
    end

    local me = myNick()
    local fromMe = me and norm(me) == norm(sender)

    local d, cd, ver = rest:match('^%s+GO%s+(%d+)%s+(%d+)%s+(%d+)')
    if d then
        d, cd, ver = tonumber(d), tonumber(cd), tonumber(ver)
        if CFG.roster_url ~= '' and ver > roster.version then
            -- не лидер по моему списку - обновляемся не чаще раза в 10 с, чтобы нельзя было
            -- заставить всех постоянно качать список
            if not isLeader(sender) then
                if os.clock() - lastForeignCatchUp < 10 then return false end
                lastForeignCatchUp = os.clock()
            end
            if fromMe then confirmOutbox('GO') end
            catchUpAndStart(sender, d, cd, ver)
            return true
        end
        if not isLeader(sender) then
            dbg('код от ' .. sender .. ', он не в списке лидеров - игнор')
            return false
        end
        if fromMe then confirmOutbox('GO') end
        beginCountdown(sender, d, cd, ver)
        return true
    end

    if not isLeader(sender) then
        dbg('код от ' .. sender .. ', он не в списке лидеров - игнор')
        return false
    end
    if rest:match('^%s+STOP') then
        if fromMe then
            local ok, tries = confirmOutbox('STOP')
            if ok then
                msg(tries > 1 and string.format('Стоп доставлен всем (с %d-й попытки).', tries) or 'Стоп доставлен всем.')
            end
        end
        state.lastStopAt = os.clock()
        stopFlood('команда лидера ' .. sender)
        return true
    end
    dbg('код от лидера, но формат не распознан: ' .. rest)
    return false
end

-- ----------------------------- конфиг ------------------------------
local function buildConfigText(o)
    local notes = o.notes or {}
    local L = {
        '; ===================== SF Capture - конфиг =====================',
        '; Строки, начинающиеся с ; - комментарии.',
        '; После правки файла набери в игре /sf reload (или перезайди).',
        '; Всё это можно менять и в меню: команда /sf.',
        '',
        '[settings]',
        '; Версия ростера. Поменял список [roster] - увеличь число на 1',
        '; и раздай этот файл всем участникам. У лидера и у всех она должна совпадать.',
        'roster_version = ' .. o.roster_version,
        '',
        '; Откуда брать ростер:',
        ';   пусто - общий список состава на GitHub (ссылка встроена в скрипт), обновляется сам;',
        ';   своя ссылка на raw-файл - брать оттуда;',
        ';   off - не скачивать, брать список из секции [roster] ниже.',
        'roster_url =' .. (o.roster_url ~= '' and (' ' .. o.roster_url) or ''),
        '',
        '; Чат, через который лидер запускает флуд',
        'chat_cmd = ' .. o.chat_cmd,
        '',
        '; Отсчёт до старта по умолчанию, секунд',
        'countdown = ' .. o.countdown,
        '',
        '; Автостоп через столько секунд после старта',
        'max_duration = ' .. o.max_duration,
        '',
        '; Прятать ли ответ "будет доступна через несколько секунд" во время флуда (true/false)',
        'hide_responses = ' .. tostring(o.hide_responses),
        '',
        '; Поправка на пинг: каждый стартует раньше на свой пинг, чтобы /capture всех',
        '; доходили до сервера по плану, даже если пинг у игроков разный (true/false)',
        'ping_compensation = ' .. tostring(o.ping_compensation ~= false),
        '',
        '; Автообновление скрипта с GitHub (true/false)',
        'auto_update = ' .. tostring(o.auto_update ~= false),
        '',
        '[leaders]',
        '; Кто может запускать и останавливать флуд. По одному нику в строке.',
        '; Учитываются, только если roster_url = off. С общим списком лидеры задаются в нём.',
    }
    for _, n in ipairs(o.leaders) do
        local note = notes['leaders:' .. norm(n)]
        L[#L + 1] = note and (n .. ' ' .. note) or n
    end
    L[#L + 1] = ''
    L[#L + 1] = '[roster]'
    L[#L + 1] = '; Участники волны. По одному нику в строке. Учитываются, только если roster_url = off.'
    L[#L + 1] = '; ПОРЯДОК ДОЛЖЕН БЫТЬ ОДИНАКОВЫМ У ВСЕХ - он определяет очерёдность в волне.'
    for _, n in ipairs(o.roster) do
        local note = notes['roster:' .. norm(n)]
        L[#L + 1] = note and (n .. ' ' .. note) or n
    end
    return table.concat(L, '\n') .. '\n'
end

local DEFAULT_CONFIG = buildConfigText({
    roster_version = 1, roster_url = '', chat_cmd = '/fc', countdown = 3,
    max_duration = 120, hide_responses = false, ping_compensation = true, auto_update = true,
    leaders = { 'Escay_Eastwood' }, roster = { 'Escay_Eastwood' },
})

local function configPath()
    return getWorkingDirectory() .. '\\config\\sf_capture.ini'
end

local function parseConfig(content)
    content = content:gsub('^\239\187\191', '') -- BOM, если файл сохранили в UTF-8
    local out = { settings = {}, leaders = {}, roster = {}, notes = {} }
    local section
    for raw in content:gmatch('[^\r\n]+') do
        local line = trim(raw)
        if line ~= '' and not line:find('^[;#]') then
            local sec = line:match('^%[(.-)%]$')
            if sec then
                section = lower(trim(sec))
            elseif section == 'settings' then
                local k, v = line:match('^([%w_]+)%s*=%s*(.-)$')
                if k then out.settings[lower(k)] = trim(v) end
            elseif section == 'leaders' or section == 'roster' then
                -- всё после ника (через пробел или ;) - комментарий, он сохраняется
                local nick, note = line:match('^([^%s;]+)%s*(.*)$')
                if nick then
                    table.insert(out[section], nick)
                    if note ~= '' then out.notes[section .. ':' .. norm(nick)] = note end
                end
            end
        end
    end
    return out
end

local syncUi = function() end -- заполняется ниже, если есть меню

local function writeConfig(o)
    local dir = getWorkingDirectory() .. '\\config'
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    local f = io.open(configPath(), 'w')
    if not f then return false end
    f:write(buildConfigText(o))
    f:close()
    return true
end

local function loadConfig(verbose)
    local dir = getWorkingDirectory() .. '\\config'
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    local path = configPath()

    local f = io.open(path, 'r')
    if not f then
        local w = io.open(path, 'w')
        if w then
            w:write(DEFAULT_CONFIG)
            w:close()
            msg('Создан конфиг moonloader\\config\\sf_capture.ini.')
        end
        f = io.open(path, 'r')
    end

    local content = f and f:read('*a') or DEFAULT_CONFIG
    if f then f:close() end
    local c = parseConfig(content)
    local s = c.settings

    CFG.roster_version    = tonumber(s.roster_version) or CFG.roster_version
    CFG.roster_url_cfg    = s.roster_url or ''
    if CFG.roster_url_cfg == '' then
        CFG.roster_url = CFG.default_roster_url
    elseif lower(CFG.roster_url_cfg) == 'off' then
        CFG.roster_url = ''
    else
        CFG.roster_url = CFG.roster_url_cfg
    end
    CFG.default_countdown = tonumber(s.countdown) or CFG.default_countdown
    CFG.max_duration      = tonumber(s.max_duration) or CFG.max_duration
    if s.chat_cmd and s.chat_cmd ~= '' then CFG.chat_cmd = s.chat_cmd end
    if s.hide_responses then CFG.hide_responses = lower(s.hide_responses) == 'true' end
    CFG.ping_compensation = lower(s.ping_compensation or 'true') ~= 'false'
    CFG.auto_update       = lower(s.auto_update or 'true') ~= 'false'

    CFG.leaders, CFG.roster, CFG.nick_notes = c.leaders, c.roster, c.notes
    roster.version, roster.list, roster.leaders = CFG.roster_version, CFG.roster, nil
    -- с общим списком сначала берём его сохранённую копию, пока качается свежая
    if CFG.roster_url ~= '' then applyCachedRoster() end

    if CFG.roster_url == '' then
        if #CFG.leaders == 0 then msg('{FF6060}В конфиге нет ни одного лидера (секция [leaders]).') end
        if #CFG.roster == 0 then msg('{FF6060}В конфиге пустой ростер (секция [roster]).') end
    end
    if verbose then
        if CFG.roster_url ~= '' then
            msg('Конфиг загружен, ростер и лидеры берутся из общего списка...')
        else
            msg(string.format('Конфиг загружен: лидеров %d, ростер v%d - %d ников.',
                #CFG.leaders, roster.version, #roster.list))
        end
    end
    syncUi()
end

-- ----------------------------- ростер ------------------------------
-- Формат общего списка:
--   первая строка - версия (1 или v1);
--   [leaders] - кто может запускать флуд (необязательно, иначе встроенные default_leaders);
--   [roster]  - участники волны по порядку. Строки до первой секции тоже считаются ростером.
-- Строки с ; или # в начале - комментарии, всё после ника через пробел или ; - тоже.
local function parseRoster(content)
    content = content:gsub('^\239\187\191', '')
    local ver, list, leaders = nil, {}, nil
    local section = 'roster'
    for raw in content:gmatch('[^\r\n]+') do
        local line = trim(raw)
        if line ~= '' and not line:find('^[;#]') then
            local sec = line:match('^%[(.-)%]$')
            if sec then
                section = lower(trim(sec))
                if section == 'leaders' then leaders = leaders or {} end
            else
                local token = line:match('^([^%s;]+)')
                if not ver then
                    ver = tonumber(token:match('^[vV]?(%d+)$'))
                    if not ver then return nil end
                elseif section == 'leaders' then
                    table.insert(leaders, token)
                elseif section == 'roster' then
                    table.insert(list, token)
                end
            end
        end
    end
    if ver and #list > 0 then return ver, list, leaders end
    return nil
end

-- Последний скачанный общий список хранится у игрока: тогда всё работает,
-- даже если GitHub временно недоступен.
local function rosterCachePath()
    return getWorkingDirectory() .. '\\config\\sf_roster_cache.txt'
end

applyCachedRoster = function()
    local f = io.open(rosterCachePath(), 'r')
    if not f then return false end
    local first = f:read('*l') or ''
    local content = f:read('*a') or ''
    f:close()
    if trim(first) ~= '; source: ' .. CFG.roster_url then return false end
    local ver, list, leaders = parseRoster(content)
    if not ver then return false end
    roster.version, roster.list, roster.leaders = ver, list, leaders
    return true
end

local function saveRosterCache(content)
    local f = io.open(rosterCachePath(), 'w')
    if not f then return end
    f:write('; source: ' .. CFG.roster_url .. '\n' .. content)
    f:close()
end

-- Raw-ссылка Gist с хешем правки (/raw/<40 символов>/) всегда отдаёт ту старую версию.
-- Убираем хеш, чтобы ссылка вела на последнюю правку, и добавляем метку против кэша.
local function rosterDownloadUrl(url)
    url = url:gsub('(/raw/)' .. string.rep('%x', 40) .. '/', '%1')
    return url .. (url:find('?', 1, true) and '&' or '?') .. 'nocache=' .. os.time()
end

local rosterRequest   = 0
local rosterLoading   = false
local rosterCheckedAt = -1000

-- verbose - писать в чат и об успехе, и об ошибках (иначе - только если список изменился).
-- onDone(ok) вызывается по завершении, timeoutMs - сколько ждать ответа.
loadRemoteRoster = function(verbose, onDone, timeoutMs)
    if CFG.roster_url == '' then
        if verbose then
            msg(string.format('Ростер берётся из конфига (v%d, %d ников).', roster.version, #roster.list))
        end
        if onDone then onDone(false) end
        return
    end
    local dir = getWorkingDirectory() .. '\\config'
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    local path = dir .. '\\sf_roster.txt'
    os.remove(path)

    rosterRequest = rosterRequest + 1
    rosterLoading = true
    rosterCheckedAt = os.clock()
    local request, done = rosterRequest, false
    local function finish(ok, text)
        done = true
        rosterLoading = false
        if text then msg(text) end
        if onDone then onDone(ok) end
    end

    local url = rosterDownloadUrl(CFG.roster_url)
    dbg('скачиваю ростер: ' .. url)
    downloadUrlToFile(url, path, function(id, status)
        if status ~= dlstatus.STATUS_ENDDOWNLOADDATA or done or request ~= rosterRequest then return end
        local f = io.open(path, 'r')
        if not f then
            finish(false, verbose and '{FF6060}Не удалось скачать ростер по ссылке, оставлен прежний список.' or nil)
            return
        end
        local content = f:read('*a')
        f:close()
        local ver, list, leaders = parseRoster(content)
        if not ver then
            finish(false, verbose and '{FF6060}Ростер по ссылке в неверном формате, оставлен прежний список.' or nil)
            return
        end
        local changed = ver ~= roster.version
            or table.concat(list, '\n') ~= table.concat(roster.list, '\n')
            or table.concat(leaders or CFG.default_leaders, '\n') ~= table.concat(leaderList(), '\n')
        roster.version, roster.list, roster.leaders = ver, list, leaders
        saveRosterCache(content)
        local info = string.format('v%d, %d ников, лидеров %d.', ver, #list, #leaderList())
        if verbose then
            finish(true, 'Общий список загружен: ' .. info)
        elseif changed then
            finish(true, 'Общий список обновился: ' .. info)
        else
            finish(true)
        end
    end)
    lua_thread.create(function()
        wait(timeoutMs or 10000)
        if not done and request == rosterRequest then
            finish(false, verbose and '{FF6060}Ростер по ссылке не скачался, оставлен прежний список. Проверь интернет.' or nil)
        end
    end)
end

-- ------------------------- автообновление --------------------------
-- Метка для проверки кодировки скачанного обновления. Не менять и не удалять:
-- если файл на GitHub пересохранили не в Windows-1251, этой строки в нём не найдётся.
local UPDATE_MARKER = 'SF-CAPTURE: метка кодировки'

local update = { checking = false, checkedAt = -1e9, pending = nil }

local function versionParts(v)
    local t = {}
    for n in tostring(v or ''):gmatch('%d+') do t[#t + 1] = tonumber(n) end
    return t
end

-- true, если версия a новее b
local function isNewerVersion(a, b)
    local x, y = versionParts(a), versionParts(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end

local function installUpdate(p)
    local f = io.open(thisScript().path, 'wb')
    if not f then
        msg('{FF6060}Не удалось записать обновление: нет доступа к файлу скрипта.')
        return
    end
    f:write(p.content)
    f:close()
    msg(string.format('Скрипт обновлён до v%s, перезапускаюсь...', p.version))
    thisScript():reload()
end

local function checkForUpdate(verbose)
    if update.checking or CFG.update_url == '' then return end
    update.checking = true
    update.checkedAt = os.clock()
    local dir = getWorkingDirectory() .. '\\config'
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    local path = dir .. '\\sf_capture_update.tmp'
    os.remove(path)

    local done = false
    local function finish(text)
        done = true
        update.checking = false
        if text then msg(text) end
    end

    downloadUrlToFile(rosterDownloadUrl(CFG.update_url), path, function(id, status)
        if status ~= dlstatus.STATUS_ENDDOWNLOADDATA or done then return end
        local f = io.open(path, 'rb')
        if not f then
            finish(verbose and '{FF6060}Не удалось проверить обновления: файл не скачался.' or nil)
            return
        end
        local content = f:read('*a')
        f:close()
        os.remove(path)

        local newVersion = content:match("script_version%(%s*'([^']+)'%s*%)")
        if not newVersion or not content:find("script_name('SF Capture')", 1, true) then
            finish(verbose and '{FF6060}Файл обновления на GitHub не похож на SF Capture.' or nil)
            return
        end
        if not isNewerVersion(newVersion, thisScript().version) then
            finish(verbose and ('Обновлений нет, у тебя последняя версия v' .. thisScript().version .. '.') or nil)
            return
        end
        if not content:find(UPDATE_MARKER, 1, true) then
            finish('{FF6060}Обновление v' .. newVersion .. ' пропущено: файл на GitHub в неверной кодировке.')
            return
        end
        local chunk, err = (loadstring or load)(content)
        if not chunk then
            dbg('ошибка в обновлении: ' .. tostring(err))
            finish('{FF6060}Обновление v' .. newVersion .. ' пропущено: в файле ошибка.')
            return
        end
        update.pending = { content = content, version = newVersion }
        finish(string.format('Найдено обновление v%s.%s', newVersion,
            state.phase ~= 'idle' and ' Установлю после флуда.' or ''))
    end)
    lua_thread.create(function()
        wait(15000)
        if not done then
            finish(verbose and '{FF6060}Не удалось проверить обновления: нет ответа от GitHub.' or nil)
        end
    end)
end

-- --------------------------- действия ------------------------------
local function leaderStart(delay, cd)
    local me = myNick() or ''
    -- с локальным списком проверяем сразу, с общим - после его обновления (в send)
    if CFG.roster_url == '' and not isLeader(me) then
        msg('Запускать может только лидер. Твой ник в игре: ' .. (me ~= '' and me or 'не определён') .. '.')
        return
    end
    delay = math.floor(delay)
    if delay < CFG.min_delay or delay > CFG.max_delay then
        msg(string.format('Задержка должна быть от %d до %d мс.', CFG.min_delay, CFG.max_delay))
        return
    end
    cd = math.max(0, math.min(30, math.floor(cd)))

    -- права лидера проверяются по свежему списку: так сразу работают и новые лидеры,
    -- и снятые с лидерства теряют права без ожидания автообновления
    local function send()
        local nick = myNick() or ''
        if not isLeader(nick) then
            msg('Запускать может только лидер. Твой ник в игре: ' .. (nick ~= '' and nick or 'не определён') .. '.')
            return
        end
        local line = string.format('%s %s GO %d %d %d', CFG.chat_cmd, CFG.code_prefix, delay, cd, roster.version)
        msg(string.format('Код запуска отправлен в %s (задержка %d мс, отсчёт %d с), жду ответ сервера...',
            CFG.chat_cmd, delay, cd))
        queueLeaderMessage('GO', line, CFG.go_tries)
    end
    if CFG.roster_url ~= '' then
        -- перед запуском сверяемся с общим списком, чтобы у лидера была последняя версия
        msg('Проверяю ростер...')
        loadRemoteRoster(false, send, 3000)
    else
        send()
    end
end

local function leaderStop()
    if isLeader(myNick() or '') then
        -- у себя сразу: тогда скрипт перестаёт слать /capture и стоп пройдёт антифлуд
        stopFlood('остановлено лидером')
        queueLeaderMessage('STOP', CFG.chat_cmd .. ' ' .. CFG.code_prefix .. ' STOP', CFG.stop_tries)
        msg('Останавливаю всех...')
    else
        stopFlood('остановлено вручную')
    end
end

local function reloadAll()
    if state.phase ~= 'idle' then
        msg('Сначала дождись конца флуда или останови его.')
        return false
    end
    loadConfig(true)
    loadRemoteRoster(true)
    return true
end

-- ------------------------------ меню -------------------------------
local ui
if hasImgui then
    local new = imgui.new
    local V2, V4 = imgui.ImVec2, imgui.ImVec4

    local C_ACCENT = V4(0.79, 0.64, 0.15, 1.00)
    local C_GREEN  = V4(0.45, 0.85, 0.45, 1.00)
    local C_GREY   = V4(0.55, 0.55, 0.55, 1.00)
    local C_RED    = V4(0.95, 0.40, 0.40, 1.00)

    ui = {
        open      = new.bool(false),
        tab       = 1,
        delay     = new.int(400),
        countdown = new.int(3),
        addRoster = new.char[32](),
        addLeader = new.char[32](),
        chatCmd   = new.char[32](),
        url       = new.char[256](),
        defCd     = new.int(3),
        maxDur    = new.int(120),
        hide      = new.bool(false),
        ping      = new.bool(true),
        autoUpd   = new.bool(true),
        debug     = new.bool(false),
        roster    = {},
        leaders   = {},
        dirty     = false,
        online    = {},
        onlineAt  = -1,
        notice    = nil,
        noticeErr = false,
        noticeAt  = 0,
    }

    -- черновик меню = копия текущего конфига
    syncUi = function()
        ui.roster, ui.leaders = {}, {}
        for i, n in ipairs(CFG.roster) do ui.roster[i] = n end
        for i, n in ipairs(CFG.leaders) do ui.leaders[i] = n end
        imgui.StrCopy(ui.chatCmd, CFG.chat_cmd)
        imgui.StrCopy(ui.url, CFG.roster_url_cfg)
        ui.defCd[0]     = CFG.default_countdown
        ui.maxDur[0]    = CFG.max_duration
        ui.hide[0]      = CFG.hide_responses
        ui.ping[0]      = CFG.ping_compensation
        ui.autoUpd[0]   = CFG.auto_update
        ui.countdown[0] = CFG.default_countdown
        ui.dirty        = false
    end

    local function setNotice(text, isErr)
        ui.notice, ui.noticeErr, ui.noticeAt = text, isErr and true or false, os.clock()
    end

    local function textColored(color, s)
        imgui.TextColored(color, u8(s))
    end

    local function wrappedColored(color, s)
        imgui.PushStyleColor(imgui.Col.Text, color)
        imgui.TextWrapped(u8(s))
        imgui.PopStyleColor(1)
    end

    -- кто онлайн: обновляется раз в полсекунды, чтобы не грузить игру
    local function refreshOnline()
        local now = os.clock()
        if now - ui.onlineAt < 0.5 then return end
        ui.onlineAt = now
        local set = {}
        local me = myNick()
        if me then set[norm(me)] = true end
        for id = 0, sampGetMaxPlayerId(false) do
            if sampIsPlayerConnected(id) then set[norm(sampGetPlayerNickname(id))] = true end
        end
        ui.online = set
    end

    local function listHas(list, nick)
        for _, n in ipairs(list) do
            if norm(n) == norm(nick) then return true end
        end
        return false
    end

    local function sameList(a, b)
        return table.concat(a, '\n') == table.concat(b, '\n')
    end

    -- ник или ID игрока -> ник
    local function resolveNickInput(text)
        text = trim(text)
        if text == '' then return nil, 'Введи ник или ID игрока.' end
        if text:match('^%d+$') then
            local id = tonumber(text)
            local ok, myid = sampGetPlayerIdByCharHandle(PLAYER_PED)
            if ok and id == myid then return myNick() end
            if sampIsPlayerConnected(id) then return sampGetPlayerNickname(id) end
            return nil, 'Игрока с ID ' .. id .. ' нет на сервере.'
        end
        if not text:match('^[%w_%.%[%]%(%)%$@=]+$') then
            return nil, 'В нике недопустимые символы.'
        end
        return text
    end

    local function saveFromUi()
        if state.phase ~= 'idle' then
            setNotice('Во время флуда сохранять нельзя.', true)
            return
        end
        local chat = trim(ffi.string(ui.chatCmd))
        if not chat:match('^/%S+$') then
            setNotice('Чат управления должен быть командой, например /fc.', true)
            return
        end
        if lower(trim(ffi.string(ui.url))) == 'off' and #ui.leaders == 0 then
            setNotice('Нужен хотя бы один лидер.', true)
            return
        end
        local rosterChanged  = not sameList(ui.roster, CFG.roster)
        local leadersChanged = not sameList(ui.leaders, CFG.leaders)
        local o = {
            roster_version = CFG.roster_version + (rosterChanged and 1 or 0),
            roster_url     = trim(ffi.string(ui.url)),
            chat_cmd       = chat,
            countdown      = ui.defCd[0],
            max_duration   = ui.maxDur[0],
            hide_responses = ui.hide[0],
            ping_compensation = ui.ping[0],
            auto_update    = ui.autoUpd[0],
            leaders        = ui.leaders,
            roster         = ui.roster,
            notes          = CFG.nick_notes,
        }
        if not writeConfig(o) then
            setNotice('Не удалось записать sf_capture.ini.', true)
            return
        end
        loadConfig(false)
        loadRemoteRoster(true)
        if rosterChanged or leadersChanged then
            setNotice(string.format('Сохранено, ростер v%d. Раздай sf_capture.ini всем участникам.', roster.version))
        else
            setNotice('Сохранено.')
        end
    end

    local TABS = { 'Запуск', 'Ростер', 'Лидеры', 'Настройки' }

    local function drawTabs()
        for i, name in ipairs(TABS) do
            if i > 1 then imgui.SameLine() end
            local active = ui.tab == i
            if active then imgui.PushStyleColor(imgui.Col.Button, C_ACCENT) end
            if imgui.Button(u8(name) .. '##tab' .. i, V2(101, 26)) then ui.tab = i end
            if active then imgui.PopStyleColor(1) end
        end
    end

    local function drawLaunchTab()
        refreshOnline()
        local me = myNick() or '?'
        local leader = isLeader(me)

        imgui.Text(u8('Ник: ') .. me)
        if leader then
            imgui.SameLine()
            textColored(C_ACCENT, '(лидер)')
        end

        if state.phase == 'idle' then
            imgui.Text(u8'Состояние: ожидание')
        elseif state.phase == 'countdown' then
            textColored(C_ACCENT, string.format('Состояние: отсчёт, старт через %d с',
                math.max(0, math.ceil(state.startAt - os.clock()))))
        else
            textColored(C_GREEN, string.format('Состояние: флуд идёт, отправлено %s: %d', CFG.flood_cmd, state.sent))
        end
        if state.phase ~= 'idle' then
            imgui.TextWrapped(u8(string.format('Лидер %s, задержка %d мс, слот %d из %d',
                state.leader, state.delay, state.slot + 1, state.active)))
        end

        local active, slot = 0, nil
        for _, n in ipairs(roster.list) do
            if ui.online[norm(n)] then
                if norm(n) == norm(me) then slot = active end
                active = active + 1
            end
        end
        imgui.TextWrapped(u8(string.format('Ростер v%d: в сети %d из %d, твой слот: %s',
            roster.version, active, #roster.list, slot and tostring(slot + 1) or 'нет')))

        imgui.Separator()
        if leader then
            imgui.PushItemWidth(160)
            if imgui.InputInt(u8'Задержка, мс', ui.delay, 10, 100) then
                ui.delay[0] = math.max(CFG.min_delay, math.min(CFG.max_delay, ui.delay[0]))
            end
            imgui.SliderInt(u8'Отсчёт, с', ui.countdown, 0, 15)
            imgui.PopItemWidth()
            if active > 0 then
                imgui.TextDisabled(u8(string.format('Шаг волны: %d / %d = %.0f мс между %s',
                    ui.delay[0], active, ui.delay[0] / active, CFG.flood_cmd)))
            end
            imgui.Spacing()
            if imgui.Button(u8'ЗАПУСТИТЬ', V2(205, 36)) then
                leaderStart(ui.delay[0], ui.countdown[0])
            end
            imgui.SameLine()
            if imgui.Button(u8'ОСТАНОВИТЬ ВСЕХ', V2(205, 36)) then
                leaderStop()
            end
        else
            imgui.TextWrapped(u8'Флуд запускает лидер. Остановить его ты можешь только у себя.')
            if imgui.Button(u8'Остановить у себя', V2(205, 32)) then
                stopFlood('остановлено вручную')
            end
        end

        imgui.Separator()
        ui.debug[0] = CFG.debug
        if imgui.Checkbox(u8'Отладка: показывать строки с кодом в чате', ui.debug) then
            CFG.debug = ui.debug[0]
        end
    end

    -- список ников: online-статус, перестановка и удаление
    local function drawNickList(list, id, editable, reorder)
        imgui.BeginChild('##list' .. id, V2(0, 200), true)
        if #list == 0 then imgui.TextDisabled(u8'Список пуст') end
        local move, remove
        for i, n in ipairs(list) do
            local on = ui.online[norm(n)]
            imgui.Text(string.format('%2d.', i))
            imgui.SameLine()
            imgui.TextColored(on and C_GREEN or C_GREY, n)
            imgui.SameLine(215)
            textColored(on and C_GREEN or C_GREY, on and 'в сети' or 'не в сети')
            if editable then
                if reorder then
                    imgui.SameLine(318)
                    if imgui.Button('^##u' .. id .. i, V2(24, 0)) and i > 1 then move = { i, i - 1 } end
                    imgui.SameLine()
                    if imgui.Button('v##d' .. id .. i, V2(24, 0)) and i < #list then move = { i, i + 1 } end
                end
                imgui.SameLine(378)
                if imgui.Button('X##x' .. id .. i, V2(24, 0)) then remove = i end
            end
        end
        imgui.EndChild()
        if move then
            list[move[1]], list[move[2]] = list[move[2]], list[move[1]]
            ui.dirty = true
        end
        if remove then
            table.remove(list, remove)
            ui.dirty = true
        end
    end

    local function drawAddRow(list, buf, id)
        imgui.PushItemWidth(200)
        imgui.InputText('##add' .. id, buf, ffi.sizeof(buf))
        imgui.PopItemWidth()
        imgui.SameLine()
        if imgui.Button(u8'Добавить##' .. id, V2(100, 0)) then
            local nick, err = resolveNickInput(ffi.string(buf))
            if not nick then
                setNotice(err, true)
            elseif listHas(list, nick) then
                setNotice(nick .. ' уже в списке.', true)
            else
                table.insert(list, nick)
                imgui.StrCopy(buf, '')
                ui.dirty = true
                setNotice('Добавлен ' .. nick .. '. Не забудь сохранить.')
            end
        end
        imgui.TextDisabled(u8'Можно ввести ник или ID игрока на сервере.')
    end

    local function drawRosterTab()
        refreshOnline()
        if CFG.roster_url ~= '' then
            imgui.TextWrapped(u8(string.format('Ростер v%d, %d ников. Порядок в списке = очерёдность в волне.',
                roster.version, #roster.list)))
            wrappedColored(C_ACCENT, 'Список общий и обновляется сам по ссылке. Менять его нужно в репозитории на GitHub.')
            drawNickList(roster.list, 'remote', false, false)
            if imgui.Button(u8'Обновить сейчас', V2(205, 26)) then loadRemoteRoster(true) end
            return
        end
        imgui.TextWrapped(u8(string.format('Ростер v%d. Порядок в списке = очерёдность в волне, у всех он должен быть одинаковым.',
            CFG.roster_version)))
        local editable = state.phase == 'idle'
        drawNickList(ui.roster, 'roster', editable, true)
        if editable then drawAddRow(ui.roster, ui.addRoster, 'roster') end
    end

    local function drawLeadersTab()
        refreshOnline()
        if CFG.roster_url ~= '' then
            imgui.TextWrapped(u8'Лидеры могут запускать и останавливать флуд.')
            wrappedColored(C_ACCENT, roster.leaders
                and 'Лидеры задаются в общем списке на GitHub (секция [leaders]). Здесь их изменить нельзя.'
                or 'В общем списке нет секции [leaders] - действуют лидеры, встроенные в скрипт.')
            drawNickList(leaderList(), 'remoteleaders', false, false)
            return
        end
        imgui.TextWrapped(u8'Лидеры могут запускать и останавливать флуд. Список должен совпадать у всех, иначе команду лидера не примут.')
        local editable = state.phase == 'idle'
        drawNickList(ui.leaders, 'leaders', editable, false)
        if editable then drawAddRow(ui.leaders, ui.addLeader, 'leaders') end
    end

    local function drawSettingsTab()
        imgui.PushItemWidth(170)
        if imgui.InputText(u8'Чат управления', ui.chatCmd, ffi.sizeof(ui.chatCmd)) then ui.dirty = true end
        if imgui.InputInt(u8'Отсчёт по умолчанию, с', ui.defCd, 1, 5) then
            ui.defCd[0] = math.max(0, math.min(30, ui.defCd[0]))
            ui.dirty = true
        end
        if imgui.InputInt(u8'Автостоп через, с', ui.maxDur, 10, 60) then
            ui.maxDur[0] = math.max(10, math.min(600, ui.maxDur[0]))
            ui.dirty = true
        end
        imgui.PopItemWidth()
        if imgui.Checkbox(u8'Прятать «будет доступна через несколько секунд»', ui.hide) then ui.dirty = true end
        if imgui.Checkbox(u8'Поправка на пинг (рекомендуется)', ui.ping) then ui.dirty = true end
        if imgui.Checkbox(u8'Автообновление скрипта', ui.autoUpd) then ui.dirty = true end
        imgui.SameLine()
        if imgui.Button(u8'Проверить сейчас', V2(150, 0)) then
            setNotice('Проверяю обновления (у тебя v' .. thisScript().version .. ')...')
            checkForUpdate(true)
        end
        imgui.Spacing()
        imgui.Text(u8'Ссылка на ростер:')
        imgui.PushItemWidth(-1)
        if imgui.InputText('##url', ui.url, ffi.sizeof(ui.url)) then ui.dirty = true end
        imgui.PopItemWidth()
        imgui.TextDisabled(u8'Пусто - общий список с GitHub (встроен в скрипт).')
        imgui.TextDisabled(u8'off - не скачивать, брать список из вкладки «Ростер».')
        imgui.TextWrapped(u8('Сейчас: ' .. (CFG.roster_url ~= '' and CFG.roster_url or 'список из конфига')))
    end

    local function drawFooter()
        imgui.Separator()
        if ui.dirty then
            if not sameList(ui.roster, CFG.roster) then
                wrappedColored(C_ACCENT, string.format('Есть несохранённые изменения. После сохранения ростер станет v%d.',
                    CFG.roster_version + 1))
            else
                wrappedColored(C_ACCENT, 'Есть несохранённые изменения.')
            end
            if imgui.Button(u8'Сохранить в конфиг', V2(205, 28)) then saveFromUi() end
            imgui.SameLine()
            if imgui.Button(u8'Отменить', V2(205, 28)) then
                syncUi()
                setNotice('Изменения отменены.')
            end
        else
            if imgui.Button(u8'Перечитать конфиг', V2(205, 28)) then
                if reloadAll() then setNotice('Конфиг перечитан.') end
            end
            imgui.SameLine()
            if imgui.Button(u8'Закрыть', V2(205, 28)) then ui.open[0] = false end
        end
        if ui.notice and os.clock() - ui.noticeAt < 8 then
            wrappedColored(ui.noticeErr and C_RED or C_GREEN, ui.notice)
        end
    end

    local function applyTheme()
        local style = imgui.GetStyle()
        local c, col = style.Colors, imgui.Col
        style.WindowRounding   = 6.0
        style.FrameRounding    = 4.0
        style.ChildRounding    = 4.0
        style.WindowTitleAlign = V2(0.5, 0.5)
        c[col.Text]             = V4(0.92, 0.92, 0.92, 1.00)
        c[col.TextDisabled]     = V4(0.55, 0.55, 0.55, 1.00)
        c[col.WindowBg]         = V4(0.10, 0.10, 0.11, 0.97)
        c[col.ChildBg]          = V4(0.13, 0.13, 0.14, 1.00)
        c[col.Border]           = V4(0.30, 0.30, 0.31, 1.00)
        c[col.FrameBg]          = V4(0.20, 0.20, 0.21, 1.00)
        c[col.FrameBgHovered]   = V4(0.27, 0.27, 0.28, 1.00)
        c[col.FrameBgActive]    = V4(0.32, 0.32, 0.33, 1.00)
        c[col.TitleBg]          = V4(0.16, 0.16, 0.17, 1.00)
        c[col.TitleBgActive]    = V4(0.20, 0.20, 0.21, 1.00)
        c[col.Button]           = V4(0.24, 0.24, 0.25, 1.00)
        c[col.ButtonHovered]    = V4(0.55, 0.45, 0.12, 1.00)
        c[col.ButtonActive]     = V4(0.79, 0.64, 0.15, 1.00)
        c[col.CheckMark]        = V4(0.79, 0.64, 0.15, 1.00)
        c[col.SliderGrab]       = V4(0.70, 0.57, 0.14, 1.00)
        c[col.SliderGrabActive] = V4(0.79, 0.64, 0.15, 1.00)
        c[col.Separator]        = V4(0.30, 0.30, 0.31, 1.00)
        c[col.TextSelectedBg]   = V4(0.55, 0.45, 0.12, 0.60)
    end

    imgui.OnInitialize(function()
        local io_ = imgui.GetIO()
        io_.IniFilename = nil
        -- шрифт с кириллицей, иначе вместо русских букв будут знаки вопроса
        local fonts = getFolderPath(0x14)
        local font = fonts .. '\\trebucbd.ttf'
        if not doesFileExist(font) then font = fonts .. '\\arial.ttf' end
        if doesFileExist(font) then
            local ranges = io_.Fonts:GetGlyphRangesCyrillic()
            io_.Fonts:Clear()
            io_.Fonts:AddFontFromFileTTF(font, 15.0, nil, ranges)
        end
        pcall(applyTheme)
    end)

    imgui.OnFrame(
        function() return ui.open[0] end,
        function(player)
            local sw, sh = getScreenResolution()
            imgui.SetNextWindowPos(V2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, V2(0.5, 0.5))
            imgui.SetNextWindowSize(V2(450, 480), imgui.Cond.FirstUseEver)
            if imgui.Begin('SF Capture v' .. thisScript().version .. '##sfmain', ui.open, imgui.WindowFlags.NoCollapse) then
                drawTabs()
                imgui.Separator()
                if ui.tab == 1 then
                    drawLaunchTab()
                elseif ui.tab == 2 then
                    drawRosterTab()
                elseif ui.tab == 3 then
                    drawLeadersTab()
                else
                    drawSettingsTab()
                end
                drawFooter()
            end
            imgui.End()
        end
    )
end

local function menuOpen()
    return ui ~= nil and ui.open[0]
end

-- ----------------------------- команды -----------------------------
local HELP = '/sf - меню, /sf start <мс> [отсчёт], /sf stop, /sf status, /sf list, /sf reload, /sf update'

local function cmdSf(arg)
    local cmd, a1, a2 = (arg or ''):match('^%s*(%S*)%s*(%S*)%s*(%S*)')
    cmd = lower(cmd)
    local me = myNick() or ''

    if cmd == '' or cmd == 'menu' then
        if ui then
            ui.open[0] = not ui.open[0]
        else
            msg('Меню недоступно: не установлена библиотека mimgui. Команды работают.')
            msg(HELP)
        end

    elseif cmd == 'start' then
        local delay = tonumber(a1)
        if not delay then
            msg('Использование: /sf start <задержка мс> [отсчёт с]')
            return
        end
        leaderStart(delay, tonumber(a2) or CFG.default_countdown)

    elseif cmd == 'stop' then
        leaderStop()

    elseif cmd == 'debug' then
        CFG.debug = not CFG.debug
        msg('Отладка ' .. (CFG.debug and 'включена: строки с кодом будут показаны как есть.' or 'выключена.'))

    elseif cmd == 'status' then
        local slot, active = computeSlot()
        msg(string.format('Ник: %s%s. Ростер v%d: онлайн %d из %d, твой слот: %s. Состояние: %s.',
            me ~= '' and me or '?', isLeader(me) and ' (лидер)' or '',
            roster.version, active, #roster.list, slot and tostring(slot + 1) or 'нет',
            PHASE_NAME[state.phase]))
        if state.phase ~= 'idle' then
            msg(string.format('Лидер %s, задержка %d мс, слот %d/%d, отправлено %d.',
                state.leader, state.delay, state.slot + 1, state.active, state.sent))
        end

    elseif cmd == 'list' then
        local leaders = leaderList()
        msg('Лидеры: ' .. (#leaders > 0 and table.concat(leaders, ', ') or 'нет'))
        msg(string.format('Ростер v%d (%d):', roster.version, #roster.list))
        local line = ''
        for i, n in ipairs(roster.list) do
            local item = string.format('%d. %s%s', i, n, isOnline(n) and '' or ' (офф)')
            if line ~= '' and #line + #item > 100 then msg(line) line = '' end
            line = line == '' and item or (line .. ', ' .. item)
        end
        if line ~= '' then msg(line) end

    elseif cmd == 'reload' then
        reloadAll()

    elseif cmd == 'update' then
        msg('Проверяю обновления... (текущая версия v' .. thisScript().version .. ')')
        checkForUpdate(true)

    else
        msg(HELP)
    end
end

-- -------------------------- серверный чат --------------------------
function sampev.onServerMessage(color, text)
    local clean = text:gsub('{%x%x%x%x%x%x}', '')

    local codePos = clean:find(CFG.code_prefix, 1, true)
    if codePos then
        dbg('строка с кодом: ' .. (text:gsub('{', '(')))
        if handleCode(clean, codePos) then
            return false -- распознанный код не показываем
        end
        return -- нераспознанную строку оставляем в чате
    end

    -- Замер синхрона по первому ответу сервера на мой /capture. Считается по часам игры
    -- от момента получения кода, поэтому не зависит от часов на компьютере.
    if state.phase == 'running' and state.sent > 0 and not state.measured then
        local isResponse = false
        for _, p in ipairs(CFG.stop_patterns) do
            if clean:find(p, 1, true) then isResponse = true end
        end
        for _, p in ipairs(CFG.hide_patterns) do
            if clean:find(p, 1, true) then isResponse = true end
        end
        if isResponse then
            state.measured = true
            local actual = (os.clock() - state.codeAt) * 1000
            msg(string.format('Синхрон: отклонение %+d мс (сервер ответил через %d мс после кода, по плану %d).',
                math.floor(actual - state.planMs + 0.5), math.floor(actual + 0.5), math.floor(state.planMs + 0.5)))
        end
    end

    if state.phase ~= 'idle' then
        for _, p in ipairs(CFG.stop_patterns) do
            if clean:find(p, 1, true) then
                stopFlood('фракция уже в состоянии войны')
                return
            end
        end
    end

    if CFG.hide_responses and (state.phase ~= 'idle' or os.clock() < state.hideUntil) then
        for _, p in ipairs(CFG.hide_patterns) do
            if clean:find(p, 1, true) then return false end
        end
    end
end

-- ESC закрывает меню
function onWindowMessage(m, wparam, lparam)
    if (m == 0x100 or m == 0x104) and wparam == vkeys.VK_ESCAPE and menuOpen() and not isPauseMenuActive() then
        consumeWindowMessage(true, false)
        ui.open[0] = false
    end
end

-- ------------------------------ main -------------------------------
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand('sf', cmdSf)
    loadConfig(false)
    if CFG.roster_url ~= '' then
        msg(string.format('v%s загружен. Общий список v%d (%d ников, лидеров %d), проверяю обновления...',
            thisScript().version, roster.version, #roster.list, #leaderList()))
    else
        msg(string.format('v%s загружен: лидеров %d, ростер v%d - %d ников.',
            thisScript().version, #CFG.leaders, roster.version, #roster.list))
    end
    loadRemoteRoster(true)
    if hasImgui then
        msg('Меню: /sf. ' .. HELP)
    else
        msg('{FF6060}mimgui не найдена - меню недоступно, работают команды.')
        msg(HELP)
    end

    local lastLeaderCheck = 0
    while true do
        wait(0)
        local now = os.clock()

        processOutbox(now)

        -- автообновление: только когда нет флуда и лидер ничего не ждёт из чата
        if state.phase == 'idle' and not outbox then
            if update.pending then
                local p = update.pending
                update.pending = nil
                installUpdate(p)
            elseif CFG.auto_update and not update.checking
                and now - update.checkedAt > CFG.update_interval then
                checkForUpdate(false)
            end
        end

        -- общий ростер перепроверяется сам, пока нет флуда
        if CFG.roster_url ~= '' and state.phase == 'idle' and not rosterLoading
            and now - rosterCheckedAt > CFG.roster_refresh then
            loadRemoteRoster(false)
        end

        if state.phase ~= 'idle' then
            if isKeyJustPressed(CFG.stop_key) and not sampIsChatInputActive()
                and not sampIsDialogActive() and not menuOpen() then
                stopFlood('локальная остановка клавишей')
            elseif now - lastLeaderCheck > 1 then
                lastLeaderCheck = now
                if not isOnline(state.leader) then
                    stopFlood('лидер вышел из игры')
                end
            end
        end

        if state.phase == 'countdown' then
            local left = math.ceil(state.startAt - now)
            if left > 0 and left ~= state.lastShown then
                state.lastShown = left
                printStringNow('~y~CAPTURE ~w~' .. left, 1000)
            end
            if now >= state.startAt then
                state.phase = 'running'
                printStringNow('~y~CAPTURE ~g~GO', 1000)
            end
        end

        if state.phase == 'running' then
            if now >= state.stopAt then
                stopFlood('лимит времени ' .. CFG.max_duration .. ' с')
            elseif now >= state.nextSend then
                sampSendChat(CFG.flood_cmd)
                state.sent = state.sent + 1
                state.lastSendAt = now
                local step = state.delay / 1000
                repeat
                    state.nextSend = state.nextSend + step
                until state.nextSend > now
            end
        end
    end
end
