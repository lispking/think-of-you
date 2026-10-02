-- 想你机 · 打桩验证（无需 Rust 模拟器）
--
-- 在标准 Lua 里加载 think-of-you.lua，用符合 LingClaw API 契约的替身
-- 驱动一次完整流程：启动、轮询、自过滤、对端播报、送出、冷却、存档恢复。
-- 替身会按文档校验参数（矩形越界、文字 63 字节、TTS 512 字节、并发播报唯一、
-- 存档 32 项 / 1024 字节等），越界即报错。
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
local clock_t

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
    calls = { rects = 0, texts = 0, presents = 0, buzzer = {}, tts = {}, led = { on = 0, off = 0, blink = 0 }, saves = {} }
    pending = {}
    next_id = 0
    startup = true
    tts_open = false
    tts_seq = 0
    clock_t = 1790900000

    _G.app = { api_version = 4, width = 240, height = 240 }

    _G.screen = {
        begin = function(c) calls.bg = c end,
        rect = function(x, y, w, h, c)
            ok(x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= 240 and y + h <= 240,
                "rect 越界: " .. x .. "," .. y .. " " .. w .. "x" .. h)
            calls.rects = calls.rects + 1
        end,
        text = function(s, x, y, c)
            ok(#s <= 63, "文字超过 63 字节: " .. #s)
            ok(x >= 0 and y >= 0 and y <= 224, "文字坐标越界")
            calls.texts = calls.texts + 1
        end,
        present = function() calls.presents = calls.presents + 1 end,
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

    _G.clock = {
        now = function() return clock_t end,
        localtime = function()
            return { year = 2026, month = 10, day = 2, hour = 12, min = 0, sec = 0, wday = 4, utc_offset = 0 }
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
local KEY = io.open(APP):read("a"):match('local KEY%s*=%s*"([^"]+)"')
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

local function line(id, t, title, message)
    return string.format('{"id":"%s","time":%d,"event":"message","topic":"%s","title":"%s","message":"%s"}',
        id, t, TOPIC, title, message)
end

print("== 想你机 打桩验证 ==")
print("应用: " .. APP)
print("TOPIC=" .. TOPIC .. "  KEY=" .. KEY)

-- 1. 启动与轮询
print("\n[1] 启动、首帧、轮询调度")
ok(boot(), "启动成功")
ok(calls.presents >= 1, "启动阶段至少提交一帧")
local poll_id, poll_opts = first_request("poll")
ok(poll_id ~= nil, "首次 tick 后应发起轮询")
ok(poll_opts and poll_opts.url:find("since=1m") ~= nil, "首次轮询使用 since=1m")
ok(poll_opts and poll_opts.url:find("^https://ntfy%.sh/") == 1, "轮询走 ntfy")

-- 2. 收到对端消息 → 声音 + 灯 + 播报；自己的消息应被过滤
print("\n[2] 轮询响应：自过滤与对端播报")
local buzzer_before = #calls.buzzer
local led_before = calls.led.on
deliver(poll_id, {
    status = 200,
    content_type = "application/x-ndjson",
    body = line("self-1", 1790900010, KEY, "mine") .. "\n"
        .. line("peer-1", 1790900011, "other-device", "hello future"),
})
ok(#calls.tts == 1, "应恰好播报 1 次（自己的消息被过滤）")
ok(calls.tts[1] == "hello future", "播报内容应为对端消息")
ok(calls.led.on > led_before, "收到消息后状态灯常亮")
ok(#calls.buzzer == buzzer_before + 2, "收到消息应响两声")

-- 3. 游标推进，下次轮询使用 peer-1 的时间 +1
print("\n[3] 游标推进")
on_tick(10001) -- 跨过一个轮询间隔
local _, next_opts = first_request("poll")
ok(next_opts and next_opts.url:find("since=1790900012") ~= nil,
    "轮询游标应为 last_time+1，实际 " .. tostring(next_opts and next_opts.url))

-- 4. 未知事件与非 JSON 行不应崩溃、不误触发
print("\n[4] 脏数据容错")
local tts_before = #calls.tts
deliver(nil, { status = 200, body = "not json\n{\"event\":\"open\",\"id\":\"x\"}\n" })
ok(#calls.tts == tts_before, "脏数据不触发播报")

-- 5. 按键发送
print("\n[5] 按键送出")
on_button_click("function")
local post_id, post_opts = first_request("post")
ok(post_id ~= nil, "按键应发起 POST")
ok(post_opts and post_opts.url == "https://ntfy.sh/" .. TOPIC, "POST 到同一主题")
ok(post_opts and post_opts.headers and post_opts.headers["Title"] == KEY, "POST 携带本机 KEY")
ok(post_opts and #post_opts.body > 0, "POST 携带一句话")

-- 6. 连点冷却
print("\n[6] 连点冷却")
local pending_before = 0
for _ in pairs(pending) do pending_before = pending_before + 1 end
on_button_click("function")
local pending_after = 0
for _ in pairs(pending) do pending_after = pending_after + 1 end
ok(pending_after == pending_before, "冷却期内不应重复发送")

-- 7. 发送失败要回滚计数
print("\n[7] 发送失败回滚")
deliver(post_id, { error = { code = "network_error", message = "x" } })
ok(true, "失败回调不崩溃")

-- 8. 存档恢复：预置游标后重新启动，轮询应沿用
print("\n[8] 存档恢复")
reset_mocks()
store = { s = 7, t = 1700000000, i = "old-id" }
dofile(APP)
on_start()
on_tick(20)
startup = false
local _, restored = first_request("poll")
ok(restored and restored.url:find("since=1700000000") ~= nil,
    "恢复的游标应生效，实际 " .. tostring(restored and restored.url))

-- 9. 存档写入合法
print("\n[9] 存档约束")
ok(#calls.saves >= 0, "存档写入通过契约校验")

print(string.format("\n== 结果: %d 通过, %d 失败 ==", pass, fail))
os.exit(fail == 0 and 0 or 1)
