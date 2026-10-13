-- 想你机 · 打桩验证（无需 Rust 模拟器）
--
-- 在标准 Lua 里加载 think-of-you.lua，用符合 LingClaw API 契约的替身驱动完整流程：
-- 启动、轮询、自过滤、敲击手势、对端播报、成长、心灯、合奏、猜拳、存档恢复。
-- 替身按文档校验参数（矩形越界、每帧矩形 ≤128 / 文字 ≤8、文字 63 字节、
-- TTS 512 字节且并发唯一、存档 32 项 / 1024 字节等），越界即报错。
--
-- 运行（在本项目根目录）：
--   lua tests/mock_think.lua
--   lua tests/mock_think.lua think-of-you.lua

local APP = (arg and arg[1]) or "think-of-you.lua"

------------------------------------------------------------------
-- 断言与计数器
------------------------------------------------------------------
local pass, fail = 0, 0
local function ok(cond, label)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        print("  FAIL: " .. label)
    end
end

local calls
local pending
local next_id
local startup
local store
local tts_open
local tts_seq
local clock_ms
local clock_date

------------------------------------------------------------------
-- 最小 JSON 解码（够用于 ntfy 的扁平对象）
------------------------------------------------------------------
local JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })

local function json_decode(s)
    if type(s) ~= "string" then return nil, "type" end
    local i, n = 1, #s
    local function skip() while i <= n and s:sub(i, i):match("%s") do i = i + 1 end end
    skip()
    if s:sub(i, i) ~= "{" then return nil, "not object" end
    local obj = {}
    i = i + 1
    while true do
        skip()
        local ch = s:sub(i, i)
        if ch == "}" then i = i + 1 break end
        if ch == "," then i = i + 1 skip() ch = s:sub(i, i) end
        if ch ~= '"' then return nil, "key" end
        i = i + 1
        local kb = i
        while i <= n and s:sub(i, i) ~= '"' do
            if s:sub(i, i) == "\\" then i = i + 1 end
            i = i + 1
        end
        local key = s:sub(kb, i - 1)
        i = i + 1
        skip()
        if s:sub(i, i) ~= ":" then return nil, "colon" end
        i = i + 1
        skip()
        local c = s:sub(i, i)
        local val
        if c == '"' then
            i = i + 1
            local vb = i
            while i <= n and s:sub(i, i) ~= '"' do
                if s:sub(i, i) == "\\" then i = i + 1 end
                i = i + 1
            end
            val = s:sub(vb, i - 1)
            i = i + 1
            val = val:gsub("\\n", "\n"):gsub('\\"', '"'):gsub("\\\\", "\\")
        elseif c == "t" then val = true i = i + 4
        elseif c == "f" then val = false i = i + 5
        elseif c == "n" then val = JSON_NULL i = i + 4
        else
            local vb = i
            while i <= n and s:sub(i, i):match("[%d%.eE%+%-]") do i = i + 1 end
            val = tonumber(s:sub(vb, i - 1))
        end
        obj[key] = val
    end
    return obj
end

------------------------------------------------------------------
-- 安装替身
------------------------------------------------------------------
local function reset_mocks()
    calls = {
        rects = 0, texts = 0, presents = 0,
        frame_rects = 0, frame_texts = 0, max_rects = 0, max_texts = 0,
        buzzer = {}, tts = {}, led = { on = 0, off = 0, blink = 0 }, saves = {},
    }
    pending = {}
    next_id = 0
    startup = true
    tts_open = false
    tts_seq = 0
    clock_ms = 1790900000 * 1000
    clock_date = { year = 2026, month = 10, day = 13 }

    _G.app = { api_version = 4, width = 240, height = 240 }

    _G.screen = {
        begin = function(c)
            calls.bg = c
            calls.frame_rects = 0
            calls.frame_texts = 0
            calls.frame_text = {}
        end,
        rect = function(x, y, w, h, c)
            ok(x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= 240 and y + h <= 240,
                "rect 越界: " .. x .. "," .. y .. " " .. w .. "x" .. h)
            calls.rects = calls.rects + 1
            calls.frame_rects = calls.frame_rects + 1
        end,
        text = function(s, x, y, c)
            ok(#s <= 63, "文字超过 63 字节: " .. #s)
            ok(x >= 0 and y >= 0 and y <= 224, "文字坐标越界: " .. y)
            calls.texts = calls.texts + 1
            calls.frame_texts = calls.frame_texts + 1
            calls.frame_text[calls.frame_texts] = s
        end,
        present = function()
            ok(calls.frame_rects <= 128, "每帧矩形超过 128 个: " .. calls.frame_rects)
            ok(calls.frame_texts <= 8, "每帧文字超过 8 段: " .. calls.frame_texts)
            if calls.frame_rects > calls.max_rects then calls.max_rects = calls.frame_rects end
            if calls.frame_texts > calls.max_texts then calls.max_texts = calls.frame_texts end
            calls.last_frame = calls.frame_text
            calls.presents = calls.presents + 1
        end,
    }

    _G.led = {
        on = function(id) calls.led.on = calls.led.on + 1 end,
        off = function(id) calls.led.off = calls.led.off + 1 end,
        blink = function(id, a, b)
            ok(a >= 10 and a <= 5000 and b >= 10 and b <= 5000, "blink 时长越界")
            calls.led.blink = calls.led.blink + 1
        end,
    }

    _G.buzzer = {
        play = function(hz, ms)
            ok(hz >= 100 and hz <= 5000, "蜂鸣频率越界: " .. hz)
            ok(ms >= 20 and ms <= 3000, "蜂鸣时长越界: " .. ms)
            calls.buzzer[#calls.buzzer + 1] = { hz, ms }
        end,
    }

    -- 墙上时间与运行时间一起推进，才测得出合奏的开场对齐与长势回落
    _G.clock = {
        now = function() return math.floor(clock_ms / 1000) end,
        localtime = function()
            return {
                year = clock_date.year, month = clock_date.month, day = clock_date.day,
                hour = 12, min = 0, sec = 0, wday = 4, utc_offset = 0,
            }
        end,
    }

    _G.storage = {
        save = function(t, ttl)
            local count, total = 0, 0
            for k, v in pairs(t) do
                count = count + 1
                ok(#k <= 32, "存档键超过 32 字节")
                local vt = type(v)
                ok(vt == "number" or vt == "boolean" or vt == "string", "存档值类型非法")
                if vt == "number" then ok(v == v and v ~= math.huge and v ~= -math.huge, "存档数字非有限") end
                if vt == "string" then ok(#v <= 256, "存档字符串超过 256 字节") end
                total = total + #k + ((vt == "string") and #v or 8) + 4
            end
            ok(count <= 32, "存档项超过 32")
            ok(total <= 1024, "存档超过 1024 字节: " .. total)
            local copy = {}
            for k, v in pairs(t) do copy[k] = v end
            store = copy
            calls.saves[#calls.saves + 1] = copy
            return true
        end,
        load = function()
            if not store then return nil end
            local copy = {}
            for k, v in pairs(store) do copy[k] = v end
            return copy
        end,
        clear = function() store = nil return true end,
    }

    local function validate_http(o)
        ok(type(o) == "table", "http 参数非表")
        ok(type(o.url) == "string" and #o.url <= 511, "url 超过 511 字节")
        ok(o.url:find("^https?://") ~= nil, "url 缺少 scheme")
        local m = o.method or "GET"
        ok(m == "GET" or m == "POST", "method 非法")
        if o.headers then
            local hn, hb = 0, 0
            for k, v in pairs(o.headers) do
                hn = hn + 1
                hb = hb + #k + #v + 4
            end
            ok(hn <= 16, "请求头超过 16 项")
            ok(hb <= 1024, "请求头超过 1024 字节")
        end
        if o.body then
            ok(m == "POST", "body 仅 POST 可用")
            ok(#o.body <= 8192, "body 超过 8192 字节")
        end
        if o.timeout_ms then ok(o.timeout_ms <= 60000, "timeout 超过 60000") end
        if o.max_response_bytes then ok(o.max_response_bytes <= 32768, "响应上限超过 32768") end
    end

    _G.http = {
        request = function(o)
            validate_http(o)
            next_id = next_id + 1
            pending[next_id] = { opts = o }
            return next_id
        end,
        cancel = function(id) pending[id] = nil return true end,
    }
    _G.http.get = function(url, o)
        o = o or {}
        o.url = url
        o.method = o.method or "GET"
        return _G.http.request(o)
    end

    _G.tts = {
        speak = function(text)
            ok(not startup, "启动期间不允许播报")
            ok(type(text) == "string" and #text > 0 and #text <= 512, "播报文本非法")
            ok(not tts_open, "并发播报超过 1 个")
            calls.tts[#calls.tts + 1] = text
            tts_open = true
            tts_seq = tts_seq + 1
            return tts_seq
        end,
        cancel = function(id) return true end,
    }

    _G.json = { decode = json_decode, null = JSON_NULL }
end

------------------------------------------------------------------
-- 驱动
------------------------------------------------------------------
local TOPIC = io.open(APP):read("a"):match('local TOPIC%s*=%s*"([^"]+)"')

local function boot()
    reset_mocks()
    dofile(APP) -- 应用通过定义全局回调工作，不返回 chunk
    ok(type(on_start) == "function", "缺少 on_start")
    ok(type(on_tick) == "function", "缺少 on_tick")
    on_start()
    on_tick(20) -- 启动阶段的第一次 tick
    startup = false
    return true
end

-- 推进时间：运行时间和墙上时钟一起走，按真实的 20ms 步长跑
local function advance(ms)
    local left = ms
    while left > 0 do
        local d = (left > 20) and 20 or left
        clock_ms = clock_ms + d
        on_tick(d)
        left = left - d
    end
end

-- 只把墙上时钟往前跳，不推进运行时间（用来测长势按真实时间回落）
local function jump_wall(sec)
    clock_ms = clock_ms + sec * 1000
end

local function first_request(kind)
    local found_id, found_opts
    for id, p in pairs(pending) do
        if kind == "poll" and p.opts.url:find("/json%?poll=1") then found_id, found_opts = id, p.opts end
        if kind == "post" and p.opts.method == "POST" then found_id, found_opts = id, p.opts end
    end
    return found_id, found_opts
end

-- 投递一次响应：先移除在途请求，再触发应用回调（模拟运行器的交付语义）
local function deliver(id, response)
    if id then pending[id] = nil end
    on_http_response(id, response)
end

-- 把在途的 POST 收尾，否则 uploading 一直为真，后面再也发不出去
local function flush_post(response)
    local id = first_request("post")
    if id then
        deliver(id, response or { status = 200, content_type = "application/json", body = "{}" })
    end
    return id
end

local function flush_poll(body)
    local id = first_request("poll")
    if id then
        deliver(id, {
            status = 200,
            content_type = "application/x-ndjson",
            body = body or "",
        })
    end
    return id
end

-- 模拟播报结束：运行器用 on_tts_result 释放播报槽，不释放就再也播不出下一条
local function finish_speech()
    if tts_open then
        tts_open = false
        on_tts_result(tts_seq, { status = "completed" })
    end
end

-- 敲 n 下算一个手势。间隔 200ms（小于 450ms 的手势间隔），
-- 最后等 2s：700ms 让手势结算，剩下的越过 1200ms 的发送冷却，
-- 这样连着敲几次都发得出去。
local function tap(n, pad)
    for i = 1, n do
        if i > 1 then advance(200) end
        on_button_click("function")
    end
    advance(pad or 2000)
end

local function line(id, t, title, message)
    return string.format('{"id":"%s","time":%d,"event":"message","topic":"%s","title":"%s","message":"%s"}',
        id, t, TOPIC, title, message)
end

-- 收一批对端消息
local function peer_batch(...)
    local body = table.concat({ ... }, "\n")
    flush_poll(body)
    return body
end

-- 蜂鸣序列里第 from 个之后出现的音（挑出旋律音，忽略提示音）
local function tones(from)
    local out = {}
    for i = from, #calls.buzzer do
        out[#out + 1] = calls.buzzer[i][1]
    end
    return out
end

local function has(sub, s)
    return string.find(s or "", sub, 1, true) ~= nil
end

print("== 想你机 打桩验证 ==")
print("应用: " .. APP)
print("TOPIC=" .. TOPIC)

------------------------------------------------------------------
-- 场景用的小工具
------------------------------------------------------------------
-- 等到应用真的发出一次轮询，再把它当作收信通道投递（轮询是唯一的收信方式）
local function next_poll_batch(...)
    local waited = 0
    while waited < 20000 and not first_request("poll") do
        advance(100)
        waited = waited + 100
    end
    return peer_batch(...)
end

-- 最近一帧画面上有没有出现这段文字
local function screen_has(sub)
    for _, s in ipairs(calls.last_frame or {}) do
        if string.find(s, sub, 1, true) then
            return true
        end
    end
    return false
end

-- 数一数在途的 POST
local function pending_posts()
    local n = 0
    for _, p in pairs(pending) do
        if p.opts.method == "POST" then
            n = n + 1
        end
    end
    return n
end

------------------------------------------------------------------
-- 1. 启动
------------------------------------------------------------------
print("\n[1] 启动、首帧、轮询调度")
ok(boot(), "启动成功")
ok(calls.presents >= 1, "启动阶段至少提交一帧")
ok(calls.max_rects <= 128 and calls.max_texts <= 8,
    "每帧绘制量在限额内（" .. calls.max_rects .. " 矩形 / " .. calls.max_texts .. " 文字）")
local poll_id, poll_opts = first_request("poll")
ok(poll_id ~= nil, "首次 tick 后应发起轮询")
ok(poll_opts and poll_opts.url:find("since=1m") ~= nil, "首次轮询使用 since=1m")
ok(poll_opts and poll_opts.url:find("^https://ntfy%.sh/") == 1, "轮询走 ntfy")

------------------------------------------------------------------
-- 2. 收信
------------------------------------------------------------------
print("\n[2] 轮询响应：对端播报与节奏回敲")
local tts_before2 = #calls.tts
local buzzer_before2 = #calls.buzzer
deliver(poll_id, {
    status = 200,
    content_type = "application/x-ndjson",
    body = line("peer-1", 1790900011, "8A31F0C2", "w|2"),
})
ok(#calls.tts == tts_before2 + 1, "收到 w|2 应播报一次")
ok(calls.tts[#calls.tts] == "在忙，等下回你。", "w|2 应念第二句")
ok(#calls.buzzer - buzzer_before2 == 3, "w|2 应把两下的节奏敲回来，再加一声提示")
ok(screen_has("在忙"), "屏幕应显示收到的是哪句")
finish_speech()

advance(2500) -- 越过两次播报的最小间隔
local tts_before2b = #calls.tts
next_poll_batch(line("peer-2", 1790900012, "1E4B77A9", "老版本发来的一句话"))
ok(#calls.tts == tts_before2b + 1, "旧版对端的自由文本也要播报")
ok(calls.tts[#calls.tts] == "老版本发来的一句话", "念的应是原文")
finish_speech()

------------------------------------------------------------------
-- 3. 游标
------------------------------------------------------------------
print("\n[3] 游标推进")
for _ = 1, 300 do
    if first_request("poll") then break end
    advance(100)
end
local _, after2 = first_request("poll")
ok(after2 and after2.url:find("since=1790900013") ~= nil,
    "游标应为最后一条消息时间+1，实际 " .. tostring(after2 and after2.url))

------------------------------------------------------------------
-- 4. 脏数据
------------------------------------------------------------------
print("\n[4] 脏数据容错")
local tts_before4 = #calls.tts
peer_batch("not json", '{"event":"open","id":"x"}')
ok(#calls.tts == tts_before4, "脏数据不应触发播报")

------------------------------------------------------------------
-- 5. 手势
------------------------------------------------------------------
print("\n[5] 敲击手势：敲几下就是哪句")
tap(1, 900)
local post_id1, post1 = first_request("post")
ok(post_id1 ~= nil, "敲一下应发出一条消息")
ok(post1 and post1.body == "w|1", "敲一下是 w|1，实际 " .. tostring(post1 and post1.body))
ok(post1 and post1.url == "https://ntfy.sh/" .. TOPIC, "POST 到同一主题")
local SELF_TOKEN = post1 and post1.headers and post1.headers["Title"]
ok(type(SELF_TOKEN) == "string" and SELF_TOKEN:match("^%x%x%x%x%x%x%x%x$") ~= nil,
    "Title 应为本条消息的 8 位随机 token")
ok(screen_has("已送出：想你"), "本机应立即显示送出的是哪句")
flush_post()

tap(3)
local _, post3 = first_request("post")
ok(post3 and post3.body == "w|3", "敲三下是 w|3，实际 " .. tostring(post3 and post3.body))
flush_post()

print("\n[5b] 敲得慢：前面那一下不能丢")
advance(1500) -- 越过发送冷却
on_button_click("function")
advance(600) -- 间隔 600ms，超过 450ms 的手势间隔，但还没到 700ms 的静默结算
on_button_click("function")
local _, slow1 = first_request("post")
ok(slow1 and slow1.body == "w|1", "间隔过大时，前面那一下应先自成一次，实际 "
    .. tostring(slow1 and slow1.body))
flush_post()
advance(1600)
ok(pending_posts() == 0, "紧挨着的第二下会撞上冷却，应被拦住")

------------------------------------------------------------------
-- 6. 冷却
------------------------------------------------------------------
print("\n[6] 连点冷却")
advance(1500)
tap(1, 800)
flush_post()
advance(100)
on_button_click("function")
advance(800) -- 结算时距上次送出只有 900ms
ok(pending_posts() == 0, "冷却期内不应重复发送")

------------------------------------------------------------------
-- 7. 发送失败
------------------------------------------------------------------
print("\n[7] 发送失败要回滚")
advance(1500)
tap(1)
local post7 = first_request("post")
ok(post7 ~= nil, "冷却过后应能再发")
deliver(post7, { error = { code = "network_error", message = "x" } })
ok(screen_has("没送出去"), "失败应显示「没送出去」")

------------------------------------------------------------------
-- 8. 回显自过滤
------------------------------------------------------------------
print("\n[8] 回显自过滤（token）")
advance(2500)
local tts_before8 = #calls.tts
next_poll_batch(
    line("self-echo", 1790900100, SELF_TOKEN, "w|1"),
    line("peer-x", 1790900101, "1E4B77A9", "w|3"))
ok(#calls.tts == tts_before8 + 1, "自己的回显应被过滤，只播报对端那条")
ok(calls.tts[#calls.tts] == "吃饭了吗？", "播报内容应为对端第三句")
finish_speech()

------------------------------------------------------------------
-- 9. 想念会长大
------------------------------------------------------------------
print("\n[9] 想念会长大：长势与连续天数")
reset_mocks()
dofile(APP)
on_start()
on_tick(20)
startup = false
advance(1200)

tap(1)
flush_post()
ok(type(store) == "table" and type(store.g) == "number" and store.g >= 8,
    "送出一次应喂长势，g=" .. tostring(store and store.g))
ok(store and store.d == "2026-10-13", "应记住今天，d=" .. tostring(store and store.d))
ok(store and store.k == 1, "第一天连续天数为 1，k=" .. tostring(store and store.k))

clock_date.day = 14
advance(12000) -- 越过 11 秒的存档节流
tap(1)
flush_post()
ok(store and store.k == 2, "第二天接着来应有 2 天连续，k=" .. tostring(store and store.k))
ok(store and store.d == "2026-10-14", "日期应换成今天")

clock_date.day = 16
advance(12000)
tap(1)
flush_post()
ok(store and store.k == 1, "中间断了一天就该重头算，k=" .. tostring(store and store.k))

print("\n[9b] 放着不管会回落（按真实时间，不是按运行时间）")
reset_mocks()
store = { s = 0, g = 100, n = 1790900000, k = 1, d = "2026-10-13", t = 1790900000 }
dofile(APP)
on_start()
on_tick(20)
startup = false
advance(1200)
jump_wall(36000) -- 墙上时间跳过 10 小时：每半小时掉 1 点，该掉 20 点
advance(30100)   -- 长势巡检每 30 秒跑一次
tap(1)           -- 送一次（+8），顺带把长势写进存档
flush_post()
ok(store and store.g and store.g <= 90, "长势应按真实时间回落，g=" .. tostring(store and store.g))

------------------------------------------------------------------
-- 10. 开花
------------------------------------------------------------------
print("\n[10] 攒够了会开花")
reset_mocks()
store = { s = 0, g = 88, n = 1790900000, k = 1, d = "2026-10-13", t = 1790900000 }
dofile(APP)
on_start()
on_tick(20)
startup = false
advance(1200)
tap(1) -- +8，越过 90 的开花线
flush_post()

local bloom_seen = false
local tts_before10 = #calls.tts
for _ = 1, 400 do
    advance(100)
    if screen_has("开花了") then
        bloom_seen = true
        break
    end
end
ok(bloom_seen, "长势过线应报「它开花了」")
ok(#calls.tts > tts_before10, "开花时应该说一句")
finish_speech()

------------------------------------------------------------------
-- 11. 心灯
------------------------------------------------------------------
print("\n[11] 心灯：两台用同一个秒钟定节拍，不需要联网同步")
reset_mocks()
clock_ms = 1790900000 * 1000 -- 站在偶数秒边界上
clock_date = { year = 2026, month = 10, day = 13 }
dofile(APP)
on_start()
on_tick(20)
startup = false
ok(calls.led.on >= 1, "开机时正站在偶数秒边界，第一拍就该亮")

local on_even = calls.led.on
advance(1000) -- 走到奇数秒：不属于任何一拍
ok(calls.led.on == on_even, "奇数秒里不该多亮一拍")
advance(2000) -- 回到偶数秒
ok(calls.led.on > on_even, "回到偶数秒又该亮一拍")

------------------------------------------------------------------
-- 12. 合奏
------------------------------------------------------------------
print("\n[12] 合奏：发起方奏主旋律")
reset_mocks()
dofile(APP)
on_start()
on_tick(20)
startup = false
advance(1200)

tap(6)
local song_post_id, song_post = first_request("post")
ok(song_post_id ~= nil, "六下应发出合奏邀请")
local kind, song_i, start_sec
if song_post then
    kind, song_i, start_sec = string.match(song_post.body, "^(%a)|(%d+)|(%d+)$")
end
ok(kind == "m" and tonumber(song_i) == 1,
    "消息应为 m|1|<起始秒>，实际 " .. tostring(song_post and song_post.body))
ok(tonumber(start_sec) and tonumber(start_sec) > math.floor(clock_ms / 1000),
    "起始秒应在未来，留出收信的时间，实际 " .. tostring(start_sec))
ok(screen_has("合奏"), "屏幕应显示正在合奏")
flush_post()

local lead_mark = #calls.buzzer
advance(20000) -- 跨过 15 秒的开场和 4.8 秒的曲子
ok(table.concat(tones(lead_mark + 1), ",") == "523,523,784,784,880,880,784",
    "主旋律应按序奏出，实际 " .. table.concat(tones(lead_mark + 1), ","))

print("\n[12b] 被叫方奏伴奏，两边从同一秒开始")
reset_mocks()
dofile(APP)
on_start()
on_tick(20)
startup = false
advance(1200)
flush_poll("")

local peer_start = math.floor(clock_ms / 1000) + 15
next_poll_batch(line("peer-song", 1790900700, "9F3A1C77", "m|1|" .. peer_start))
ok(screen_has("合奏"), "收到邀请应显示合奏中")
local bass_mark = #calls.buzzer
advance(20000)
ok(table.concat(tones(bass_mark + 1), ",") == "131,196,175,131",
    "伴奏应按序奏出，实际 " .. table.concat(tones(bass_mark + 1), ","))

------------------------------------------------------------------
-- 13. 猜拳
------------------------------------------------------------------
print("\n[13] 猜拳：各自出招，两边算出同一个结果")
reset_mocks()
dofile(APP)
on_start()
on_tick(20)
startup = false
advance(1200)

local function play_round(my_taps, peer_body, want_text, tag)
    advance(1500)
    tap(5) -- 发起一局
    local _, inv = first_request("post")
    ok(inv and inv.body == "r|0", tag .. "：五下应发起猜拳，实际 " .. tostring(inv and inv.body))
    flush_post()

    advance(1500)
    tap(my_taps) -- 出招
    local _, mv = first_request("post")
    ok(mv and mv.body == "r|" .. my_taps,
        tag .. "：应发出 r|" .. my_taps .. "，实际 " .. tostring(mv and mv.body))
    flush_post()

    advance(1500)
    next_poll_batch(line("peer-move-" .. tag, 1790900800, "77AA11BB", peer_body))
    local shown = screen_has(want_text)
    finish_speech()
    advance(7000) -- 等结算文字退场，好开下一局
    return shown
end

ok(play_round(1, "r|2", "你赢了", "石头对剪刀"), "石头胜剪刀：屏幕应显示你赢了")
ok(store and store.w == 1, "胜场应写进存档，w=" .. tostring(store and store.w))
ok(play_round(2, "r|1", "你输了", "剪刀对石头"), "剪刀输石头：屏幕应显示你输了")
ok(store and store.l == 1, "负场应写进存档，l=" .. tostring(store and store.l))
ok(play_round(3, "r|3", "平手", "布对布"), "布对布：屏幕应显示平手")
ok(store and store.e == 1, "平局应写进存档，e=" .. tostring(store and store.e))

------------------------------------------------------------------
-- 14. 轮询节奏
------------------------------------------------------------------
print("\n[14] 轮询节奏：闲时 10 秒，对局时 2 秒")
local function poll_interval()
    local function drop()
        local id = first_request("poll")
        if id then
            deliver(id, { status = 200, content_type = "application/x-ndjson", body = "" })
        end
        return id
    end
    local function wait_for(cap)
        local w = 0
        while w < cap and not first_request("poll") do
            advance(100)
            w = w + 100
        end
        return w
    end
    drop()          -- 收掉积压的那次
    wait_for(20000) -- 它可能早就过期了，应用会立刻再发一个
    drop()          -- 收掉这个之后，下一次就按当前节奏排期
    return wait_for(20000)
end

advance(500)
local idle_wait = poll_interval()
ok(idle_wait >= 9000, "闲着时应按 10 秒轮询，实际 " .. idle_wait .. "ms")

tap(5)
flush_post()
local busy_wait = poll_interval()
ok(busy_wait > 0 and busy_wait <= 2600, "对局中应加快到 2 秒级，实际 " .. busy_wait .. "ms")

------------------------------------------------------------------
-- 15. 存档恢复
------------------------------------------------------------------
print("\n[15] 存档恢复")
reset_mocks()
store = {
    s = 7, r = 5, t = 1700000000, i = "old-id", g = 42, n = 1790900000,
    k = 3, d = "2026-10-12", w = 2, l = 1, e = 0,
}
dofile(APP)
on_start()
on_tick(20)
startup = false
ok(screen_has("送出 7") and screen_has("收到 5"), "计数应恢复")
ok(screen_has("连续 3 天"), "连续天数应恢复")
local _, restored = first_request("poll")
ok(restored and restored.url:find("since=1700000000") ~= nil,
    "恢复的游标应生效，实际 " .. tostring(restored and restored.url))

------------------------------------------------------------------
-- 16. 存档约束
------------------------------------------------------------------
print("\n[16] 存档约束")
advance(12000)
tap(1)
flush_post()
ok(#calls.saves >= 1, "存档写入通过了契约校验（键长/类型/32 项/1024 字节）")

print(string.format("\n== 结果: %d 通过, %d 失败 ==", pass, fail))
os.exit(fail == 0 and 0 or 1)
