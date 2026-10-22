script_name('AMARAYTHEN Capter')
script_author('amaru')
script_version('2.2')
script_description('AMARAYTHEN Capter by amaru: синхронный флуд /capture волной. Запуск лидером через /fc.')
-- Совместимость с автообновлением v1.8-v1.9, которые ищут в новом файле прежнее имя.
-- Не удалять: script_name('SF Capture')

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

-- Ростер и лидеры берутся только из общего списка на GitHub (ссылка ниже, менять её
-- может только тот, кто выпускает скрипт). В конфиге moonloader\config\sf_capture.ini
-- хранятся лишь личные настройки игрока. Значения ниже - запасные.

-- ============================ НАСТРОЙКИ ============================
local CFG = {
    -- Общий список: ростер и лидеры.
    roster_url      = 'https://raw.githubusercontent.com/amaru1918/sf-roster/main/sf_roster.txt',
    roster_refresh  = 120,        -- как часто перепроверять список, с (когда нет флуда)
    -- Лидеры, пока общий список ещё ни разу не скачан или в нём нет секции [leaders].
    default_leaders = { 'Escay_Eastwood' },
    -- Автообновление: отсюда скачивается новая версия скрипта.
    update_url      = 'https://raw.githubusercontent.com/amaru1918/sf-roster/main/sf_capture.lua',
    auto_update     = true,
    update_interval = 1800,       -- как часто проверять обновления, с

    chat_cmd          = '/fc',       -- чат управления
    code_prefix       = '#SF',       -- метка служебных сообщений
    debug             = false,       -- то же, что /ac debug
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

local TAG       = '{C9A227}[AMARAYTHEN]{CFCFCF} '
local TAG_COLOR = 0xC9A227

-- Общий список. leaders = nil, если в нём нет секции [leaders].
-- Версия 0 - список ещё ни разу не скачивался.
local roster = { version = 0, list = {}, leaders = nil }

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

-- Действующий список лидеров: только из общего списка на GitHub (или встроенный),
-- поэтому назначить себя лидером у себя в игре нельзя.
local function leaderList()
    return roster.leaders or CFG.default_leaders
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
            msg(string.format('{FF6060}У лидера устаревший список (v%d, у тебя v%d) - пусть наберёт /ac reload.',
                ver, roster.version))
        else
            msg(string.format('{FF6060}Список не совпадает: у лидера v%d, у тебя v%d. Набери /ac reload.',
                ver, roster.version))
        end
        return
    end
    local slot, active = computeSlot()
    if not slot then
        msg('Тебя нет в списке, в этом запуске не участвуешь.')
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
                    ' или не распознан. Включи /ac debug и повтори запуск.')
            else
                msg('{FF6060}Стоп не прошёл в ' .. CFG.chat_cmd ..
                    '. Повтори /ac stop, иначе остальные остановятся по автостопу.')
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
        msg(string.format('У лидера список новее (v%d, у тебя v%d), обновляю...', ver, roster.version))
    else
        dbg(string.format('код от %s с версией v%d, проверяю общий список', sender, ver))
    end
    loadRemoteRoster(false, function()
        if not isLeader(sender) then
            dbg('после обновления списка ' .. sender .. ' всё равно не лидер - игнор')
        elseif roster.version ~= ver then
            msg(string.format('{FF6060}Не удалось получить список v%d, в этом запуске не участвуешь.', ver))
        elseif state.lastStopAt >= receivedAt then
            msg('Пока обновлялся список, лидер уже остановил запуск.')
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
        if ver > roster.version then
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
-- В конфиге только личные настройки игрока. Ростер и лидеры - в общем списке на GitHub.
local function buildConfigText(o)
    local L = {
        '; ============== AMARAYTHEN Capter by amaru - конфиг ==============',
        '; Строки, начинающиеся с ; - комментарии.',
        '; После правки файла набери в игре /ac reload (или перезайди).',
        '; Всё это можно менять и в меню: команда /ac.',
        '; Ники участников и лидеров здесь не хранятся - они берутся из общего списка состава.',
        '',
        '[settings]',
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
        '; Автообновление скрипта (true/false)',
        'auto_update = ' .. tostring(o.auto_update ~= false),
    }
    return table.concat(L, '\n') .. '\n'
end

local function currentSettings()
    return {
        chat_cmd = CFG.chat_cmd, countdown = CFG.default_countdown, max_duration = CFG.max_duration,
        hide_responses = CFG.hide_responses, ping_compensation = CFG.ping_compensation,
        auto_update = CFG.auto_update,
    }
end

local DEFAULT_CONFIG = buildConfigText(currentSettings())

local function configPath()
    return getWorkingDirectory() .. '\\config\\sf_capture.ini'
end

-- obsolete = true, если в файле остались ссылки или списки ников от старых версий
local OBSOLETE_KEYS = { roster_url = true, roster_version = true }

local function parseConfig(content)
    content = content:gsub('^\239\187\191', '') -- BOM, если файл сохранили в UTF-8
    local out = { settings = {}, obsolete = false }
    local section
    for raw in content:gmatch('[^\r\n]+') do
        local line = trim(raw)
        if line ~= '' and not line:find('^[;#]') then
            local sec = line:match('^%[(.-)%]$')
            if sec then
                section = lower(trim(sec))
                if section ~= 'settings' then out.obsolete = true end
            elseif section == 'settings' then
                local k, v = line:match('^([%w_]+)%s*=%s*(.-)$')
                if k then
                    k = lower(k)
                    if OBSOLETE_KEYS[k] then out.obsolete = true else out.settings[k] = trim(v) end
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

    CFG.default_countdown = tonumber(s.countdown) or CFG.default_countdown
    CFG.max_duration      = tonumber(s.max_duration) or CFG.max_duration
    if s.chat_cmd and s.chat_cmd ~= '' then CFG.chat_cmd = s.chat_cmd end
    if s.hide_responses then CFG.hide_responses = lower(s.hide_responses) == 'true' end
    CFG.ping_compensation = lower(s.ping_compensation or 'true') ~= 'false'
    CFG.auto_update       = lower(s.auto_update or 'true') ~= 'false'

    -- конфиг от старой версии: убираем из него ссылки и списки ников, настройки сохраняем
    if c.obsolete then
        local w = io.open(path, 'w')
        if w then
            w:write(buildConfigText(currentSettings()))
            w:close()
            msg('Конфиг очищен от старых ссылок и ников: теперь они берутся из общего списка.')
        end
    end

    -- пока свежий общий список не скачан, берём его сохранённую копию
    if roster.version == 0 then applyCachedRoster() end

    if verbose then msg('Конфиг загружен.') end
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
    dbg('скачиваю список: ' .. url)
    downloadUrlToFile(url, path, function(id, status)
        if status ~= dlstatus.STATUS_ENDDOWNLOADDATA or done or request ~= rosterRequest then return end
        local f = io.open(path, 'r')
        if not f then
            finish(false, verbose and '{FF6060}Не удалось скачать общий список, оставлен сохранённый.' or nil)
            return
        end
        local content = f:read('*a')
        f:close()
        local ver, list, leaders = parseRoster(content)
        if not ver then
            finish(false, verbose and '{FF6060}Общий список в неверном формате, оставлен сохранённый.' or nil)
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
            finish(false, verbose and '{FF6060}Общий список не скачался, оставлен сохранённый. Проверь интернет.' or nil)
        end
    end)
end

-- ------------------------- автообновление --------------------------
-- Метка для проверки кодировки скачанного обновления. Не менять и не удалять
-- (её ищут и уже установленные старые версии):
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
        local isOurs = content:find("script_name('AMARAYTHEN Capter')", 1, true)
            or content:find("script_name('SF Capture')", 1, true)
        if not newVersion or not isOurs then
            finish(verbose and '{FF6060}Файл обновления на GitHub не похож на AMARAYTHEN Capter.' or nil)
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
        if roster.version == 0 then
            msg('{FF6060}Общий список ещё ни разу не скачался - запуск невозможен. Проверь интернет.')
            return
        end
        local line = string.format('%s %s GO %d %d %d', CFG.chat_cmd, CFG.code_prefix, delay, cd, roster.version)
        msg(string.format('Код запуска отправлен в %s (задержка %d мс, отсчёт %d с), жду ответ сервера...',
            CFG.chat_cmd, delay, cd))
        queueLeaderMessage('GO', line, CFG.go_tries)
    end
    -- перед запуском сверяемся с общим списком, чтобы у лидера была последняя версия
    msg('Проверяю список...')
    loadRemoteRoster(false, send, 3000)
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

    -- палитра: насыщенный янтарно-жёлтый неон на тёмном графите
    local C_ACCENT    = V4(1.00, 0.76, 0.03, 1.00) -- основной жёлтый
    local C_ACCENT_HI = V4(1.00, 0.85, 0.28, 1.00)
    local C_NEON_CORE = V4(1.00, 0.95, 0.72, 1.00) -- светлая «сердцевина» неона
    local C_ON_ACCENT = V4(0.07, 0.05, 0.00, 1.00) -- текст на жёлтом
    local C_TEXT      = V4(0.96, 0.96, 0.98, 1.00)
    local C_MUTED     = V4(0.60, 0.62, 0.69, 1.00)
    local C_WINDOW    = V4(0.045, 0.047, 0.06, 0.98)
    local C_PANEL     = V4(0.095, 0.10, 0.125, 1.00)
    local C_PANEL_HI  = V4(0.16, 0.165, 0.20, 1.00)
    local C_BORDER    = V4(0.22, 0.23, 0.29, 1.00)
    local C_GREEN     = V4(0.18, 0.96, 0.46, 1.00)
    local C_RED       = V4(1.00, 0.25, 0.27, 1.00)
    local C_RED_BG    = V4(0.62, 0.09, 0.12, 1.00)

    ui = {
        open      = new.bool(false),
        tab       = 1,
        delay     = new.int(400),
        countdown = new.int(3),
        chatCmd   = new.char[32](),
        defCd     = new.int(3),
        maxDur    = new.int(120),
        hide      = new.bool(false),
        ping      = new.bool(true),
        autoUpd   = new.bool(true),
        debug     = new.bool(false),
        dirty     = false,
        online    = {},
        onlineAt  = -1,
        notice    = nil,
        noticeErr = false,
        noticeAt  = 0,
    }

    -- черновик меню = копия текущих настроек
    syncUi = function()
        imgui.StrCopy(ui.chatCmd, CFG.chat_cmd)
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
        local o = {
            chat_cmd          = chat,
            countdown         = ui.defCd[0],
            max_duration      = ui.maxDur[0],
            hide_responses    = ui.hide[0],
            ping_compensation = ui.ping[0],
            auto_update       = ui.autoUpd[0],
        }
        if not writeConfig(o) then
            setNotice('Не удалось записать sf_capture.ini.', true)
            return
        end
        loadConfig(false)
        setNotice('Сохранено.')
    end

    local TABS = { 'Запуск', 'Список', 'Лидеры', 'Настройки' }
    local F = {}       -- шрифты: body, bold, title, big
    local PAD = 16     -- внутренний отступ окна

    local function u32(c, a)
        return imgui.ColorConvertFloat4ToU32(V4(c.x, c.y, c.z, a or c.w))
    end

    local function withFont(font, fn)
        if font then imgui.PushFont(font) end
        fn()
        if font then imgui.PopFont() end
    end

    local function contentWidth()
        return imgui.GetWindowWidth() - PAD * 2
    end

    -- ------------------------------ неон -------------------------------
    -- Плавное «дыхание» яркости свечения
    local function pulse()
        return 0.82 + 0.18 * math.sin(os.clock() * 2.4)
    end

    -- Свечение вокруг прямоугольника: несколько полупрозрачных слоёв, рисуется ДО элемента
    local function glowRect(p, w, h, color, rounding, strength)
        local dl = imgui.GetWindowDrawList()
        local k = (strength or 1) * pulse()
        for i = 4, 1, -1 do
            local e = i * 2
            dl:AddRectFilled(V2(p.x - e, p.y - e), V2(p.x + w + e, p.y + h + e),
                u32(color, 0.055 * k), rounding + e)
        end
    end

    -- Неоновая надпись: ореол, свечение вокруг букв и светлая сердцевина
    local function neonText(text, core, glow)
        local p = imgui.GetCursorScreenPos()
        local ts = imgui.CalcTextSize(text)
        local k = pulse()
        local dl = imgui.GetWindowDrawList()
        for i = 4, 1, -1 do
            local e = i * 3
            dl:AddRectFilled(V2(p.x - e, p.y - e * 0.5), V2(p.x + ts.x + e, p.y + ts.y + e * 0.5),
                u32(glow, 0.03 * k), ts.y)
        end
        for _, r in ipairs({ 3, 2, 1 }) do
            local a = (0.09 + (3 - r) * 0.07) * k
            for s = 0, 7 do
                local ang = s * math.pi / 4
                imgui.SetCursorScreenPos(V2(p.x + math.cos(ang) * r, p.y + math.sin(ang) * r))
                imgui.TextColored(V4(glow.x, glow.y, glow.z, a), text)
            end
        end
        imgui.SetCursorScreenPos(p)
        imgui.TextColored(core, text)
    end

    local function mutedWrapped(s)
        imgui.PushStyleColor(imgui.Col.Text, C_MUTED)
        imgui.TextWrapped(u8(s))
        imgui.PopStyleColor(1)
    end

    -- «таблетка»: цветная плашка с текстом (и точкой). text уже в UTF-8.
    local function pillWidth(text, dot)
        return imgui.CalcTextSize(text).x + (dot and 26 or 16)
    end

    local function pill(text, color, dot)
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local w, h = pillWidth(text, dot), imgui.GetTextLineHeight() + 6
        dl:AddRectFilled(p, V2(p.x + w, p.y + h), u32(color, 0.16), h / 2)
        local tx = p.x + 8
        if dot then
            local c = V2(p.x + 11, p.y + h / 2)
            dl:AddCircleFilled(c, 7, u32(color, 0.18 * pulse()), 16) -- свечение точки
            dl:AddCircleFilled(c, 3.5, u32(color), 12)
            tx = p.x + 19
        end
        imgui.SetCursorScreenPos(V2(tx, p.y + 3))
        imgui.TextColored(color, text)
        imgui.SetCursorScreenPos(p)
        imgui.Dummy(V2(w, h))
    end

    -- кнопка своего цвета
    local function colorButton(label, w, h, base, hover, textColor)
        imgui.PushStyleColor(imgui.Col.Button, base)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, hover)
        imgui.PushStyleColor(imgui.Col.ButtonActive, hover)
        imgui.PushStyleColor(imgui.Col.Text, textColor or C_TEXT)
        local clicked
        withFont(F.bold, function() clicked = imgui.Button(label, V2(w, h)) end)
        imgui.PopStyleColor(4)
        return clicked
    end

    -- карточка: подложка со скруглением, содержимое с отступом
    local function beginCard(id, h)
        imgui.PushStyleColor(imgui.Col.ChildBg, C_PANEL)
        imgui.BeginChild(id, V2(0, h), false, imgui.WindowFlags.NoScrollbar)
        imgui.SetCursorPos(V2(14, 12))
        imgui.BeginGroup()
    end

    local function endCard()
        imgui.EndGroup()
        imgui.EndChild()
        imgui.PopStyleColor(1)
    end

    local function cardTitle(text)
        withFont(F.bold, function() imgui.TextColored(C_ACCENT, u8(text)) end)
    end

    local function statCard(id, caption, value, color, w)
        imgui.PushStyleColor(imgui.Col.ChildBg, C_PANEL)
        imgui.BeginChild(id, V2(w, 66), false, imgui.WindowFlags.NoScrollbar)
        imgui.SetCursorPos(V2(12, 9))
        imgui.TextDisabled(u8(caption))
        imgui.SetCursorPos(V2(12, 30))
        withFont(F.big, function() imgui.TextColored(color or C_TEXT, u8(value)) end)
        imgui.EndChild()
        imgui.PopStyleColor(1)
    end

    local function sectionTitle(text)
        imgui.Dummy(V2(0, 2))
        withFont(F.bold, function() imgui.TextColored(C_ACCENT, u8(text)) end)
        local p = imgui.GetCursorScreenPos()
        imgui.GetWindowDrawList():AddRectFilled(p, V2(p.x + contentWidth(), p.y + 1), u32(C_BORDER), 0)
        imgui.Dummy(V2(0, 5))
    end

    local function statusInfo()
        if state.phase == 'countdown' then
            return string.format('ОТСЧЁТ %d', math.max(0, math.ceil(state.startAt - os.clock()))), C_ACCENT
        elseif state.phase == 'running' then
            return 'ФЛУД', C_GREEN
        end
        return 'ОЖИДАНИЕ', C_MUTED
    end

    local function rosterOnline(me)
        local active, slot = 0, nil
        for _, n in ipairs(roster.list) do
            if ui.online[norm(n)] then
                if me and norm(n) == norm(me) then slot = active end
                active = active + 1
            end
        end
        return active, slot
    end

    -- ------------------------- шапка и вкладки -------------------------
    local function drawHeader()
        local y0 = imgui.GetCursorPosY()
        withFont(F.title, function()
            neonText('AMARAYTHEN', C_NEON_CORE, C_ACCENT)
            imgui.SameLine(0, 9)
            imgui.TextColored(C_TEXT, 'CAPTER')
        end)
        imgui.TextDisabled(u8('by amaru  ·  v' .. thisScript().version))

        -- состояние справа
        local text, color = statusInfo()
        text = u8(text)
        imgui.SameLine(imgui.GetWindowWidth() - PAD - pillWidth(text, true) - 36)
        imgui.SetCursorPosY(y0 + 4)
        pill(text, color, true)

        -- крестик закрытия
        imgui.SameLine(imgui.GetWindowWidth() - PAD - 26)
        imgui.SetCursorPosY(y0 + 1)
        local p = imgui.GetCursorScreenPos()
        local clicked = imgui.InvisibleButton('##close', V2(26, 26))
        local hovered = imgui.IsItemHovered()
        local dl = imgui.GetWindowDrawList()
        if hovered then dl:AddRectFilled(p, V2(p.x + 26, p.y + 26), u32(C_RED, 0.22), 7) end
        local xc = u32(hovered and C_RED or C_MUTED)
        dl:AddLine(V2(p.x + 8, p.y + 8), V2(p.x + 18, p.y + 18), xc, 2)
        dl:AddLine(V2(p.x + 18, p.y + 8), V2(p.x + 8, p.y + 18), xc, 2)
        if clicked then ui.open[0] = false end

        -- неоновая линия: яркая слева, гаснет к правому краю, со свечением
        imgui.SetCursorPosY(math.max(imgui.GetCursorPosY(), y0 + 50))
        local lp = imgui.GetCursorScreenPos()
        local lw = contentWidth()
        local k = pulse()
        for i = 3, 1, -1 do
            local a = u32(C_ACCENT, 0.09 * k / i)
            local z = u32(C_ACCENT, 0)
            dl:AddRectFilledMultiColor(V2(lp.x, lp.y - i * 1.5), V2(lp.x + lw, lp.y + 2 + i * 1.5), a, z, z, a)
        end
        dl:AddRectFilledMultiColor(lp, V2(lp.x + lw, lp.y + 2),
            u32(C_NEON_CORE), u32(C_ACCENT, 0.15), u32(C_ACCENT, 0.15), u32(C_NEON_CORE))
        imgui.Dummy(V2(0, 10))
    end

    local function drawTabs()
        local W = contentWidth()
        local gap, inner, h = 4, 4, 30
        local bw = (W - inner * 2 - gap * (#TABS - 1)) / #TABS
        local p = imgui.GetCursorScreenPos()
        imgui.GetWindowDrawList():AddRectFilled(p, V2(p.x + W, p.y + h + inner * 2), u32(C_PANEL), 10)
        imgui.SetCursorScreenPos(V2(p.x + inner, p.y + inner))
        for i, name in ipairs(TABS) do
            if i > 1 then imgui.SameLine(0, gap) end
            local active = ui.tab == i
            if active then
                glowRect(imgui.GetCursorScreenPos(), bw, h, C_ACCENT, 7, 0.8)
                imgui.PushStyleColor(imgui.Col.Button, C_ACCENT)
                imgui.PushStyleColor(imgui.Col.ButtonHovered, C_ACCENT_HI)
                imgui.PushStyleColor(imgui.Col.ButtonActive, C_ACCENT_HI)
                imgui.PushStyleColor(imgui.Col.Text, C_ON_ACCENT)
            else
                imgui.PushStyleColor(imgui.Col.Button, V4(0, 0, 0, 0))
                imgui.PushStyleColor(imgui.Col.ButtonHovered, C_PANEL_HI)
                imgui.PushStyleColor(imgui.Col.ButtonActive, C_PANEL_HI)
                imgui.PushStyleColor(imgui.Col.Text, C_MUTED)
            end
            withFont(F.bold, function()
                if imgui.Button(u8(name) .. '##tab' .. i, V2(bw, h)) then ui.tab = i end
            end)
            imgui.PopStyleColor(4)
        end
        imgui.SetCursorScreenPos(V2(p.x, p.y + h + inner * 2))
        imgui.Dummy(V2(0, 6))
    end

    -- ----------------------------- вкладки -----------------------------
    local function drawLaunchTab()
        refreshOnline()
        local me = myNick() or '?'
        local leader = isLeader(me)
        local W = contentWidth()

        -- кто я
        withFont(F.bold, function() imgui.Text(me) end)
        imgui.SameLine(0, 10)
        pill(u8(leader and 'ЛИДЕР' or 'УЧАСТНИК'), leader and C_ACCENT or C_MUTED, false)
        local ptxt = u8(string.format('пинг %d мс', myPing()))
        imgui.SameLine(imgui.GetWindowWidth() - PAD - imgui.CalcTextSize(ptxt).x)
        imgui.TextDisabled(ptxt)
        imgui.Dummy(V2(0, 2))

        -- карточки
        local active, slot = rosterOnline(me)
        local cw = (W - 16) / 3
        statCard('##st1', 'В СЕТИ', string.format('%d / %d', active, #roster.list),
            active > 0 and C_GREEN or C_MUTED, cw)
        imgui.SameLine(0, 8)
        statCard('##st2', 'ТВОЙ СЛОТ', slot and tostring(slot + 1) or '-', slot and C_ACCENT or C_MUTED, cw)
        imgui.SameLine(0, 8)
        statCard('##st3', 'ВЕРСИЯ', roster.version > 0 and ('v' .. roster.version) or '-', C_TEXT, cw)
        imgui.Dummy(V2(0, 2))

        -- что происходит сейчас
        if state.phase == 'countdown' then
            local left = math.max(0, state.startAt - os.clock())
            local total = math.max(0.001, state.startAt - state.codeAt)
            withFont(F.bold, function()
                imgui.TextColored(C_ACCENT, u8(string.format('Старт через %d с  ·  ведёт %s', math.ceil(left), state.leader)))
            end)
            imgui.ProgressBar(1 - left / total, V2(W, 6), '')
        elseif state.phase == 'running' then
            withFont(F.bold, function()
                imgui.TextColored(C_GREEN, u8(string.format('Флуд идёт  ·  отправлено %d  ·  слот %d из %d',
                    state.sent, state.slot + 1, state.active)))
            end)
            imgui.PushStyleColor(imgui.Col.PlotHistogram, C_GREEN)
            local total = math.max(1, state.stopAt - state.startAt)
            imgui.ProgressBar(math.min(1, math.max(0, (os.clock() - state.startAt) / total)), V2(W, 6), '')
            imgui.PopStyleColor(1)
        else
            imgui.TextDisabled(u8(leader and 'Готов к запуску.' or 'Ждём команду лидера.'))
        end
        imgui.Dummy(V2(0, 2))

        local fh = imgui.GetFrameHeightWithSpacing()
        local th = imgui.GetTextLineHeightWithSpacing()
        if leader then
            beginCard('##leader', 12 + th + fh * 2 + th + 8 + 42 + 14)
            cardTitle('ПАНЕЛЬ ЛИДЕРА')
            imgui.PushItemWidth(180)
            if imgui.InputInt(u8'Задержка, мс', ui.delay, 10, 100) then
                ui.delay[0] = math.max(CFG.min_delay, math.min(CFG.max_delay, ui.delay[0]))
            end
            imgui.SliderInt(u8'Отсчёт, с', ui.countdown, 0, 15)
            imgui.PopItemWidth()
            if active > 0 then
                imgui.TextDisabled(u8(string.format('Шаг волны: %d / %d = %.0f мс между %s',
                    ui.delay[0], active, ui.delay[0] / active, CFG.flood_cmd)))
            else
                imgui.TextDisabled(u8'Из списка сейчас никого нет в сети.')
            end
            imgui.Dummy(V2(0, 2))
            local bw = (W - 28 - 8) / 2
            glowRect(imgui.GetCursorScreenPos(), bw, 42, C_ACCENT, 7, 1)
            if colorButton(u8'ЗАПУСТИТЬ', bw, 42, C_ACCENT, C_ACCENT_HI, C_ON_ACCENT) then
                leaderStart(ui.delay[0], ui.countdown[0])
            end
            imgui.SameLine(0, 8)
            if colorButton(u8'СТОП ВСЕМ', bw, 42, C_RED_BG, C_RED, C_TEXT) then
                leaderStop()
            end
            endCard()
        else
            beginCard('##member', 12 + th * 4 + 8 + 38 + 14)
            cardTitle('УЧАСТНИК')
            mutedWrapped('Флуд запускает лидер. Скрипт сам встанет в волну в свою очередь, ' ..
                'а остановить его ты можешь только у себя.')
            imgui.Dummy(V2(0, 2))
            if colorButton(u8'Остановить у себя', W - 28, 38, C_RED_BG, C_RED, C_TEXT) then
                stopFlood('остановлено вручную')
            end
            endCard()
        end

        imgui.Dummy(V2(0, 2))
        ui.debug[0] = CFG.debug
        if imgui.Checkbox(u8'Отладка в чате', ui.debug) then CFG.debug = ui.debug[0] end
    end

    -- строки списка: точка «в сети», номер, ник, метки справа
    local function drawNickRows(list, me, emptyText, height)
        imgui.PushStyleColor(imgui.Col.ChildBg, C_PANEL)
        imgui.BeginChild('##rows' .. ui.tab, V2(0, height), false)
        imgui.Dummy(V2(0, 4))
        if #list == 0 then
            imgui.SetCursorPosX(14)
            imgui.TextDisabled(u8(emptyText))
        end
        local dl = imgui.GetWindowDrawList()
        local rowW = imgui.GetWindowWidth() - 12
        local rowH = imgui.GetTextLineHeight() + 12
        for i, n in ipairs(list) do
            local on = ui.online[norm(n)]
            local isMe = me and norm(n) == norm(me)
            local p = imgui.GetCursorScreenPos()
            local x0 = p.x + 6
            if isMe then
                dl:AddRectFilled(V2(x0, p.y), V2(x0 + rowW, p.y + rowH), u32(C_ACCENT, 0.10), 7)
            end
            dl:AddCircleFilled(V2(x0 + 13, p.y + rowH / 2), 4, on and u32(C_GREEN) or u32(C_MUTED, 0.5), 12)
            imgui.SetCursorScreenPos(V2(x0 + 26, p.y + 6))
            imgui.TextDisabled(tostring(i))
            imgui.SetCursorScreenPos(V2(x0 + 50, p.y + 6))
            imgui.TextColored(on and C_TEXT or C_MUTED, n)

            local badges = {}
            if isLeader(n) then badges[#badges + 1] = { u8'лидер', C_ACCENT } end
            if isMe then badges[#badges + 1] = { u8'ты', C_GREEN } end
            local bx = x0 + rowW - 8
            for _, b in ipairs(badges) do
                bx = bx - pillWidth(b[1], false)
                imgui.SetCursorScreenPos(V2(bx, p.y + 3))
                pill(b[1], b[2], false)
                bx = bx - 6
            end

            imgui.SetCursorScreenPos(p)
            imgui.Dummy(V2(rowW, rowH))
        end
        imgui.EndChild()
        imgui.PopStyleColor(1)
    end

    local function drawListHeader(title, count, total)
        withFont(F.bold, function() imgui.Text(u8(title)) end)
        local txt = u8(string.format('в сети %d из %d', count, total))
        imgui.SameLine(imgui.GetWindowWidth() - PAD - pillWidth(txt, true))
        pill(txt, count > 0 and C_GREEN or C_MUTED, true)
    end

    local function drawRosterTab()
        refreshOnline()
        local me = myNick()
        local active = rosterOnline(me)
        drawListHeader(roster.version > 0 and string.format('Список  ·  v%d', roster.version) or 'Список',
            active, #roster.list)
        mutedWrapped('Порядок в списке - очерёдность в волне. Список общий для состава и обновляется сам.')
        imgui.Dummy(V2(0, 2))
        drawNickRows(roster.list, me, 'Список ещё не загружен.', 318)
        imgui.Dummy(V2(0, 2))
        if imgui.Button(u8'Обновить список', V2(contentWidth(), 32)) then loadRemoteRoster(true) end
    end

    local function drawLeadersTab()
        refreshOnline()
        local me = myNick()
        local list = leaderList()
        local on = 0
        for _, n in ipairs(list) do if ui.online[norm(n)] then on = on + 1 end end
        drawListHeader('Лидеры', on, #list)
        mutedWrapped('Только лидеры могут запускать и останавливать флуд. Список задаётся руководством состава.')
        imgui.Dummy(V2(0, 2))
        drawNickRows(list, me, 'Лидеров нет.', 360)
    end

    local function drawSettingsTab()
        sectionTitle('ЗАПУСК')
        imgui.PushItemWidth(180)
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

        sectionTitle('ПОВЕДЕНИЕ')
        if imgui.Checkbox(u8'Поправка на пинг (рекомендуется)', ui.ping) then ui.dirty = true end
        if imgui.Checkbox(u8'Прятать «будет доступна через несколько секунд»', ui.hide) then ui.dirty = true end

        sectionTitle('ОБНОВЛЕНИЯ')
        if imgui.Checkbox(u8'Автообновление скрипта', ui.autoUpd) then ui.dirty = true end
        imgui.TextDisabled(u8('Установлена версия v' .. thisScript().version))
        imgui.Dummy(V2(0, 2))
        local bw = (contentWidth() - 8) / 2
        if imgui.Button(u8'Проверить обновления', V2(bw, 32)) then
            setNotice('Проверяю обновления...')
            checkForUpdate(true)
        end
        imgui.SameLine(0, 8)
        if imgui.Button(u8'Перечитать конфиг', V2(bw, 32)) then
            if reloadAll() then setNotice('Конфиг перечитан.') end
        end
    end

    local function drawFooter()
        if ui.dirty then
            imgui.Dummy(V2(0, 6))
            mutedWrapped('Есть несохранённые изменения.')
            local bw = (contentWidth() - 8) / 2
            if colorButton(u8'Сохранить', bw, 34, C_ACCENT, C_ACCENT_HI, C_ON_ACCENT) then saveFromUi() end
            imgui.SameLine(0, 8)
            if imgui.Button(u8'Отменить', V2(bw, 34)) then
                syncUi()
                setNotice('Изменения отменены.')
            end
        end
        if ui.notice and os.clock() - ui.noticeAt < 8 then
            imgui.Dummy(V2(0, 4))
            wrappedColored(ui.noticeErr and C_RED or C_GREEN, ui.notice)
        end
    end

    -- ------------------------------ тема -------------------------------
    local function applyTheme()
        local s = imgui.GetStyle()
        local c, col = s.Colors, imgui.Col
        s.WindowPadding     = V2(PAD, 14)
        s.FramePadding      = V2(8, 5)
        s.ItemSpacing       = V2(8, 7)
        s.ItemInnerSpacing  = V2(6, 4)
        s.WindowRounding    = 12
        s.ChildRounding     = 10
        s.FrameRounding     = 7
        s.GrabRounding      = 7
        s.PopupRounding     = 8
        s.ScrollbarSize     = 10
        s.ScrollbarRounding = 8
        s.GrabMinSize       = 12
        s.WindowBorderSize  = 1
        s.ChildBorderSize   = 0
        s.FrameBorderSize   = 0
        c[col.Text]                 = C_TEXT
        c[col.TextDisabled]         = C_MUTED
        c[col.WindowBg]             = C_WINDOW
        c[col.ChildBg]              = C_PANEL
        c[col.PopupBg]              = V4(0.08, 0.085, 0.10, 0.98)
        c[col.Border]               = V4(1.00, 0.76, 0.03, 0.45) -- неоновая рамка окна
        c[col.FrameBg]              = V4(0.14, 0.145, 0.18, 1.00)
        c[col.FrameBgHovered]       = V4(0.19, 0.195, 0.24, 1.00)
        c[col.FrameBgActive]        = V4(0.24, 0.20, 0.08, 1.00)
        c[col.Button]               = V4(0.15, 0.155, 0.19, 1.00)
        c[col.ButtonHovered]        = V4(0.24, 0.21, 0.10, 1.00)
        c[col.ButtonActive]         = V4(0.36, 0.29, 0.06, 1.00)
        c[col.CheckMark]            = C_ACCENT
        c[col.SliderGrab]           = C_ACCENT
        c[col.SliderGrabActive]     = C_ACCENT_HI
        c[col.Separator]            = C_BORDER
        c[col.PlotHistogram]        = C_ACCENT
        c[col.ScrollbarBg]          = V4(0, 0, 0, 0)
        c[col.ScrollbarGrab]        = V4(0.25, 0.255, 0.29, 1.00)
        c[col.ScrollbarGrabHovered] = V4(0.32, 0.325, 0.36, 1.00)
        c[col.ScrollbarGrabActive]  = C_ACCENT
        c[col.TextSelectedBg]       = V4(0.79, 0.64, 0.15, 0.35)
    end

    -- первый найденный шрифт Windows из списка
    local function pickFont(names)
        local dir = getFolderPath(0x14)
        for _, n in ipairs(names) do
            local path = dir .. '\\' .. n
            if doesFileExist(path) then return path end
        end
    end

    imgui.OnInitialize(function()
        local io_ = imgui.GetIO()
        io_.IniFilename = nil
        -- шрифты с кириллицей, иначе вместо русских букв будут знаки вопроса
        local regular = pickFont({ 'segoeui.ttf', 'trebuc.ttf', 'arial.ttf' })
        local bold = pickFont({ 'segoeuib.ttf', 'trebucbd.ttf', 'arialbd.ttf' }) or regular
        if regular then
            local ranges = io_.Fonts:GetGlyphRangesCyrillic()
            io_.Fonts:Clear()
            F.body  = io_.Fonts:AddFontFromFileTTF(regular, 16.0, nil, ranges)
            F.bold  = io_.Fonts:AddFontFromFileTTF(bold, 16.0, nil, ranges)
            F.title = io_.Fonts:AddFontFromFileTTF(bold, 22.0, nil, ranges)
            F.big   = io_.Fonts:AddFontFromFileTTF(bold, 24.0, nil, ranges)
        end
        pcall(applyTheme)
    end)

    imgui.OnFrame(
        function() return ui.open[0] end,
        function(player)
            local sw, sh = getScreenResolution()
            imgui.SetNextWindowPos(V2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, V2(0.5, 0.5))
            imgui.SetNextWindowSize(V2(480, 610), imgui.Cond.Always)
            local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
            if imgui.Begin('AMARAYTHEN Capter##sfmain', ui.open, flags) then
                -- неоновый ореол вокруг окна (рисуется позади всех окон)
                pcall(function()
                    local pos, size = imgui.GetWindowPos(), imgui.GetWindowSize()
                    local bg = imgui.GetBackgroundDrawList()
                    local k = pulse()
                    for i = 6, 1, -1 do
                        local e = i * 3
                        bg:AddRectFilled(V2(pos.x - e, pos.y - e), V2(pos.x + size.x + e, pos.y + size.y + e),
                            u32(C_ACCENT, 0.035 * k), 12 + e)
                    end
                end)
                drawHeader()
                drawTabs()
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
local HELP = '/ac - меню, /ac start <мс> [отсчёт], /ac stop, /ac status, /ac list, /ac reload, /ac update'

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
            msg('Использование: /ac start <задержка мс> [отсчёт с]')
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
        msg(string.format('Ник: %s%s. Список v%d: онлайн %d из %d, твой слот: %s. Состояние: %s.',
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
        msg(string.format('Список v%d (%d):', roster.version, #roster.list))
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

    sampRegisterChatCommand('ac', cmdSf)
    loadConfig(false)
    if roster.version > 0 then
        msg(string.format('v%s загружен. Общий список v%d (%d ников, лидеров %d), проверяю обновления...',
            thisScript().version, roster.version, #roster.list, #leaderList()))
    else
        msg(string.format('v%s загружен, скачиваю общий список...', thisScript().version))
    end
    loadRemoteRoster(true)
    if hasImgui then
        msg('Меню: /ac. ' .. HELP)
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
        if state.phase == 'idle' and not rosterLoading
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
