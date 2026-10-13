-- 想你机 · Think of You
--
-- 两台 LingClaw，一个键，几种心情。
--
-- 按键只有一个，但「敲几下」已经够用：一下想你、两下在忙、三下吃饭了吗、
-- 四下晚安；五下开一局猜拳，六下两台一起奏一段。送出时本机立刻回你几声、
-- 屏幕上直接显示送出的是哪句；对端在下次轮询里用它自己的声音念出来，
-- 并把你的节奏原样敲回去。
--
-- 还有两样不随消息走、也不靠网络的东西：
--   同频心跳：两台用同一个墙上时钟算节拍，指示灯一起脉动，两个房间一起呼吸。
--   想念会长大：交换累积长成一株像素植物，放着不管会蔫，攒够了开花。
--
-- 依赖：API 4（http / json / tts / clock / storage / screen / led / buzzer）。
-- 设备只能主动轮询、无法被动接收推送，所以两台通过公共中继 ntfy.sh 交换信号：
-- 发送即 POST 到主题，接收即每 POLL_MS 拉一次（对局或合奏期间用 POLL_BUSY_MS）。
--
-- 配对：两台跑完全相同的这一份脚本，只要求同一个 TOPIC，不需要「本机身份」。
-- 自己的回显靠每条消息的随机 token 认出来；「谁演主角」这类角色由
-- 「谁发起了这件事」决定，而这一点双方都能从同一条消息里读出来，所以也
-- 不必区分设备。
--   1. ./flash.sh --topic lingclaw-think-xxxxxxxx
--   2. 手工烧同一份：adb push think-of-you.lua /miniapp/think-of-you.lua

------------------------------------------------------------------
-- 配置
------------------------------------------------------------------
local TOPIC = "lingclaw-think-CHANGE-ME-8f3a" -- ntfy 主题；两台相同，务必改掉
local NT    = "https://ntfy.sh/"

local POLL_MS          = 10000 -- 空闲时的轮询间隔
local POLL_BUSY_MS     = 2000  -- 密集轮询：对局、合奏，或刚有来往时
local ACTIVE_WINDOW_MS = 15000 -- 收到消息后这么久内算"还在聊"，保持密集轮询
local SEND_COOLDOWN_MS = 1200  -- 两次发送之间的最小间隔
local TTS_COOLDOWN_MS  = 2000  -- 两次播报之间的最小间隔
local SAVE_INTERVAL_MS = 11000 -- 存档写入节流（平台最短 10s）

-- 敲几下说什么：下标就是敲的遍数。
-- say 是对端念出来的话，hint 是本机屏幕上的短标签。
local WORDS = {
    { say = "有人在想你。",     hint = "想你" },
    { say = "在忙，等下回你。", hint = "在忙" },
    { say = "吃饭了吗？",       hint = "吃饭了吗" },
    { say = "晚安，好好睡。",   hint = "晚安" },
}
local GESTURE_GAME = #WORDS + 1 -- 五下：开一局猜拳
local GESTURE_SONG = #WORDS + 2 -- 六下：两台合奏一段

local TAP_GAP_MS    = 450 -- 相邻两下的最大间隔，超过就从新的一次算起
local TAP_SETTLE_MS = 700 -- 最后一下之后静默这么久，手势结算
local TAP_MAX       = GESTURE_SONG

-- 心灯：两台用同一个墙上时钟算节拍，相位自然一致，不需要联网同步。
-- 只取「秒钟的整数部分」来定位节拍，两台取整的结果完全相同；
-- 对表越勤，节拍边界被察觉的时间越准（最多晚一次对表的时间）。
local BEAT_MS       = 2000
local BEAT_ON_MS    = 120
local CLOCK_READ_MS = 100

-- 长势：交换喂它，时间让它回落
local GROW_DECAY_SEC = 1800 -- 每半小时掉 1 点，100 点约 50 小时掉光
local GROW_FEED_GOT  = 14   -- 收到一次喂多少
local GROW_FEED_SENT = 8    -- 送出一次喂多少
local GROW_BLOOM     = 90   -- 到这个值开花

-- 合奏：每个音符占一个固定长度的槽，两台按同一条时间轴推进，所以合得上。
-- 0 表示休止；lead 是主旋律，bass 是伴奏，谁演哪个由「谁发起的」决定。
-- 槽刻意放慢到 600ms：墙上时钟只有秒精度，两台的开场最多差约一秒，
-- 慢曲子听上去只是「松」，快曲子会直接散掉。
local STEP_MS       = 600
local SONG_LEAD_SEC = 15 -- 发起后留这么久给对端收信，再一起开始
local SONGS = {
    {
        name = "小星星",
        lead = { 523, 523, 784, 784, 880, 880, 784, 0 },
        bass = { 131, 0, 196, 0, 175, 0, 131, 0 },
    },
}

------------------------------------------------------------------
-- 状态
------------------------------------------------------------------
local uptime_ms = 0
local sent      = 0  -- 本机送出的次数
local got       = 0  -- 收到对端的次数
local last_time = 0  -- 轮询游标：上次已处理消息的时间戳
local seen_id   = "" -- 已处理的最新消息 id（去重）

local last_send = -1e9
local last_tts  = -1e9
local last_save = -1e9

local send_id, poll_id        -- 在途请求 id
local uploading, polling = false, false
local next_poll = 0
local active_until = 0 -- "还在聊"到什么时候：期间用密集轮询

local speaking = false
local speech_id
local booted = false -- 第一次 tick 属于启动阶段，期间禁止播报

local led_until = 0 -- 事件灯占用的截止时刻
local flash_until, flash_msg = 0, ""

-- 手势
local taps, last_tap, tapping = 0, -1e9, false

-- 长势、连续天数、比分
local grow, grow_sec = 0, nil
local bloomed = false
local streak, last_day = 0, ""
local wins, losses, draws = 0, 0, 0

-- 心灯
local clock_sec, clock_at, clock_read = nil, 0, -1e9
local beat_idx, beat_off_at = -1, 0
local grow_check = 0

-- 合奏与对局（同一时刻只会有一个）
local song  -- { part = {...}, start_at = 换算到本机运行时刻的开场时间, cursor = 1 }
local match -- { state = "choose"|"wait", mine = n, theirs = n, until_ms = ... }

local draw, flash -- 前向声明：下面几节里才定义

-- 把下一次轮询提前：对局、合奏，或刚收到消息时用，
-- 别等满一个空闲周期才去收信
local function hurry_poll()
    local soon = uptime_ms + POLL_BUSY_MS
    if next_poll > soon then
        next_poll = soon
    end
end

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
        r = got,
        t = last_time,
        i = seen_id,
        g = math.floor(grow),
        n = grow_sec or 0,
        k = streak,
        d = last_day,
        w = wins,
        l = losses,
        e = draws,
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

    -- 存档可能来自旧版本或是脏数据，逐项校验类型与范围
    local function num(v, lo, hi)
        if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
            return nil
        end
        if v < lo then
            v = lo
        end
        if v > hi then
            v = hi
        end
        return math.floor(v)
    end

    local v = num(saved.s, 0, 1e9)
    if v then sent = v end
    v = num(saved.r, 0, 1e9)
    if v then got = v end
    v = num(saved.t, 0, 1e12)
    if v then last_time = v end
    v = num(saved.g, 0, 100)
    if v then grow = v end
    v = num(saved.n, 0, 1e12)
    if v and v > 0 then grow_sec = v end
    v = num(saved.k, 0, 1e6)
    if v then streak = v end
    v = num(saved.w, 0, 1e9)
    if v then wins = v end
    v = num(saved.l, 0, 1e9)
    if v then losses = v end
    v = num(saved.e, 0, 1e9)
    if v then draws = v end

    if type(saved.i) == "string" and #saved.i <= 24 then
        seen_id = saved.i
    end
    if type(saved.d) == "string" and #saved.d <= 10 then
        last_day = saved.d
    end

    -- 已经是满的就不必再道贺一次（否则每次开机都开花）
    bloomed = grow >= GROW_BLOOM
end

------------------------------------------------------------------
-- 想念的长势
------------------------------------------------------------------
-- 公历日期编号（Howard Hinnant 的 days_from_civil），用来判断「昨天」
local function day_num(y, m, d)
    local yy = (m <= 2) and (y - 1) or y
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local doy = math.floor((153 * (m + ((m > 2) and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe
end

local function today()
    local lt = clock.localtime()
    if type(lt) ~= "table" or type(lt.year) ~= "number" then
        return nil, nil
    end
    return string.format("%04d-%02d-%02d", lt.year, lt.month, lt.day),
        day_num(lt.year, lt.month, lt.day)
end

-- 让长势随时间回落。以墙上时间结算，所以关机多久也算数。
local function grow_update()
    local now = clock.now()
    if type(now) ~= "number" then
        return
    end
    if type(grow_sec) == "number" and now > grow_sec then
        grow = grow - (now - grow_sec) / GROW_DECAY_SEC
        if grow < 0 then
            grow = 0
        end
    end
    grow_sec = now
end

-- 喂一次：涨一点长势，并维护「连续有来有往的天数」
local function feed(amount)
    grow_update()
    grow = grow + amount
    if grow > 100 then
        grow = 100
    end

    local day, dn = today()
    if day and day ~= last_day then
        local prev
        if #last_day == 10 then
            local y  = tonumber(string.sub(last_day, 1, 4))
            local mo = tonumber(string.sub(last_day, 6, 7))
            local d  = tonumber(string.sub(last_day, 9, 10))
            if y and mo and d then
                prev = day_num(y, mo, d)
            end
        end
        if prev and dn == prev + 1 then
            streak = streak + 1
        else
            streak = 1
        end
        last_day = day
    end
end

------------------------------------------------------------------
-- 墙上时间轴
------------------------------------------------------------------
-- 两台设备只能靠轮询通信，延迟以秒计，所以「同时」这件事不能靠消息对齐。
-- 它们各自读自己的墙上时钟，用同一个式子算出节拍和播放进度，相位自然一致。
local function wall_ms()
    if type(clock_sec) ~= "number" then
        return nil
    end
    return clock_sec * 1000 + (uptime_ms - clock_at)
end

------------------------------------------------------------------
-- 画面
------------------------------------------------------------------
-- 屏幕只给矩形和文字，没有图像，所以画面全部是矩形拼的像素画。
-- 每帧最多 128 个矩形、8 段文字；画布 240x240，名义字号 16px。
local function draw_plant()
    local green = (grow >= 40) and 0x7BC96F or 0x5A7A56 -- 蔫了就发灰
    local pot_y = 132
    local height = 6 + math.floor(grow * 0.42)          -- 越高越精神
    local top   = pot_y - 4 - height

    -- 花盆与土
    screen.rect(105, pot_y, 30, 6, 0x8A5A3C)
    screen.rect(99, pot_y + 6, 42, 6, 0x6B4430)
    screen.rect(105, pot_y - 4, 30, 4, 0x3A2A22)

    -- 茎
    screen.rect(117, top, 6, height, green)

    -- 叶子：按长势一片片长出来
    local function leaf(y, right)
        if right then
            screen.rect(123, y, 18, 6, green)
            screen.rect(135, y + 6, 6, 6, green)
        else
            screen.rect(99, y, 18, 6, green)
            screen.rect(93, y + 6, 6, 6, green)
        end
    end
    if grow >= 20 then leaf(top + 28, false) end
    if grow >= 45 then leaf(top + 14, true) end
    if grow >= 70 then leaf(top + 42, true) end

    -- 开花
    if grow >= GROW_BLOOM then
        screen.rect(111, top - 12, 18, 6, 0xFF6B8A)
        screen.rect(105, top - 6, 30, 6, 0xFF6B8A)
        screen.rect(117, top - 18, 6, 6, 0xFFD166)
    end
end

-- 心灯：右上角一个小方块，跟着节拍张缩；两台相位一致所以一起跳
local function draw_beat()
    local on   = beat_off_at > uptime_ms
    local size = on and 12 or 6
    screen.rect(228 - size, 10, size, size, on and 0xFF6B8A or 0x5A2E3A)
end

draw = function()
    screen.begin(0x1A0F1E)

    screen.text("想你机", 12, 8, 0xFFD9E2)
    draw_beat()

    if streak > 0 then
        screen.text("连续 " .. streak .. " 天", 12, 32, 0xFFB3C7)
    else
        screen.text("今天刚开始", 12, 32, 0x8A7A86)
    end

    draw_plant()

    screen.text("送出 " .. sent .. "  收到 " .. got, 12, 154, 0xFFFFFF)

    if tapping then
        local hint = (taps <= #WORDS) and WORDS[taps].hint or "再敲就多了"
        screen.text("敲了 " .. taps .. " 下：" .. hint, 12, 178, 0xFFD166)
    elseif uptime_ms < flash_until then
        screen.text(flash_msg, 12, 178, 0xFFD166)
    elseif uploading then
        screen.text("正在送去…", 12, 178, 0x8FE3C4)
    elseif grow < 20 then
        screen.text("好久没人惦记它了", 12, 178, 0x9AA7B8)
    else
        screen.text("按下，就有人在想你", 12, 178, 0x9AA7B8)
    end

    if match then
        local line
        if match.text then
            line = match.text
        elseif match.mine and not match.theirs then
            line = "猜拳：已出招，等对方"
        elseif match.theirs and not match.mine then
            line = "猜拳：对方出了，敲1-3"
        elseif match.mine and match.theirs then
            line = "猜拳：开"
        else
            line = "猜拳：敲1-3出招"
        end
        screen.text(line, 12, 202, 0x8FE3C4)
    elseif song then
        screen.text("合奏：" .. song.name, 12, 202, 0x8FE3C4)
    else
        screen.text("敲1-4传话 5猜拳 6合奏", 12, 202, 0x6C7A8C)
    end

    screen.text("主题 …" .. string.sub(TOPIC, -4), 12, 222, 0x6C7A8C)
    screen.present()
end

flash = function(msg, ms)
    flash_msg = msg
    flash_until = uptime_ms + (ms or 1500)
    draw()
end

------------------------------------------------------------------
-- 消息
------------------------------------------------------------------
-- 消息体是「类型|参数」的短文本。没有前缀的一律当普通文本念，
-- 这样对面就算还跑着旧版脚本也依然能说话。
--   w|<n>            敲了 n 下的短语（n 是 WORDS 的下标）
--   m|<曲>|<起始秒>   合奏：发起方奏主旋律，被叫方奏伴奏
--   r|<动作>         猜拳：1 石头、2 剪刀、3 布；0 表示想开一局
local function post(body)
    local tok = new_token()
    remember_own(tok)
    send_id = http.request({
        url = NT .. TOPIC,
        method = "POST",
        headers = { ["Title"] = tok },
        body = body,
        timeout_ms = 8000,
        max_response_bytes = 1024,
    })
    uploading = true
    sent = sent + 1
    feed(GROW_FEED_SENT)
end

local function speak(text)
    -- 启动阶段（源码、on_start、第一次 tick）不允许调用 tts.speak
    if booted and not speaking and uptime_ms - last_tts >= TTS_COOLDOWN_MS then
        speech_id = tts.speak(text)
        speaking = true
        last_tts = uptime_ms
    end
end

-- 收到一条有效消息后的共同动作：计数、喂长势、亮灯、念出来
local function received(say)
    got = got + 1
    feed(GROW_FEED_GOT)
    led.on("status")
    led_until = uptime_ms + 1500
    -- 有人说话就说明可能还在聊：这段时间把轮询加密，好让来回更快
    active_until = uptime_ms + ACTIVE_WINDOW_MS
    hurry_poll()
    if say then
        speak(say)
    end
    persist()
end

------------------------------------------------------------------
-- 发送
------------------------------------------------------------------
local function can_send()
    if uploading then
        flash("还在送…", 1000)
        return false
    end
    if uptime_ms - last_send < SEND_COOLDOWN_MS then
        flash("别急，慢一点", 1000)
        return false
    end
    last_send = uptime_ms
    return true
end

local function send_whisper(n)
    if not can_send() then
        return
    end
    post("w|" .. n)
    for _ = 1, n do
        buzzer.play(1180, 50) -- 敲了几下，本机就回几声
    end
    led.blink("status", 70, 70)
    led_until = uptime_ms + 900
    flash("已送出：" .. WORDS[n].hint, 1600)
    persist()
end

------------------------------------------------------------------
-- 合奏
------------------------------------------------------------------
-- 谁演哪个声部由「谁发起的」决定：发起方奏主旋律，被叫方奏伴奏。
-- 双方都从消息里那个绝对起始秒开始推进，所以两个房间合起来是一段曲子。
local function begin_song(index, start_sec, leading)
    local track = SONGS[index]
    if not track then
        return false
    end
    -- 消息里带的是绝对起始秒，这里换成本机的运行时刻，之后只用单调时钟推进：
    -- wall_ms 每次对表都会跳一下（墙上只有秒精度），不能拿它当播放基准。
    local wm = wall_ms()
    if not wm then
        return false
    end
    song = {
        name     = track.name,
        part     = leading and track.lead or track.bass,
        start_at = uptime_ms + (start_sec * 1000 - wm),
        cursor   = 1,
    }
    return true
end

local function start_song()
    if song then
        flash("正在合奏", 1200)
        return
    end
    local now = clock.now()
    if type(now) ~= "number" then
        flash("没校时，先连上网", 2200)
        return
    end
    if not can_send() then
        return
    end
    local index = math.random(#SONGS)
    local start_sec = now + SONG_LEAD_SEC
    post("m|" .. index .. "|" .. start_sec)
    begin_song(index, start_sec, true)
    hurry_poll()
    flash("合奏 " .. SONGS[index].name, 1800)
    persist()
end

local function peer_song(index, start_sec)
    if not index or not start_sec then
        return
    end
    local wm = wall_ms()
    if not wm or wm >= start_sec * 1000 then
        return -- 收到时已经开场了，不要插进半个曲子
    end
    if not begin_song(index, start_sec, false) then
        return
    end
    hurry_poll()
    buzzer.play(1560, 90)
    received("一起听 " .. SONGS[index].name)
    flash("合奏 " .. SONGS[index].name, 1800)
end

local function tick_song()
    if not song then
        return
    end
    local elapsed = uptime_ms - song.start_at
    if elapsed < 0 then
        return
    end
    -- 蜂鸣器队列只有 4 格、满了会丢弃，所以按时间轴一个槽一个槽地推
    if elapsed + 40 >= (song.cursor - 1) * STEP_MS then
        local hz = song.part[song.cursor]
        if hz and hz > 0 then
            buzzer.play(hz, STEP_MS - 20)
        end
        song.cursor = song.cursor + 1
        if song.cursor > #song.part then
            song = nil
            draw()
        end
    end
end

------------------------------------------------------------------
-- 猜拳
------------------------------------------------------------------
local MOVES            = { "石头", "剪刀", "布" }
local MATCH_TIMEOUT_MS = 60000 -- 一局最多等这么久
local MATCH_DONE_MS    = 6000  -- 结算结果在屏幕上留这么久

local function beats(a, b)
    -- 石头胜剪刀、剪刀胜布、布胜石头
    return (a == 1 and b == 2) or (a == 2 and b == 3) or (a == 3 and b == 1)
end

local function settle()
    local mine, theirs = match.mine, match.theirs
    if not mine or not theirs then
        return
    end

    local text, say
    if mine == theirs then
        draws = draws + 1
        text, say = "平手", "平手，再来一局？"
    elseif beats(mine, theirs) then
        wins = wins + 1
        text, say = "你赢了", "你赢了，厉害。"
    else
        losses = losses + 1
        text, say = "你输了", "这局你输了，再来。"
    end

    match.text = text .. "  " .. MOVES[mine] .. " 对 " .. MOVES[theirs]
    match.until_ms = uptime_ms + MATCH_DONE_MS
    buzzer.play(1320, 90)
    buzzer.play(1760, 140)
    led.blink("status", 60, 60)
    led_until = uptime_ms + 1200
    speak(say)
    persist(true)
    draw()
end

local function start_match()
    if match and not match.text then
        flash("正在猜拳", 1200)
        return
    end
    if not can_send() then
        return
    end
    post("r|0")
    match = { until_ms = uptime_ms + MATCH_TIMEOUT_MS }
    hurry_poll()
    buzzer.play(880, 80)
    flash("开一局猜拳", 1500)
    persist()
end

local function choose_move(n)
    if not match or match.text or match.mine then
        return
    end
    if not can_send() then
        return
    end
    match.mine = n
    post("r|" .. n)
    buzzer.play(1240, 60)
    if match.theirs then
        settle()
    else
        flash("你出了" .. MOVES[n], 1200)
    end
end

local function peer_move(n)
    if not n then
        return
    end
    if n == 0 then
        -- 对方想开一局
        if not match then
            match = { until_ms = uptime_ms + MATCH_TIMEOUT_MS }
        end
        hurry_poll()
        buzzer.play(880, 80)
        buzzer.play(1320, 80)
        received("想跟你猜拳。")
        flash("对方想猜拳", 1800)
        return
    end
    if n < 1 or n > 3 then
        return
    end
    if not match then
        match = { until_ms = uptime_ms + MATCH_TIMEOUT_MS }
    end
    match.theirs = n
    buzzer.play(1100, 70)
    if match.mine then
        settle() -- 两边的出招都齐了，各自算出同一个结果
    else
        received("我出好了，到你了。")
        flash("对方出了，敲1-3", 1800)
    end
end

local function tick_match()
    if not match then
        return
    end
    if uptime_ms < match.until_ms then
        return
    end
    if not match.text then
        flash("这局算了", 1500)
    end
    match = nil
    draw()
end

------------------------------------------------------------------
-- 手势：单击是唯一的输入，靠「敲几下 + 间隔」表达
------------------------------------------------------------------
local function resolve_gesture(n)
    if match and not match.text then
        -- 对局中：1/2/3 下就是出招
        if n >= 1 and n <= 3 then
            choose_move(n)
        else
            flash("出招只敲 1-3 下", 1200)
        end
        return
    end
    if n >= GESTURE_SONG then
        start_song()
    elseif n >= GESTURE_GAME then
        start_match()
    else
        send_whisper(n)
    end
end

local function tick_gesture()
    if tapping and uptime_ms - last_tap >= TAP_SETTLE_MS then
        tapping = false
        local n = taps
        taps = 0
        resolve_gesture(n)
    end
end

------------------------------------------------------------------
-- 心灯
------------------------------------------------------------------
-- 两台各自用墙上时钟算节拍，所以相位一致；一拍灯亮一小下、屏幕上的方块张一次。
-- 有事件（发送、收到、结算）时不跟事件抢灯。
-- 心灯节拍：只用秒钟的整数部分定位，两台取整结果完全相同
local function beat_sec()
    if type(clock_sec) == "number" then
        return clock_sec
    end
    return math.floor(uptime_ms / 1000) -- 没校时就退化成自己的节奏，只是两台不同频
end

local function tick_beat()
    local idx = math.floor(beat_sec() / (BEAT_MS / 1000))
    if idx ~= beat_idx then
        beat_idx = idx
        beat_off_at = uptime_ms + BEAT_ON_MS
        if led_until == 0 or uptime_ms >= led_until then
            led.on("status")
        end
        draw()
    elseif beat_off_at > 0 and uptime_ms >= beat_off_at then
        beat_off_at = 0
        if led_until == 0 or uptime_ms >= led_until then
            led.off("status")
        end
        draw()
    end
end

------------------------------------------------------------------
-- 轮询与收信
------------------------------------------------------------------
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

local function handle_peer(body)
    if type(body) ~= "string" or #body < 1 or #body > 480 then
        return
    end

    local kind, rest = string.match(body, "^([a-z])|(.+)$")
    if kind == "w" then
        local n = tonumber(string.match(rest, "^(%d+)"))
        if not n or n < 1 then
            n = 1
        end
        if n > #WORDS then
            n = #WORDS
        end
        for _ = 1, n do
            buzzer.play(1560, 70) -- 把你的节奏原样敲回去
        end
        buzzer.play(2100, 120)
        received(WORDS[n].say)
        flash("有人想你：" .. WORDS[n].hint, 2200)
    elseif kind == "m" then
        local index, start_sec = string.match(rest, "^(%d+)|(%d+)$")
        peer_song(tonumber(index), tonumber(start_sec))
    elseif kind == "r" then
        peer_move(tonumber(string.match(rest, "^(%d+)")))
    elseif #body <= 200 then
        buzzer.play(1600, 80)
        buzzer.play(2100, 120)
        received(body) -- 旧版对端发来的自由文本
        flash("有人想你 ♥", 2000)
    end
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
                    handle_peer(m.message)
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
        clock_sec, clock_at = seed, 0
    end

    restore()
    draw()

    if string.find(TOPIC, "CHANGE%-ME") then
        flash("请先设置 TOPIC", 3000)
    end
end

function on_tick(dt_ms)
    uptime_ms = uptime_ms + (dt_ms or 20)
    booted = true -- 第一次 tick 之后即视为启动完成，此后允许播报

    -- 每 CLOCK_READ_MS 对一次墙上时间；心灯相位与合奏开场都以它为准
    if uptime_ms - clock_read >= CLOCK_READ_MS then
        clock_read = uptime_ms
        local now = clock.now()
        if type(now) == "number" then
            clock_sec, clock_at = now, uptime_ms
        end
    end

    if led_until > 0 and uptime_ms >= led_until then
        led.off("status")
        led_until = 0
    end

    tick_beat()
    tick_gesture()
    tick_song()
    tick_match()

    -- 长势每半分钟结算一次（回落按墙上时间算），够攒到开花就道贺一次
    if uptime_ms - grow_check >= 30000 then
        grow_check = uptime_ms
        grow_update()
        if grow >= GROW_BLOOM and not bloomed then
            bloomed = true
            flash("它开花了 ♥", 2500)
            speak("你把它养开花了。")
            persist(true)
        end
    end

    if flash_until > 0 and uptime_ms >= flash_until then
        flash_until = 0
        draw()
    end

    if not uploading and not polling and uptime_ms >= next_poll then
        -- 对局、合奏，或刚有来往：把轮询加快，之后自己退回去
        local busy = (match ~= nil) or (song ~= nil) or (uptime_ms < active_until)
        next_poll = uptime_ms + (busy and POLL_BUSY_MS or POLL_MS)
        poll()
    end
end

function on_button_click(button_id)
    if button_id ~= "function" then
        return
    end

    -- 间隔超过 TAP_GAP_MS 说明上一串已经断了：先把它结算掉再开新的一串，
    -- 否则「慢慢地敲两下」里前面那一下会被直接丢掉。
    if tapping and uptime_ms - last_tap > TAP_GAP_MS then
        tapping = false
        local n = taps
        taps = 0
        resolve_gesture(n)
    end

    if not tapping then
        taps = 0
        tapping = true
    end
    taps = taps + 1
    if taps > TAP_MAX then
        taps = TAP_MAX
    end
    last_tap = uptime_ms
    buzzer.play(1480, 35) -- 每敲一下先回一声
    draw()                -- 屏幕上即时显示敲到第几下
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
