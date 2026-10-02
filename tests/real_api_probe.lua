-- 真机 API 探针（临时）：在真实模拟器里走一遍应用使用的调用形状。
-- 任一参数非法或调用时机非法都会抛 Lua 异常，headless 返回非零状态。
local calls = 0
local tts_id
local http_id

local function check_json()
    -- 真实 ntfy 轮询报文片段
    local body = '{"id":"abc123","time":1790907078,"expires":1790950278,"event":"message","topic":"t","title":"peer-sim","message":"sim smoke test"}'
    local m = json.decode(body)
    assert(type(m) == "table", "json.decode 失败")
    assert(m.event == "message", "event 字段错误")
    assert(m.title == "peer-sim", "title 字段错误")
    assert(json.decode("not json") == nil, "非法 JSON 应返回 nil")
end

function on_start()
    check_json()
    local r = storage.save({ s = 1, t = 1790907078, i = "abc123" })
    assert(r == true, "storage.save 应成功")
    screen.begin(0x1A0F1E)
    screen.text("probe", 12, 12, 0xFFFFFF)
    led.blink("status", 80, 80)
    screen.present()
end

function on_tick(dt_ms)
    calls = calls + 1
    -- 启动阶段（源码、on_start、第一次 tick）禁止播报，从第二次 tick 起才允许。
    if calls == 2 then
        tts_id = tts.speak("有人在想你。")
        assert(type(tts_id) == "number", "tts.speak 应返回 id")
        buzzer.play(1600, 80)
        http_id = http.request({
            url = "https://ntfy.sh/lingclaw-probe/json?poll=1&since=1m",
            method = "GET",
            timeout_ms = 8000,
            max_response_bytes = 12000,
        })
        assert(type(http_id) == "number", "http.request 应返回 id")
        -- 发送形状（不真的关心结果）
        local sid = http.request({
            url = "https://ntfy.sh/lingclaw-probe",
            method = "POST",
            headers = { ["Title"] = "A1B2C3D4" },
            body = "有人在想你。",
            timeout_ms = 8000,
            max_response_bytes = 1024,
        })
        assert(type(sid) == "number", "POST 应返回 id")
    end
end

function on_http_response(id, response)
    -- 结果类型检查：要么有 status，要么有 error
    assert(response ~= nil, "response 不应为 nil")
end

function on_tts_result(id, result)
    assert(type(result) == "table", "tts result 应为表")
end

function on_button_click(id) end
