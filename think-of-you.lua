-- 想你机 · Think of You
--
-- 两台 LingClaw，一个键，一种消息：有人在想你。
--
-- 按下自己这台，对端就会响一声、灯闪一下，并用它自己的声音把那句话念出来。
-- 没有文字聊天，没有未读红点，只有一种消息。
--
-- 依赖：API 4（http / json / tts / clock / storage / screen / led / buzzer）。
-- 设备只能主动轮询、无法被动接收推送，所以两台设备通过公共中继 ntfy.sh
-- 交换信号：发送即 POST 到主题，接收即每 POLL_MS 拉取一次新消息。
--
-- 配对：两台设备跑完全相同的这一份脚本，只要求同一个 TOPIC，
-- 不需要「本机身份」——自己的回显靠每条消息的随机 token 认出来。
--   1. 用 flash.sh 注入难猜的 TOPIC，两台一起烧：
--        ./flash.sh --topic lingclaw-think-xxxxxxxx
--   2. 手工烧同一份也行：adb push think-of-you.lua /miniapp/think-of-you.lua

------------------------------------------------------------------
-- 配置
------------------------------------------------------------------
local TOPIC = "lingclaw-think-CHANGE-ME-8f3a" -- ntfy 主题；两台相同，务必改掉
local NT    = "https://ntfy.sh/"

local POLL_MS           = 10000 -- 轮询间隔
local SEND_COOLDOWN_MS  = 1500  -- 连点冷却
local TTS_COOLDOWN_MS   = 6000  -- 两次播报的最小间隔
local SAVE_INTERVAL_MS  = 11000 -- 存档写入节流（平台最短 10s）

-- 想说的话：发送时随机挑一句，对端用它自己的声音念出来。
local WHISPERS = {
    "有人在想你。",
    "刚才有个人，忽然想起了你。",
    "喂，抬头看看，有人想你了。",
    "世界很大，但有人正想着你。",
    "这一刻，有人在惦记你。",
    "叮——你被想念了一下。",
}

------------------------------------------------------------------
-- 状态
------------------------------------------------------------------
local uptime_ms = 0
local sent      = 0    -- 本机送出的次数
local last_time = 0    -- 轮询游标：上次已处理消息的时间戳
local seen_id   = ""   -- 已处理的最新消息 id（去重）

local last_press = -1e9
local last_tts   = -1e9
local last_save  = -1e9

local send_id, poll_id          -- 在途请求 id
local uploading, polling = false, false
local next_poll = 0

local speaking = false
local speech_id
local booted = false -- 第一次 tick 属于启动阶段，期间禁止播报

local led_until   = 0
local flash_until = 0
local flash_msg   = ""

------------------------------------------------------------------
-- 自过滤：认「消息」，不认「设备」
------------------------------------------------------------------
-- ntfy 会把自己发的那条也回送给自己，必须滤掉，否则会自己对自己播报。
-- 这里不设本机身份：发送前生成一个随机 token 放进 Title 头（Title 不显示在
-- 界面上），收到消息时看 Title 是不是自己最近发过的，是就当成回显丢弃。
local OWN_KEEP   = 16   -- 记住最近多少条自己的 token；一个轮询周期内发不了这么多
local own_tokens = {}   -- 环形缓冲，槽位 0..OWN_KEEP-1
local own_seq    = 0

local function new_token()
    -- 32 位十六进制，只需在自己最近发出的消息里不重复
    return string.format("%08X", math.random(0, 4294967295))
end

local function remember_own(tok)
    own_tokens[own_seq % OWN_KEEP] = tok
    own_seq = own_seq + 1
end

local function is_own(title)
    if type(title) ~= "string" then
        return false
    end
    for i = 0, OWN_KEEP - 1 do
        if own_tokens[i] == title then
            return true
        end
    end
    return false
end

------------------------------------------------------------------
-- 存档
------------------------------------------------------------------
local function persist(force)
    if not force and uptime_ms - last_save < SAVE_INTERVAL_MS then
        return
    end
    local ok = storage.save({
        s = sent,
        t = last_time,
        i = seen_id,
    })
    if ok then
        last_save = uptime_ms
    end
end

local function restore()
    local saved = storage.load()
    if type(saved) ~= "table" then
        return
    end
    if type(saved.s) == "number" and saved.s >= 0 then
        sent = math.floor(saved.s)
    end
    if type(saved.t) == "number" and saved.t >= 0 then
        last_time = math.floor(saved.t)
    end
    if type(saved.i) == "string" and #saved.i <= 24 then
        seen_id = saved.i
    end
end

------------------------------------------------------------------
-- 画面
------------------------------------------------------------------
local function draw()
    local bg = 0x1A0F1E
    screen.begin(bg)
    screen.text("想你机", 12, 10, 0xFFD9E2)

    -- 像素爱心
    local pink = 0xFF6B8A
    screen.rect(99,  60, 18, 6,  pink)
    screen.rect(123, 60, 18, 6,  pink)
    screen.rect(93,  66, 24, 6,  pink)
    screen.rect(123, 66, 24, 6,  pink)
    screen.rect(87,  72, 66, 12, pink)
    screen.rect(93,  84, 54, 6,  pink)
    screen.rect(99,  90, 42, 6,  pink)
    screen.rect(105, 96, 30, 6,  pink)
    screen.rect(111, 102, 18, 6, pink)
    screen.rect(117, 108, 6,  6, pink)

    screen.text("已送出 " .. sent .. " 次", 12, 152, 0xFFFFFF)

    if uptime_ms < flash_until then
        screen.text(flash_msg, 12, 176, 0xFFD166)
    elseif uploading then
        screen.text("正在送去…", 12, 176, 0x8FE3C4)
    else
        screen.text("按下，就有人在想你", 12, 176, 0x9AA7B8)
    end

    screen.text("主题 …" .. string.sub(TOPIC, -4), 12, 204, 0x6C7A8C)
    screen.present()
end

local function flash(msg, ms)
    flash_msg = msg
    flash_until = uptime_ms + (ms or 1500)
    draw()
end

------------------------------------------------------------------
-- 发送 / 接收
------------------------------------------------------------------
local function pick_whisper()
    return WHISPERS[math.random(#WHISPERS)]
end

local function send()
    if uploading then
        flash("还在送…", 1200)
        return
    end
    if uptime_ms - last_press < SEND_COOLDOWN_MS then
        flash("别急，慢一点", 1200)
        return
    end
    last_press = uptime_ms

    local tok = new_token()
    remember_own(tok)

    send_id = http.request({
        url = NT .. TOPIC,
        method = "POST",
        headers = { ["Title"] = tok },
        body = pick_whisper(),
        timeout_ms = 8000,
        max_response_bytes = 1024,
    })
    uploading = true
    sent = sent + 1

    buzzer.play(1200, 60)
    led.blink("status", 80, 80)
    led_until = uptime_ms + 1200

    flash("已送出", 1200)
    persist()
end

local function poll()
    local since = (last_time > 0) and tostring(last_time) or "1m"
    poll_id = http.request({
        url = NT .. TOPIC .. "/json?poll=1&since=" .. since,
        method = "GET",
        timeout_ms = 8000,
        max_response_bytes = 12000,
    })
    polling = true
end

local function on_peer(text)
    if type(text) ~= "string" or #text < 1 or #text > 480 then
        text = WHISPERS[1]
    end

    buzzer.play(1600, 80)
    buzzer.play(2100, 120)
    led.on("status")
    led_until = uptime_ms + 1500

    -- 启动阶段（源码、on_start、第一次 tick）不允许调用 tts.speak。
    if booted and not speaking and uptime_ms - last_tts >= TTS_COOLDOWN_MS then
        speech_id = tts.speak(text)
        speaking = true
        last_tts = uptime_ms
    end

    flash("有人想你 ♥", 2000)
end

local function process(body)
    for line in string.gmatch(body, "[^\r\n]+") do
        local m = json.decode(line)
        if type(m) == "table" and m.event == "message" and type(m.id) == "string" then
            if m.id ~= seen_id then
                seen_id = m.id
                if type(m.time) == "number" and m.time + 1 > last_time then
                    last_time = math.floor(m.time) + 1
                end
                if not is_own(m.title) then
                    on_peer(m.message)
                end
            end
        end
    end
end

------------------------------------------------------------------
-- 回调
------------------------------------------------------------------
function on_start()
    local seed = clock.now()
    if type(seed) == "number" then
        math.randomseed(seed)
    end

    restore()
    draw()

    if string.find(TOPIC, "CHANGE%-ME") then
        flash("请先设置 TOPIC", 3000)
    end
end

function on_tick(dt_ms)
    uptime_ms = uptime_ms + (dt_ms or 20)
    booted = true -- 首次 tick 之后即视为启动完成，此后允许播报

    if led_until > 0 and uptime_ms >= led_until then
        led.off("status")
        led_until = 0
    end

    if flash_until > 0 and uptime_ms >= flash_until then
        flash_until = 0
        draw()
    end

    if not uploading and not polling and uptime_ms >= next_poll then
        next_poll = uptime_ms + POLL_MS
        poll()
    end
end

function on_button_click(button_id)
    if button_id == "function" then
        send()
    end
end

function on_http_response(id, response)
    if id == send_id then
        uploading = false
        send_id = nil
        local failed = response.error ~= nil
            or (type(response.status) == "number" and response.status >= 400)
        if failed then
            if sent > 0 then
                sent = sent - 1
            end
            flash("没送出去", 1500)
        end
    elseif id == poll_id then
        polling = false
        poll_id = nil
        if response.error == nil and type(response.body) == "string" then
            process(response.body)
        end
    end
end

function on_tts_result(id, result)
    if id == speech_id then
        speaking = false
        speech_id = nil
    end
end

function on_exit()
    persist(true)
end
