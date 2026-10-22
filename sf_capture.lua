script_name('AMARAYTHEN Capter')
script_author('amaru')
script_version('2.9')
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
    -- Репозиторий, где лежат общий список (ростер и лидеры) и сам скрипт для автообновления.
    github          = { owner = 'amaru1918', repo = 'sf-roster', branch = 'main' },
    roster_path     = 'sf_roster.txt',
    script_path     = 'sf_capture.lua',
    roster_refresh  = 600,        -- как часто перепроверять список, с (когда нет флуда); реже - бережём лимит API GitHub
    sync_cooldown   = 5,          -- не чаще раза в N секунд выполнять «обновить у всех»
    -- Лидеры, пока общий список ещё ни разу не скачан или в нём нет секции [leaders].
    default_leaders = { 'Escay_Eastwood' },
    auto_update     = true,
    update_interval = 1800,       -- как часто проверять обновления, с

    -- Автоопределение участников: кто со скриптом и в сети, тот и в волне.
    -- Лидеры при этом по-прежнему берутся с GitHub, а GitHub-ростер - запасной.
    auto_discovery  = true,
    scan_wait       = 2.6,        -- сколько лидер собирает отклики перед запуском, с
    presence_ttl    = 90,         -- сколько секунд ник считается «в сети со скриптом»
    hi_jitter       = 0.8,        -- случайная задержка отклика, чтобы не было всплеска в чате, с
    hi_confirm      = 1.2,        -- сколько ждать свой отклик обратно из чата, прежде чем повторить, с
    hi_tries        = 2,          -- попыток отправить отклик
    -- При входе в игру: участник один раз отмечается в чате, лидер один раз сканирует.
    -- Так игроки со скриптом сами появляются в списке у лидеров.
    announce_on_join = true,
    announce_delay   = { 6, 15 }, -- через сколько секунд после появления в игре (случайно в этих пределах)
    max_participants = 30,        -- предел участников в одном коде запуска (лимит длины чата)

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

-- Прямая ссылка на список (по ней же подписана сохранённая копия списка у игрока)
CFG.roster_url = string.format('https://raw.githubusercontent.com/%s/%s/%s/%s',
    CFG.github.owner, CFG.github.repo, CFG.github.branch, CFG.roster_path)

local TAG       = '{C9A227}[AMARAYTHEN]{CFCFCF} '
local TAG_COLOR = 0xC9A227

-- Общий список. leaders = nil, если в нём нет секции [leaders].
-- Версия 0 - список ещё ни разу не скачивался. fetchedAt - когда последний раз скачан.
local roster = { version = 0, list = {}, leaders = nil, fetchedAt = nil }

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

-- Короткие отметки о ключевых шагах в moonloader.log: если игра упадёт,
-- по последним строкам лога будет видно, на каком шаге это случилось.
local function trace(text)
    print('[trace] ' .. text)
end

-- Свой персонаж уже в игре? До спавна функции SAMPFUNCS для своего игрока
-- небезопасны, поэтому ник/ID/пинг до этого не запрашиваются.
local function localReady()
    if not isSampAvailable() then return false end
    if sampIsLocalPlayerSpawned and not sampIsLocalPlayerSpawned() then return false end
    return true
end

local function myNick()
    if not localReady() then return nil end
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not ok then return nil end
    return sampGetPlayerNickname(id)
end

-- Свой пинг до сервера, мс (туда и обратно)
local function myPing()
    if not localReady() then return 0 end
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

-- «Отпечаток» списка: короткая строка, которая меняется при любой правке ников или лидеров.
-- Лидер отправляет её в коде запуска, и каждый сразу видит, совпадает ли его список.
local B36 = '0123456789abcdefghijklmnopqrstuvwxyz'

local function listHash()
    local s = lower(table.concat(leaderList(), ',') .. '|' .. table.concat(roster.list, ','))
    local h = 7
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    local out = ''
    repeat
        local r = h % 36
        out = B36:sub(r + 1, r + 1) .. out
        h = math.floor(h / 36)
    until h == 0
    return out
end

-- Совпадает ли мой список с лидерским (по отпечатку, а у старых версий - по номеру)
local function listMatches(ver, hash)
    if hash and hash ~= '' then return hash == listHash() end
    return ver == roster.version
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

-- Мой слот среди тех, кто из GitHub-ростера сейчас онлайн (запасной режим)
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

-- Мой игровой ID на сервере
local function myId()
    if not localReady() then return nil end
    local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    return ok and id or nil
end

-- ------------------- присутствие (кто со скриптом) -----------------
-- Заполняется, когда приходит отклик #SF HI или любой служебный код от игрока со скриптом.
-- Хранится всю сессию: кто отметился и сейчас в сети, тот в списке.
local presence = {}        -- [норм.ник] = { nick = ник, at = время, ver = версия скрипта или nil }
local lastScanInfo = nil   -- { at, count } - результат последнего сканирования
local lastScanSeenAt = -1000 -- когда в чате последний раз было сканирование от лидера

-- ver - версия из отклика (v2.9+); старые версии её не присылают
local function recordPresence(nick, ver)
    if not nick or nick == '' then return end
    local k = norm(nick)
    local old = presence[k]
    presence[k] = { nick = nick, at = os.clock(), ver = ver or (old and old.ver) }
end

local function presenceOf(nick)
    return presence[norm(nick)]
end

-- Не ответил на последнее сканирование: оно было после его последней отметки, и время на ответ вышло
local function missedScan(p)
    return p.at < lastScanSeenAt and os.clock() - lastScanSeenAt > CFG.scan_wait + 1
end

-- Кто сейчас на сервере: [норм.ник] = ID. Один проход по игрокам вместо поиска для каждого ника.
-- Свой ник тоже в таблице (до спавна ID может быть неизвестен, тогда -1).
local function onlineMap()
    local map = {}
    for id = 0, sampGetMaxPlayerId(false) do
        if sampIsPlayerConnected(id) then map[norm(sampGetPlayerNickname(id))] = id end
    end
    local me = myNick()
    if me then map[norm(me)] = myId() or -1 end
    return map
end

-- Другие игроки со скриптом (без меня), которые в сети и отметились не раньше since
-- (по умолчанию - за последние presence_ttl секунд)
local function presentNicks(map, since)
    map = map or onlineMap()
    since = since or (os.clock() - CFG.presence_ttl)
    local out = {}
    local me = myNick()
    for _, p in pairs(presence) do
        local isMe = me and norm(p.nick) == norm(me)
        if not isMe and p.at >= since and map[norm(p.nick)] then out[#out + 1] = p.nick end
    end
    table.sort(out, function(a, b) return lower(a) < lower(b) end)
    return out
end

-- Для списка в меню: все, кто отмечался в этой сессии и сейчас в сети (без меня).
-- Возвращает два списка: на связи и не ответившие на последнее сканирование.
local function knownNicks(map)
    map = map or onlineMap()
    local live, missed = {}, {}
    local me = myNick()
    for _, p in pairs(presence) do
        local isMe = me and norm(p.nick) == norm(me)
        if not isMe and map[norm(p.nick)] then
            if missedScan(p) then missed[#missed + 1] = p.nick else live[#live + 1] = p.nick end
        end
    end
    local function byNick(a, b) return lower(a) < lower(b) end
    table.sort(live, byNick)
    table.sort(missed, byNick)
    return live, missed
end

-- Игроки из списка состава на GitHub, которые в сети, но не отметились (с момента since, если задан):
-- у них нет скрипта, он старый, не скачался список лидеров или отклик не дошёл
local function silentRosterNicks(map, since)
    map = map or onlineMap()
    local out = {}
    local me = myNick()
    for _, n in ipairs(roster.list) do
        local isMe = me and norm(n) == norm(me)
        local p = presenceOf(n)
        local answered = p and (not since or p.at >= since)
        if not isMe and not answered and map[norm(n)] then out[#out + 1] = n end
    end
    return out
end

-- Ник с версией скрипта для чата: "Nick_Name 2.9" (версию присылают только v2.9+)
local function nickWithVer(nick)
    local p = presenceOf(nick)
    return (p and p.ver) and (nick .. ' ' .. p.ver) or nick
end

-- Список ников в чат, по нескольку на строку (строка чата SA-MP ограничена по длине)
local function msgNicks(title, nicks)
    local line = title
    for i, n in ipairs(nicks) do
        local piece = (i == 1 and ' ' or ', ') .. n
        if #line + #piece > 105 then
            msg(line .. (i > 1 and ',' or ''))
            line = '   ' .. n
        else
            line = line .. piece
        end
    end
    msg(line)
end

-- Итог сканирования в чат лидеру: кто отозвался (с версиями) и кто из списка состава молчит
local function scanReport(since)
    local map = onlineMap()
    local present = presentNicks(map, since)
    msg(string.format('Со скриптом в сети: %d (включая тебя).', #present + 1))
    if #present > 0 then
        local labels = {}
        for i, n in ipairs(present) do labels[i] = nickWithVer(n) end
        msgNicks('Отозвались:', labels)
    end
    local silent = silentRosterNicks(map, since)
    if #silent > 0 then
        msgNicks(string.format('{FFB040}Из списка состава в сети, но молчат (%d):{CFCFCF}', #silent), silent)
        msg('Причины: нет скрипта, версия старее 2.4 или у них не скачался список лидеров с GitHub.')
        msg('Проверь у них /ac - вкладка «Лидеры»: если тебя там нет, дело в списке.')
    end
    return #present + 1
end

-- Текущий игровой ID по нику (ник со временем мог сменить ID)
local function idByNick(nick)
    local me = myNick()
    if me and norm(me) == norm(nick) then return myId() end
    for id = 0, sampGetMaxPlayerId(false) do
        if sampIsPlayerConnected(id) and norm(sampGetPlayerNickname(id)) == norm(nick) then return id end
    end
    return nil
end

-- Список ID участников для кода запуска: я + присутствующие, по возрастанию ID.
-- Возвращает строку "id1.id2..." и число участников (может быть обрезан по max_participants).
local function buildParticipantIds(since)
    local ids, seen = {}, {}
    local function add(id) if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    add(myId())
    for _, nick in ipairs(presentNicks(nil, since)) do add(idByNick(nick)) end
    table.sort(ids)
    local trimmed = false
    if #ids > CFG.max_participants then
        while #ids > CFG.max_participants do table.remove(ids) end
        trimmed = true
    end
    local parts = {}
    for _, id in ipairs(ids) do parts[#parts + 1] = tostring(id) end
    return table.concat(parts, '.'), #ids, trimmed
end

-- Мой слот среди присутствующих по строке ID из кода запуска.
-- Возвращает slot (0-based) и число участников, или nil если меня нет в наборе.
local function computeSlotFromIds(idstr)
    local mine = myId()
    local active, slot = 0, nil
    for id in idstr:gmatch('%d+') do
        id = tonumber(id)
        if mine and id == mine then slot = active end
        active = active + 1
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

-- Общая настройка волны по готовым слоту и числу участников.
-- codeAt - когда пришёл код запуска (если подключаемся с опозданием).
local function startWave(leader, delay, cd, slot, active, codeAt)
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

-- Запасной режим: слот по GitHub-ростеру. Совпадение списков проверяется до вызова.
local function beginCountdown(leader, delay, cd, codeAt)
    local slot, active = computeSlot()
    if not slot then
        msg('Тебя нет в списке, в этом запуске не участвуешь.')
        return
    end
    startWave(leader, delay, cd, slot, active, codeAt)
end

-- Авто-режим: слот по строке ID участников от лидера (одинаковой у всех).
local function beginCountdownAuto(leader, delay, cd, idstr, codeAt)
    local slot, active = computeSlotFromIds(idstr)
    if not slot then
        msg('Тебя нет среди участников этого запуска (нет отклика на сканирование).')
        return
    end
    startWave(leader, delay, cd, slot, active, codeAt)
end

-- -------------------- сообщения лидера в чат -----------------------
-- Сервер отбрасывает сообщение в чат, если перед ним игрок только что отправил /capture
-- (антифлуд). Поэтому код запуска и стоп уходят после паузы, а если лидер не увидел
-- своё сообщение в чате - отправляются повторно.
local outbox = nil

-- after - необязательная функция, вызывается, когда сообщение вернулось из чата (подтвердилось)
local function queueLeaderMessage(kind, text, maxTries, after)
    local now = os.clock()
    outbox = {
        kind = kind, text = text, tries = 0, maxTries = maxTries, after = after,
        sendAt = math.max(now, state.lastSendAt + CFG.chat_pause), confirmUntil = nil,
    }
end

-- true, если это подтверждение моего сообщения; второе значение - номер попытки
local function confirmOutbox(kind)
    if outbox and outbox.kind == kind and outbox.tries > 0 then
        local tries, after = outbox.tries, outbox.after
        outbox = nil
        if after then after() end
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
            elseif kind == 'SYNC' then
                msg('{FF6060}Команда обновления не прошла в ' .. CFG.chat_cmd .. '. Повтори /ac sync.')
            elseif kind == 'SCAN' then
                msg('{FF6060}Сканирование не прошло в ' .. CFG.chat_cmd .. '. Повтори запуск.')
            else
                msg('{FF6060}Стоп не прошёл в ' .. CFG.chat_cmd ..
                    '. Повтори /ac stop, иначе остальные остановятся по автостопу.')
            end
        end
    end
end

-- Отклик на сканирование: сообщаю, что я со скриптом, и свою версию. С разбросом по времени,
-- чтобы отклики всех не легли в чат одним всплеском (антифлуд сервера).
-- Если свой отклик не вернулся из чата (сервер его не пропустил), отправляю ещё раз.
-- Каждое сканирование получает свой ответ (иначе лидер, сканирующий следом за другим, не увидит
-- ответа), но если отклик ещё ждёт отправки, он уйдёт после обоих сканирований и годится для обоих.
local hiPending = false    -- отклик запланирован, но ещё не отправлен
local hiPendingAt = -100
local hiEchoAt = -100      -- когда мой отклик последний раз вернулся из чата
local hiFailNoticeAt = -100
local function replyPresence(leader)   -- leader = nil: отметка при входе в игру
    if hiPending and os.clock() - hiPendingAt < 5 then return end
    hiPending, hiPendingAt = true, os.clock()
    local line = string.format('%s %s HI %s', CFG.chat_cmd, CFG.code_prefix, thisScript().version)
    lua_thread.create(function()
        wait(math.random(0, math.floor(CFG.hi_jitter * 1000)))
        for try = 1, CFG.hi_tries do
            if os.clock() - state.lastSendAt < CFG.chat_pause then wait(math.floor(CFG.chat_pause * 1000)) end
            local sentAt = os.clock()
            state.lastSendAt = sentAt
            dbg(string.format('%s, попытка %d', leader and ('отклик на сканирование ' .. leader) or 'отметка при входе', try))
            sampSendChat(line)
            hiPending = false
            while os.clock() - sentAt < CFG.hi_confirm and hiEchoAt < sentAt do wait(50) end
            if hiEchoAt >= sentAt then return end
        end
        if os.clock() - hiFailNoticeAt > 60 then
            hiFailNoticeAt = os.clock()
            msg('{FF6060}Твоя отметка «со скриптом» не прошла в ' .. CFG.chat_cmd ..
                ': сервер не пропустил или чат не тот (/ac, Настройки).')
        end
    end)
end

-- Разбор служебного кода. Возвращает true, если код распознан (тогда строка скрывается).
-- Форматы (без двоеточий, чтобы антиреклама сервера не приняла цифры за IP:порт):
--   #SF GO <задержка> <отсчёт> A <id1>.<id2>...   - авто-режим, участники по ID от лидера
--   #SF GO <задержка> <отсчёт> <версия> <отпечаток> - запасной режим по GitHub-ростеру
--   #SF STOP / #SF SYNC / #SF SCAN / #SF HI
-- Старые версии знают только запасной GO и игнорируют остальное.

-- Мой список отличается от лидерского: скачиваем свежий прямо во время отсчёта.
-- Лидер ли отправитель, решает уже свежий список (так подхватываются и новые лидеры),
-- а к волне подключаемся с учётом времени, ушедшего на загрузку.
local lastForeignCatchUp = -100
local lastSyncAt = -100

-- Код от того, кого нет в моих лидерах, а свежий список не скачался - проверить его нельзя.
-- Говорю об этом вслух (не чаще раза в минуту), иначе игрок не поймёт, почему не участвует.
local lastListFailNoticeAt = -100
local function listFailedNotice(sender, what)
    if os.clock() - lastListFailNoticeAt < 60 then return end
    lastListFailNoticeAt = os.clock()
    msg(string.format('{FF6060}%s %s, но его нет в твоём списке лидеров, а свежий список не скачался.', sender, what))
    msg('{FF6060}Проверь доступ к github.com и набери /ac reload.')
    msgNicks('Лидеры у тебя сейчас:', leaderList())
end

-- Авто-запуск от того, кого у меня нет в лидерах: обновляю лидеров с GitHub и проверяю снова
local function catchUpLeaderAuto(sender, delay, cd, idstr)
    local receivedAt = os.clock()
    dbg(string.format('авто-код от %s, его нет в моих лидерах - проверяю общий список', sender))
    loadRemoteRoster(false, function(ok)
        if not isLeader(sender) then
            if not ok then listFailedNotice(sender, 'запустил флуд') end
            dbg('после обновления ' .. sender .. ' всё равно не лидер - игнор')
        elseif state.lastStopAt >= receivedAt then
            msg('Пока обновлялся список, лидер уже остановил запуск.')
        elseif state.phase == 'idle' then
            beginCountdownAuto(sender, delay, cd, idstr, receivedAt)
        end
    end)
end

local function catchUpAndStart(sender, delay, cd, ver, hash)
    local receivedAt = os.clock()
    if isLeader(sender) then
        msg('Твой список отличается от лидерского, обновляю...')
    else
        dbg(string.format('код от %s, его нет в моём списке лидеров - проверяю общий список', sender))
    end
    loadRemoteRoster(false, function(ok)
        if not isLeader(sender) then
            if not ok then listFailedNotice(sender, 'запустил флуд') end
            dbg('после обновления списка ' .. sender .. ' всё равно не лидер - игнор')
        elseif not listMatches(ver, hash) then
            msg('{FF6060}Список у тебя и у лидера всё равно разный - в этом запуске не участвуешь. ' ..
                'Лидеру: /ac sync и запуск заново.')
        elseif state.lastStopAt >= receivedAt then
            msg('Пока обновлялся список, лидер уже остановил запуск.')
        elseif state.phase == 'idle' then
            beginCountdown(sender, delay, cd, receivedAt)
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

    -- #SF HI [версия] - отклик на сканирование (v2.9+ добавляют свою версию)
    local isHi, hiVer = rest:match('^%s+(HI)%s*([%d%.]*)')

    -- любой служебный код подтверждает: этот игрок со скриптом (свои сообщения не считаем)
    if fromMe then
        if isHi then hiEchoAt = os.clock() end
    else
        recordPresence(sender, (isHi and hiVer ~= '') and hiVer or nil)
    end
    if isHi then return true end

    -- Авто-GO: #SF GO <задержка> <отсчёт> A <id1>.<id2>...
    local ad, acd, aids = rest:match('^%s+GO%s+(%d+)%s+(%d+)%s+[Aa]%s+([%d%.]+)')
    if ad then
        ad, acd = tonumber(ad), tonumber(acd)
        if not isLeader(sender) then
            if os.clock() - lastForeignCatchUp < 10 then return false end
            lastForeignCatchUp = os.clock()
            if fromMe then confirmOutbox('GO') end
            catchUpLeaderAuto(sender, ad, acd, aids)
            return true
        end
        if fromMe then confirmOutbox('GO') end
        beginCountdownAuto(sender, ad, acd, aids)
        return true
    end

    local d, cd, ver, hash = rest:match('^%s+GO%s+(%d+)%s+(%d+)%s+(%d+)%s*(%w*)')
    if d then
        d, cd, ver = tonumber(d), tonumber(cd), tonumber(ver)
        local leader = isLeader(sender)
        if not listMatches(ver, hash) or not leader then
            -- код от того, кого нет в моём списке лидеров: возможно, мой список устарел.
            -- Таких проверяем не чаще раза в 10 с, чтобы нельзя было заставить всех качать список.
            if not leader then
                if os.clock() - lastForeignCatchUp < 10 then return false end
                lastForeignCatchUp = os.clock()
            end
            if fromMe then confirmOutbox('GO') end
            catchUpAndStart(sender, d, cd, ver, hash)
            return true
        end
        if fromMe then confirmOutbox('GO') end
        beginCountdown(sender, d, cd)
        return true
    end

    -- #SF SCAN от того, кого нет в моих лидерах: возможно, его только что сделали лидером,
    -- а мой список устарел. Сверяюсь с GitHub (не чаще раза в 10 с) и, если он лидер, откликаюсь.
    if rest:match('^%s+SCAN') and not isLeader(sender) then
        if os.clock() - lastForeignCatchUp < 10 then return false end
        lastForeignCatchUp = os.clock()
        dbg('сканирование от ' .. sender .. ', его нет в моих лидерах - проверяю общий список')
        loadRemoteRoster(false, function(ok)
            if isLeader(sender) then
                if not fromMe then replyPresence(sender) end
            elseif not ok then
                listFailedNotice(sender, 'просит отклик')
            else
                dbg('после обновления ' .. sender .. ' всё равно не лидер - не отвечаю')
            end
        end)
        return false
    end

    if not isLeader(sender) then
        dbg('код от ' .. sender .. ', он не в списке лидеров - игнор')
        return false
    end
    -- #SF SCAN - лидер спрашивает, кто со скриптом в сети; откликаюсь, если это не я
    if rest:match('^%s+SCAN') then
        lastScanSeenAt = os.clock()
        if fromMe then confirmOutbox('SCAN') else replyPresence(sender) end
        return true
    end
    if rest:match('^%s+SYNC') then
        if fromMe then confirmOutbox('SYNC') end
        if os.clock() - lastSyncAt >= CFG.sync_cooldown then
            lastSyncAt = os.clock()
            msg(fromMe and 'Обновляю список у всех...' or ('Лидер ' .. sender .. ' обновляет список у всех...'))
            loadRemoteRoster(true)
        end
        return true
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
        '',
        '; Автоопределение участников: в волне те, кто со скриптом и в сети.',
        '; false - брать участников из списка состава на GitHub (true/false)',
        'auto_discovery = ' .. tostring(o.auto_discovery ~= false),
    }
    return table.concat(L, '\n') .. '\n'
end

local function currentSettings()
    return {
        chat_cmd = CFG.chat_cmd, countdown = CFG.default_countdown, max_duration = CFG.max_duration,
        hide_responses = CFG.hide_responses, ping_compensation = CFG.ping_compensation,
        auto_update = CFG.auto_update, auto_discovery = CFG.auto_discovery,
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
    CFG.auto_discovery    = lower(s.auto_discovery or 'true') ~= 'false'

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

-- ---------------------- скачивание с GitHub ------------------------
-- Прямые ссылки raw.githubusercontent.com GitHub кэширует до 5 минут, поэтому файлы берутся
-- через API GitHub: он отдаёт свежую версию сразу. Если API не ответил (например, исчерпан
-- лимит запросов), файл берётся по прямой ссылке.

local httpSeq = 0

local function fileSize(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local size = f:seek('end')
    f:close()
    return size
end

-- Скачивание через downloadUrlToFile. Правила, которые здесь соблюдаются:
-- 1) Сигнал STATUS_ENDDOWNLOADDATA приходит, когда данные получены, но Windows может ещё
--    дописывать файл на диск. Файл читается по окончательному сигналу STATUSEX_ENDDOWNLOAD,
--    а если его нет - когда размер файла перестал меняться.
-- 2) Из обработчика загрузки нельзя запускать новую загрузку («device or resource busy»),
--    поэтому обработчик только ставит отметки.
-- 3) Загрузку нельзя запускать из временного потока lua_thread: поток завершится раньше
--    загрузки, и сообщение о её окончании придёт в уже несуществующий поток (падение игры).
--    Поэтому httpGet только ставит запрос в очередь, а запускает загрузки, следит за ними
--    и вызывает обработчики результата главный цикл скрипта (pollDownloads).
local dlQueue  = {}   -- запросы, ждущие запуска
local dlActive = {}   -- идущие загрузки

-- Скачивает url, потом вызывает cb(содержимое) или cb(nil) при ошибке или по таймауту
local function httpGet(url, timeoutMs, cb)
    dlQueue[#dlQueue + 1] = { url = url, timeoutMs = timeoutMs, cb = cb }
end

local function readWholeFile(path)
    local f = io.open(path, 'rb')
    local content = f and f:read('*a')
    if f then f:close() end
    return (content and content ~= '') and content or nil
end

local function finishDownload(d, content)
    if d.done then return end
    d.done = true
    d.cleanupAt = os.clock() + 30
    os.remove(d.path)
    trace(string.format('загрузка %d: %s', d.seq, content and (#content .. ' байт') or 'нет данных'))
    -- ошибка в обработке ответа не должна «убивать» весь скрипт
    local ok, err = pcall(d.cb, content)
    if not ok then
        print('[AMARAYTHEN] ошибка при обработке загрузки: ' .. tostring(err))
        dbg('ошибка при обработке загрузки: ' .. tostring(err))
    end
end

local function startDownload(req)
    httpSeq = httpSeq + 1
    local dir = getWorkingDirectory() .. '\\config'
    if not doesDirectoryExist(dir) then createDirectory(dir) end
    local d = {
        seq = httpSeq, cb = req.cb, done = false,
        path = string.format('%s\\sf_download_%d.tmp', dir, httpSeq),
        st = { dataEnded = false, fullyEnded = false },
        deadline = os.clock() + req.timeoutMs / 1000,
        last = -1, stable = 0, nextPoll = 0,
    }
    os.remove(d.path)
    local EX_END = dlstatus.STATUSEX_ENDDOWNLOAD
    local st = d.st
    trace(string.format('загрузка %d: %s', d.seq, req.url:match('^https://([^/]+)') or '?'))
    local ok, err = pcall(downloadUrlToFile, req.url, d.path, function(id, status)
        if EX_END and status == EX_END then
            st.fullyEnded = true
        elseif status == dlstatus.STATUS_ENDDOWNLOADDATA then
            st.dataEnded = true
        end
    end)
    dlActive[#dlActive + 1] = d
    if not ok then
        print('[AMARAYTHEN] не удалось начать загрузку: ' .. tostring(err))
        finishDownload(d, nil)
    end
end

-- Вызывается из главного цикла каждый кадр
local function pollDownloads(now)
    -- запуск новых (обработчики результатов могли добавить запросы - они стартуют в следующий раз)
    local pending = dlQueue
    dlQueue = {}
    for _, req in ipairs(pending) do startDownload(req) end

    -- со STATUSEX_ENDDOWNLOAD ждём его (но не дольше ~1.5 с после конца данных),
    -- без него - пока размер файла не меняется целую секунду (проверка раз в 50 мс)
    local need = dlstatus.STATUSEX_ENDDOWNLOAD and 30 or 20
    for i = #dlActive, 1, -1 do
        local d = dlActive[i]
        if not d.done then
            if d.st.fullyEnded then
                finishDownload(d, readWholeFile(d.path))
            elseif now >= d.deadline then
                finishDownload(d, nil)
            elseif d.st.dataEnded and now >= d.nextPoll then
                d.nextPoll = now + 0.05
                local size = fileSize(d.path)
                if size and size > 0 and size == d.last then d.stable = d.stable + 1 else d.stable = 0 end
                d.last = size or -1
                if d.stable >= need then finishDownload(d, readWholeFile(d.path)) end
            end
        end
        -- загрузка, оборванная по таймауту, может дописать файл позже - убираем его
        if d.done and (d.st.fullyEnded or now >= d.cleanupAt) then
            os.remove(d.path)
            table.remove(dlActive, i)
        end
    end
end

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64_INDEX = {}
for i = 1, 64 do B64_INDEX[B64:byte(i)] = i - 1 end

local function base64Decode(s)
    s = s:gsub('[^%w%+/=]', '')
    local out, n = {}, 0
    for i = 1, #s, 4 do
        local a, b, c, d = s:byte(i, i + 3)
        local A, B = B64_INDEX[a], a and b and B64_INDEX[b]
        if not A or not B then break end
        local C, D = c and B64_INDEX[c], d and B64_INDEX[d]
        local v = A * 262144 + B * 4096 + (C or 0) * 64 + (D or 0)
        n = n + 1; out[n] = string.char(math.floor(v / 65536) % 256)
        if C then n = n + 1; out[n] = string.char(math.floor(v / 256) % 256) end
        if D then n = n + 1; out[n] = string.char(v % 256) end
    end
    return table.concat(out)
end

-- Ответ API GitHub (JSON) -> содержимое файла, или nil.
-- Размер раскодированного файла сверяется с полем "size": так отсекается обрезанный ответ.
local function decodeContentsJson(json)
    if not json:find('"encoding"%s*:%s*"base64"') then return nil end
    local b64 = json:match('"content"%s*:%s*"([^"]*)"')
    if not b64 then return nil end
    b64 = b64:gsub('\\n', ''):gsub('\\r', ''):gsub('\\/', '/')
    local data = base64Decode(b64)
    local size = tonumber(json:match('"size"%s*:%s*(%d+)'))
    if size and #data ~= size then
        dbg(string.format('ответ API неполный: %d из %d байт', #data, size))
        return nil
    end
    return data ~= '' and data or nil
end

-- Свежий файл из репозитория: cb(содержимое или nil, 'api' | 'raw')
local function fetchRepoFile(path, timeoutMs, cb)
    local g, t = CFG.github, os.time()
    local api = string.format('https://api.github.com/repos/%s/%s/contents/%s?ref=%s&t=%d',
        g.owner, g.repo, path, g.branch, t)
    local raw = string.format('https://raw.githubusercontent.com/%s/%s/%s/%s?nocache=%d',
        g.owner, g.repo, g.branch, path, t)
    httpGet(api, timeoutMs, function(json)
        local data = json and decodeContentsJson(json)
        if data then
            cb(data, 'api')
            return
        end
        dbg('API GitHub не ответил для ' .. path .. ', беру по прямой ссылке')
        httpGet(raw, timeoutMs, function(content) cb(content, 'raw') end)
    end)
end

-- -------------------------- общий список ---------------------------
local rosterWaiters   = nil   -- если не nil - список сейчас скачивается
local rosterCheckedAt = -1000

local function rosterBusy()
    return rosterWaiters ~= nil
end

-- verbose - писать в чат и об успехе, и об ошибках (иначе - только если список изменился).
-- onDone(ok) вызывается по завершении. Если список уже скачивается, запрос дожидается его.
loadRemoteRoster = function(verbose, onDone, timeoutMs)
    if rosterWaiters then
        rosterWaiters[#rosterWaiters + 1] = { verbose = verbose, onDone = onDone }
        return
    end
    rosterWaiters = { { verbose = verbose, onDone = onDone } }
    rosterCheckedAt = os.clock()

    fetchRepoFile(CFG.roster_path, timeoutMs or 8000, function(content, source)
        local waiters = rosterWaiters
        rosterWaiters = nil
        local anyVerbose = false
        for _, w in ipairs(waiters) do anyVerbose = anyVerbose or w.verbose end

        local ok, text = false, nil
        local ver, list, leaders
        if content then ver, list, leaders = parseRoster(content) end
        if not content then
            text = '{FF6060}Общий список не скачался, оставлен сохранённый. Проверь интернет.'
        elseif not ver then
            text = '{FF6060}Общий список в неверном формате, оставлен сохранённый.'
        else
            ok = true
            local oldHash = listHash()
            local changed = ver ~= roster.version
            roster.version, roster.list, roster.leaders = ver, list, leaders
            roster.fetchedAt = os.clock()
            changed = changed or listHash() ~= oldHash
            saveRosterCache(content)
            dbg('список получен через ' .. source)
            local info = string.format('v%d, %d ников, лидеров %d.', ver, #list, #leaderList())
            if anyVerbose then
                text = 'Общий список загружен: ' .. info
            elseif changed then
                text = 'Общий список обновился: ' .. info
            end
        end
        if text and (ok or anyVerbose) then msg(text) end
        for _, w in ipairs(waiters) do
            if w.onDone then w.onDone(ok) end
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
    if update.checking then return end
    update.checking = true
    update.checkedAt = os.clock()

    local function finish(text)
        update.checking = false
        if text then msg(text) end
    end

    fetchRepoFile(CFG.script_path, 15000, function(content, source)
        if not content then
            finish(verbose and '{FF6060}Не удалось проверить обновления: нет ответа от GitHub.' or nil)
            return
        end
        dbg('файл обновления получен через ' .. source)

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
        -- Последняя строка файла - метка конца. Нет её - файл скачался не полностью:
        -- пробую снова через минуту, а не через полчаса.
        if not content:match('SF%-CAPTURE: конец файла%s*$') then
            update.checkedAt = os.clock() - CFG.update_interval + 60
            finish('{FF6060}Обновление v' .. newVersion .. ' скачалось не полностью, повторю через минуту.')
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
end

-- --------------------------- действия ------------------------------
local pendingGo = nil   -- запланированный авто-запуск: ждём откликов на сканирование

-- Запасной запуск по GitHub-ростеру (когда автоопределение выключено или никого не нашло)
local function sendFallbackGo(delay, cd)
    local line = string.format('%s %s GO %d %d %d %s', CFG.chat_cmd, CFG.code_prefix,
        delay, cd, roster.version, listHash())
    msg(string.format('Код запуска отправлен в %s (по списку состава, задержка %d мс, отсчёт %d с)...',
        CFG.chat_cmd, delay, cd))
    queueLeaderMessage('GO', line, CFG.go_tries)
end

-- Авто-запуск: разослать ID присутствующих одним кодом
local function sendAutoGo(delay, cd, idstr, count, trimmed)
    if trimmed then
        msg(string.format('{FF6060}Слишком много участников, взял первых %d.', CFG.max_participants))
    end
    local line = string.format('%s %s GO %d %d A %s', CFG.chat_cmd, CFG.code_prefix, delay, cd, idstr)
    msg(string.format('Код запуска отправлен в %s (участников: %d, задержка %d мс, отсчёт %d с)...',
        CFG.chat_cmd, count, delay, cd))
    queueLeaderMessage('GO', line, CFG.go_tries)
end

-- Срабатывает в главном цикле, когда прошло время сбора откликов на сканирование
local function finalizeAutoLaunch()
    local p = pendingGo
    pendingGo = nil
    -- в волну идут только ответившие на это сканирование: чей скрипт отвечает прямо сейчас
    local idstr, count, trimmed = buildParticipantIds(p.since)
    lastScanInfo = { at = os.clock(), count = count }
    if count < 2 then
        -- На GitHub-список не откатываемся автоматически: там могут быть без скрипта, волна с дырами.
        -- Запасной режим включается вручную - выключить автоопределение в настройках.
        msg('Со скриптом в сети больше никого не отозвалось, запускаю один.')
    end
    local silent = silentRosterNicks(nil, p.since)
    if #silent > 0 then
        msgNicks(string.format('{FFB040}Из списка состава не отозвались, в волне не будут (%d):{CFCFCF}', #silent), silent)
    end
    sendAutoGo(p.delay, p.cd, idstr, count, trimmed)
end

local function leaderStart(delay, cd)
    delay = math.floor(delay)
    if delay < CFG.min_delay or delay > CFG.max_delay then
        msg(string.format('Задержка должна быть от %d до %d мс.', CFG.min_delay, CFG.max_delay))
        return
    end
    cd = math.max(0, math.min(30, math.floor(cd)))

    -- Сверяемся со свежим списком: нужны актуальные лидеры (и ростер для запасного режима)
    msg('Проверяю список...')
    loadRemoteRoster(false, function()
        local nick = myNick() or ''
        if not isLeader(nick) then
            msg('Запускать может только лидер. Твой ник в игре: ' .. (nick ~= '' and nick or 'не определён') .. '.')
            return
        end

        if not CFG.auto_discovery then
            if roster.version == 0 then
                msg('{FF6060}Общий список ещё ни разу не скачался - запуск невозможен. Проверь интернет.')
                return
            end
            sendFallbackGo(delay, cd)
            return
        end

        -- автоопределение: сначала рассылаем сканирование, собираем отклики, потом код запуска
        msg('Сканирую, кто со скриптом в сети...')
        local since = os.clock()
        queueLeaderMessage('SCAN', CFG.chat_cmd .. ' ' .. CFG.code_prefix .. ' SCAN', 2, function()
            pendingGo = { delay = delay, cd = cd, at = os.clock() + CFG.scan_wait, since = since }
        end)
    end, 2500)
end

-- Отдельное сканирование (кнопка/команда или само при входе лидера в игру)
local function leaderScan(onJoin)
    local nick = myNick() or ''
    if not isLeader(nick) then
        msg('Сканировать может только лидер.')
        return
    end
    if state.phase ~= 'idle' or outbox or pendingGo then
        msg('Сейчас занят, повтори чуть позже.')
        return
    end
    msg(onJoin and 'Проверяю, кто со скриптом в сети (при входе в игру)...' or 'Сканирую, кто со скриптом в сети...')
    local since = os.clock()
    queueLeaderMessage('SCAN', CFG.chat_cmd .. ' ' .. CFG.code_prefix .. ' SCAN', 2, function()
        lua_thread.create(function()
            wait(math.floor(CFG.scan_wait * 1000) + 400)
            lastScanInfo = { at = os.clock(), count = scanReport(since) }
        end)
    end)
end

-- Лидер просит всех сразу скачать свежий список
local function leaderSync()
    local nick = myNick() or ''
    if not isLeader(nick) then
        msg('Обновить список у всех может только лидер. Обнови у себя: /ac reload.')
        return
    end
    if state.phase ~= 'idle' then
        msg('Во время флуда нельзя, дождись конца или останови его.')
        return
    end
    msg('Отправляю команду обновления в ' .. CFG.chat_cmd .. '...')
    queueLeaderMessage('SYNC', CFG.chat_cmd .. ' ' .. CFG.code_prefix .. ' SYNC', 2)
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
-- Кнопки меню не выполняют действия сразу (окно рисуется внутри отрисовки игры), а ставят
-- их в очередь; главный цикл выполняет их в своём обычном порядке.
local startMenuTrace = function() end   -- заполняется в блоке меню

local uiActions = {}
local function uiDo(name, fn)
    uiActions[#uiActions + 1] = { name = name, fn = fn }
end

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
        autoDisc  = new.bool(true),
        debug     = new.bool(false),
        dirty     = false,
        online    = {},       -- [норм.ник] = ID, кто сейчас на сервере
        onlineAt  = -1,
        present   = {},       -- другие со скриптом, на связи
        missed    = {},       -- отмечались, но не ответили на последнее сканирование
        silent    = {},       -- из списка состава в сети, но ни разу не отметились
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
        ui.autoDisc[0]  = CFG.auto_discovery
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
        ui.online  = onlineMap()
        ui.present, ui.missed = knownNicks(ui.online)
        ui.silent  = silentRosterNicks(ui.online)
    end

    -- Авто-режим: сколько будет в волне (я + отозвавшиеся) и мой слот - участники идут по возрастанию ID,
    -- как их потом разошлёт лидер
    local function autoSlot()
        local mine = myId()
        local ids = { mine or -1 }
        for _, n in ipairs(ui.present) do
            local id = ui.online[norm(n)]
            if id then ids[#ids + 1] = id end
        end
        table.sort(ids)
        if not mine then return #ids, nil end
        for i, id in ipairs(ids) do
            if id == mine then return #ids, i - 1 end
        end
        return #ids, nil
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
            auto_discovery    = ui.autoDisc[0],
        }
        if not writeConfig(o) then
            setNotice('Не удалось записать sf_capture.ini.', true)
            return
        end
        loadConfig(false)
        setNotice('Сохранено.')
    end

    -- Отметки первых кадров после открытия меню - в отдельный файл, с записью на диск сразу:
    -- если игра упадёт, по последней строке будет видно, на каком шаге отрисовки.
    local markFrames, markPath = 0, nil
    local function mark(step)
        if markFrames <= 0 or not markPath then return end
        local f = io.open(markPath, 'a')
        if f then f:write(string.format('%.3f %s\n', os.clock(), step)) f:close() end
    end
    startMenuTrace = function()
        markPath = getWorkingDirectory() .. '\\config\\sf_trace.txt'
        local f = io.open(markPath, 'w')
        if f then f:write('v' .. thisScript().version .. ' - открытие меню\n') f:close() end
        markFrames = 3
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
        mark('запуск: онлайн')
        refreshOnline()
        mark('запуск: ник')
        local me = myNick() or '?'
        local leader = isLeader(me)
        local W = contentWidth()

        -- кто я
        withFont(F.bold, function() imgui.Text(me) end)
        imgui.SameLine(0, 10)
        pill(u8(leader and 'ЛИДЕР' or 'УЧАСТНИК'), leader and C_ACCENT or C_MUTED, false)
        mark('запуск: пинг')
        local ptxt = u8(string.format('пинг %d мс', myPing()))
        imgui.SameLine(imgui.GetWindowWidth() - PAD - imgui.CalcTextSize(ptxt).x)
        imgui.TextDisabled(ptxt)
        imgui.Dummy(V2(0, 2))

        -- карточки
        mark('запуск: карточки')
        local active, slot
        local cw = (W - 16) / 3
        if CFG.auto_discovery then
            -- авто-режим: в волне те, кто отозвался на сканирование (плюс я)
            active, slot = autoSlot()
            statCard('##st1', 'СО СКРИПТОМ', tostring(active), active > 1 and C_GREEN or C_MUTED, cw)
            imgui.SameLine(0, 8)
            statCard('##st2', 'ТВОЙ СЛОТ', slot and tostring(slot + 1) or '-', slot and C_ACCENT or C_MUTED, cw)
            imgui.SameLine(0, 8)
            statCard('##st3', 'РЕЖИМ', 'АВТО', C_TEXT, cw)
        else
            active, slot = rosterOnline(me)
            statCard('##st1', 'В СЕТИ', string.format('%d / %d', active, #roster.list),
                active > 0 and C_GREEN or C_MUTED, cw)
            imgui.SameLine(0, 8)
            statCard('##st2', 'ТВОЙ СЛОТ', slot and tostring(slot + 1) or '-', slot and C_ACCENT or C_MUTED, cw)
            imgui.SameLine(0, 8)
            statCard('##st3', 'ВЕРСИЯ', roster.version > 0 and ('v' .. roster.version) or '-', C_TEXT, cw)
        end
        imgui.Dummy(V2(0, 2))

        -- что происходит сейчас
        mark('запуск: состояние')
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

        mark('запуск: панель')
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
            if CFG.auto_discovery then
                imgui.TextDisabled(u8(string.format('Шаг волны: %d / %d = %.0f мс (уточнится сканированием)',
                    ui.delay[0], active, ui.delay[0] / active)))
            elseif active > 0 then
                imgui.TextDisabled(u8(string.format('Шаг волны: %d / %d = %.0f мс между %s',
                    ui.delay[0], active, ui.delay[0] / active, CFG.flood_cmd)))
            else
                imgui.TextDisabled(u8'Из списка сейчас никого нет в сети.')
            end
            imgui.Dummy(V2(0, 2))
            local bw = (W - 28 - 8) / 2
            glowRect(imgui.GetCursorScreenPos(), bw, 42, C_ACCENT, 7, 1)
            if colorButton(u8'ЗАПУСТИТЬ', bw, 42, C_ACCENT, C_ACCENT_HI, C_ON_ACCENT) then
                local delay, cd = ui.delay[0], ui.countdown[0]
                uiDo('запуск', function() leaderStart(delay, cd) end)
            end
            imgui.SameLine(0, 8)
            if colorButton(u8'СТОП ВСЕМ', bw, 42, C_RED_BG, C_RED, C_TEXT) then
                uiDo('стоп всем', leaderStop)
            end
            endCard()
        else
            beginCard('##member', 12 + th * 4 + 8 + 38 + 14)
            cardTitle('УЧАСТНИК')
            mutedWrapped('Флуд запускает лидер. Скрипт сам встанет в волну в свою очередь, ' ..
                'а остановить его ты можешь только у себя.')
            imgui.Dummy(V2(0, 2))
            if colorButton(u8'Остановить у себя', W - 28, 38, C_RED_BG, C_RED, C_TEXT) then
                uiDo('стоп у себя', function() stopFlood('остановлено вручную') end)
            end
            endCard()
        end

        imgui.Dummy(V2(0, 2))
        ui.debug[0] = CFG.debug
        if imgui.Checkbox(u8'Отладка в чате', ui.debug) then CFG.debug = ui.debug[0] end
    end

    -- строки списка: точка «в сети», номер, ник, метки справа.
    -- rowInfo(ник) (необязательно) -> { muted = серым, badges = { {текст, цвет}, ... } }
    local function drawNickRows(list, me, emptyText, height, rowInfo)
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
            local info = rowInfo and rowInfo(n) or {}
            local on = ui.online[norm(n)] and not info.muted
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
            for _, b in ipairs(info.badges or {}) do badges[#badges + 1] = { u8(b[1]), b[2] } end
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

    local function drawListHeader(title, count, total, pillText)
        withFont(F.bold, function() imgui.Text(u8(title)) end)
        local txt = u8(pillText or string.format('в сети %d из %d', count, total))
        imgui.SameLine(imgui.GetWindowWidth() - PAD - pillWidth(txt, true))
        pill(txt, count > 0 and C_GREEN or C_MUTED, true)
    end

    local function drawRosterTab()
        refreshOnline()
        local me = myNick()
        local leader = isLeader(me or '')

        if CFG.auto_discovery then
            local present, missed, silent = ui.present, ui.missed, ui.silent
            local n = #present + 1
            drawListHeader('Со скриптом в сети', n, n, string.format('%d со скриптом', n))
            mutedWrapped('Игроки со скриптом попадают сюда сами, когда заходят в игру. ' ..
                'Перед запуском лидер ещё раз проверяет всех: в волну идут только ответившие.')
            local info
            if lastScanSeenAt < 0 then
                info = 'сканирования в этой сессии ещё не было'
            else
                local s = os.clock() - lastScanSeenAt
                if s < 15 then
                    info = 'сканирование было только что'
                elseif s < 120 then
                    info = string.format('последнее сканирование: %d с назад', math.floor(s))
                else
                    info = string.format('последнее сканирование: %d мин назад', math.floor(s / 60))
                end
            end
            imgui.TextDisabled(u8(info))
            local grey = #missed + #silent
            if grey > 0 then
                wrappedColored(C_ACCENT, string.format('Серые (%d) - в сети, но не на связи: нет скрипта, ' ..
                    'версия старее 2.4 или у них не скачался список лидеров.', grey))
            end
            imgui.Dummy(V2(0, 2))
            -- я + на связи, затем не ответившие на сканирование, затем молчащие из списка состава
            local shown, tag = { me or '?' }, {}
            for _, x in ipairs(present) do shown[#shown + 1] = x end
            for _, x in ipairs(missed) do shown[#shown + 1] = x; tag[norm(x)] = 'не ответил' end
            for _, x in ipairs(silent) do shown[#shown + 1] = x; tag[norm(x)] = 'не отмечался' end
            local myVer = thisScript().version
            drawNickRows(shown, me, 'Пока никто не отметился.', grey > 0 and 256 or 296, function(x)
                local t = tag[norm(x)]
                if t then return { muted = true, badges = { { t, C_MUTED } } } end
                local isMe = me and norm(x) == norm(me)
                local pr = presenceOf(x)
                local ver = isMe and myVer or (pr and pr.ver)
                if ver then
                    return { badges = { { 'v' .. ver, isNewerVersion(myVer, ver) and C_ACCENT or C_MUTED } } }
                end
                return {}
            end)
            imgui.Dummy(V2(0, 2))
            if leader then
                glowRect(imgui.GetCursorScreenPos(), contentWidth(), 32, C_ACCENT, 7, 0.7)
                if colorButton(u8'Сканировать', contentWidth(), 32, C_ACCENT, C_ACCENT_HI, C_ON_ACCENT) then
                    uiDo('сканирование', leaderScan)
                end
            else
                imgui.TextDisabled(u8'Сканирование запускает лидер.')
            end
            return
        end

        local active = rosterOnline(me)
        drawListHeader(roster.version > 0 and string.format('Список  ·  v%d', roster.version) or 'Список',
            active, #roster.list)
        mutedWrapped('Порядок в списке - очерёдность в волне. Список общий для состава и обновляется сам.')
        local age
        if rosterBusy() then
            age = 'обновляется...'
        elseif roster.fetchedAt then
            local s = os.clock() - roster.fetchedAt
            age = s < 60 and 'обновлён только что' or string.format('обновлён %d мин назад', math.floor(s / 60))
        else
            age = roster.version > 0 and 'сохранённая копия, ещё не обновлялся' or 'ещё не загружен'
        end
        imgui.TextDisabled(u8(age))
        imgui.Dummy(V2(0, 2))
        drawNickRows(roster.list, me, 'Список ещё не загружен.', 296)
        imgui.Dummy(V2(0, 2))
        if leader then
            local bw = (contentWidth() - 8) / 2
            if imgui.Button(u8'Обновить у себя', V2(bw, 32)) then
                uiDo('обновить у себя', function() loadRemoteRoster(true) end)
            end
            imgui.SameLine(0, 8)
            glowRect(imgui.GetCursorScreenPos(), bw, 32, C_ACCENT, 7, 0.7)
            if colorButton(u8'Обновить у всех', bw, 32, C_ACCENT, C_ACCENT_HI, C_ON_ACCENT) then
                uiDo('обновить у всех', leaderSync)
            end
        else
            if imgui.Button(u8'Обновить список', V2(contentWidth(), 32)) then
                uiDo('обновить список', function() loadRemoteRoster(true) end)
            end
        end
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

        sectionTitle('УЧАСТНИКИ')
        if imgui.Checkbox(u8'Автоопределение (кто со скриптом, тот в волне)', ui.autoDisc) then ui.dirty = true end
        imgui.TextDisabled(u8'Выкл - участники из списка состава на GitHub.')

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
            uiDo('проверка обновлений', function() checkForUpdate(true) end)
        end
        imgui.SameLine(0, 8)
        if imgui.Button(u8'Перечитать конфиг', V2(bw, 32)) then
            uiDo('перечитать конфиг', function()
                if reloadAll() then setNotice('Конфиг перечитан.') end
            end)
        end
    end

    local function drawFooter()
        if ui.dirty then
            imgui.Dummy(V2(0, 6))
            mutedWrapped('Есть несохранённые изменения.')
            local bw = (contentWidth() - 8) / 2
            if colorButton(u8'Сохранить', bw, 34, C_ACCENT, C_ACCENT_HI, C_ON_ACCENT) then
                uiDo('сохранить настройки', saveFromUi)
            end
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
        mark('шрифты: начало')
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
        mark('шрифты: готово')
    end)

    imgui.OnFrame(
        function() return ui.open[0] end,
        function(player)
            mark('кадр: начало')
            local sw, sh = getScreenResolution()
            imgui.SetNextWindowPos(V2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, V2(0.5, 0.5))
            imgui.SetNextWindowSize(V2(480, 610), imgui.Cond.Always)
            local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
            if imgui.Begin('AMARAYTHEN Capter##sfmain', ui.open, flags) then
                mark('окно')
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
                mark('ореол')
                drawHeader()
                mark('шапка')
                drawTabs()
                mark('вкладки, открыта ' .. ui.tab)
                if ui.tab == 1 then
                    drawLaunchTab()
                elseif ui.tab == 2 then
                    drawRosterTab()
                elseif ui.tab == 3 then
                    drawLeadersTab()
                else
                    drawSettingsTab()
                end
                mark('вкладка нарисована')
                drawFooter()
                mark('низ')
            end
            imgui.End()
            mark('кадр: конец')
            markFrames = markFrames - 1
        end
    )
end

local function menuOpen()
    return ui ~= nil and ui.open[0]
end

-- ----------------------------- команды -----------------------------
local HELP = '/ac - меню. Ещё: /ac start <мс> [отсчёт], stop, scan, sync, status, list, reload, update'

local function cmdSf(arg)
    local cmd, a1, a2 = (arg or ''):match('^%s*(%S*)%s*(%S*)%s*(%S*)')
    cmd = lower(cmd)
    local me = myNick() or ''

    if cmd == '' or cmd == 'menu' then
        if ui then
            ui.open[0] = not ui.open[0]
            if ui.open[0] then
                trace('меню открыто')
                startMenuTrace()
            end
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

    elseif cmd == 'sync' then
        leaderSync()

    elseif cmd == 'scan' then
        leaderScan()

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

    -- разброс откликов у всех разный; свой ID здесь не берём - персонаж может быть ещё не в игре
    math.randomseed(os.time() + math.floor((os.clock() % 1) * 1000000))
    trace('старт v' .. thisScript().version)
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
        msg(HELP)
    else
        msg('{FF6060}mimgui не найдена - меню недоступно, работают команды.')
        msg(HELP)
    end

    local lastLeaderCheck = 0
    local announceAt, announced = nil, false
    while true do
        wait(0)
        local now = os.clock()

        processOutbox(now)
        pollDownloads(now)

        -- действия, нажатые в меню: выполняются здесь, а не во время отрисовки окна
        if #uiActions > 0 then
            local actions = uiActions
            uiActions = {}
            for _, a in ipairs(actions) do
                trace('меню: ' .. a.name)
                local ok, err = pcall(a.fn)
                if not ok then print('[AMARAYTHEN] ошибка действия «' .. a.name .. '»: ' .. tostring(err)) end
            end
        end

        -- при входе в игру (один раз за запуск скрипта): участник отмечается в чате,
        -- лидер сканирует - так игроки со скриптом сами появляются в списке у лидеров
        if not announced and CFG.auto_discovery and CFG.announce_on_join and localReady() and myNick() then
            if not announceAt then
                local a, b = CFG.announce_delay[1], CFG.announce_delay[2]
                announceAt = now + a + math.random() * (b - a)
            elseif now >= announceAt and state.phase == 'idle' and not outbox and not pendingGo and not rosterBusy() then
                announced = true
                if isLeader(myNick()) then leaderScan(true) else replyPresence(nil) end
            end
        end

        -- запланированный авто-запуск: собрали отклики - отправляем код
        if pendingGo and now >= pendingGo.at and not outbox then
            finalizeAutoLaunch()
        end

        -- автообновление: только когда нет флуда и лидер ничего не ждёт из чата
        if state.phase == 'idle' and not outbox and not pendingGo then
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
        if state.phase == 'idle' and not rosterBusy()
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
-- Следующая строка должна оставаться последней: по ней автообновление проверяет, что файл скачался целиком.
-- SF-CAPTURE: конец файла
