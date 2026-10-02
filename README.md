# 想你机 · Think of You

两台 LingClaw，一个按键，**一种消息**。

按下自己这台，对方那台就会响一声、状态灯闪一下，并用它自己的声音念出一句话——
「有人在想你。」

没有文字输入，没有未读红点，没有「对方正在输入」。
这是两台设备用同一个键、共用同一个数字，做成的**只有一种消息的寻呼机**。

## 玩法

| 你的操作 | 自己这台 | 对方那台 |
| --- | --- | --- |
| 按下 `function` 键 | 短鸣一声、灯闪、显示「已送出」 | 响两声、灯常亮 1.5s、**念出那句话**、显示「有人想你 ♥」 |

- 连续猛点会被冷却拦住（显示「别急，慢一点」），避免刷屏打扰对方。
- 发送失败不会虚增计数，会显示「没送出去」。
- 送出的计数、轮询游标都会存档，重启后接着用。

## 它是怎么工作的

设备只能**主动轮询**，没法被动接收推送，所以两台设备需要一个公共中转。
这里用 [ntfy.sh](https://ntfy.sh)（免费、免注册、支持 HTTP 轮询）：

```
设备 A 按下 → POST https://ntfy.sh/<TOPIC>          （Title 头 = A 的 KEY）
设备 B 每 10s → GET  https://ntfy.sh/<TOPIC>/json?poll=1&since=<上次时间戳>
             → 解析出消息 → 检查 Title ≠ 自己的 KEY → 响铃 + 播报
```

`since` 用上次**已处理消息的时间戳 +1**，所以重启或断网后也不会重复播报；
必要时用 `since=1m` 从一分钟前开始拉取。两条消息用消息 `id` 去重。

## 快速开始（模拟器，零配置）

```sh
# 打开模拟器，选择本项目根目录下的：
think-of-you.lua
```

点击预览画面后按空格键（Mini 预设的 `function` 映射）即可发送。
模拟器使用电脑真实网络，`on_http_response` 走的是真 ntfy 请求。
底栏「播报」侧栏可以查看并确认「对方」传来的播报文本。

## 配对两台设备

1. **改掉主题名。** 打开脚本，把 `TOPIC` 换成一段难猜的字符串，
   **两台设备填成同一个**。ntfy 的主题名就是密码，公开主题任何人都能订阅。
2. **区分身份。** 两台设备的 `KEY` 必须**不同**，它是用来判断「这条消息是不是我自己发的」。
3. 分别上传：

   ```sh
   adb push think-of-you.lua /miniapp/think-of-you.lua
   ```

   上传后设备立即运行。两台设备各跑一份、分别改掉 `KEY` 即可。
4. 想改回设备上正在跑的版本：

   ```sh
   adb pull /miniapp/miniapp.lua ./device-app.lua
   ```

## 配置

脚本顶部集中了所有可调项：

| 变量 | 含义 | 默认 |
| --- | --- | --- |
| `TOPIC` | ntfy 主题，**两台必须相同**，务必改掉 | `lingclaw-think-CHANGE-ME-8f3a` |
| `KEY` | 本机标识，**两台必须不同** | `A1B2C3D4` |
| `POLL_MS` | 轮询间隔 | `10000` |
| `SEND_COOLDOWN_MS` | 连点冷却 | `1500` |
| `TTS_COOLDOWN_MS` | 两次播报最小间隔 | `6000` |
| `WHISPERS` | 可送出的话术，随机挑一句 | 6 句中文 |

## 设计取舍

- **为什么用轮询而不是推送？** 设备没有长连接/被动接收能力，
  HTTP 也没有 WebSocket，只有 `http.request`。轮询是唯一可行的收信方式。
- **为什么要 `KEY`？** ntfy 主题里所有人都看得到全部消息，包括自己发的那条。
  收到自己的消息时用 `Title` 头里的 `KEY` 过滤掉，否则会自己对自己播报。
- **为什么播报要节流、串行？** TTS 同一时刻只允许一个任务且**不排队**，
  被占用时直接返回 `failed/busy`。所以先等 `on_tts_result` 回来再发下一条，
  并设最小间隔。
- **为什么有一道 `booted` 保险？** 运行器禁止在启动阶段（源码、`on_start`、
  第一次 `on_tick`）调用 `tts.speak`。协议上不会在这时投递对端消息，
  但这道保险能防止边界情况下把应用直接抛死。
- **为什么存档要节流？** 平台限定同一存档槽写入至少间隔 10 秒，
  这里合并到约 11 秒写一次，避免 `rate_limited`。

## 验证

无需编译模拟器，用标准 Lua 跑打桩验证（用符合 API 契约的替身驱动全流程，
并校验矩形越界、文字 63 字节、TTS 512 字节、并发播报唯一、存档 32 项/1024 字节等）：

```sh
lua tests/mock_think.lua
# == 结果: 232 通过, 0 失败 ==
```

用真实模拟器做无界面验证（会发起真实 ntfy 请求）。
本项目只包含 Lua 应用，模拟器来自
[LingClaw-SDK](https://github.com/LISTENAI/LingClaw-SDK) 的 Releases，
或本地 SDK 检出编译出的 `target/debug/lingclaw-sdk`：

```sh
# 在 SDK 仓库执行 cargo build 后，用其可执行文件指向本项目的脚本
<lingclaw-sdk> --headless tests/real_api_probe.lua /tmp/probe.png
<lingclaw-sdk> --headless think-of-you.lua shot.png
```

## 已知限制与注意

- **公共主题没有隐私。** 消息内容对任何知道主题名的人可见。
  主题名要足够随机，别用生日、昵称这类可猜字符串。
- 想彻底私有化，可以自建 [ntfy 服务端](https://docs.ntfy.sh/install/)，
  或在 POST/GET 上加 `Authorization` 头（脚本的 `headers` 已支持）。
- ntfy.sh 公共实例有速率限制；`POLL_MS` 不建议低于 5 秒。
- 依赖 API 4（`http` / `json` / `tts`），需要设备有网络、扬声器和指示灯能力
  （Mini 固件 3.0.2 及以上满足）。
- 响应体默认上限 8KB，脚本放宽到 12KB；主题闲置一周以上会清空历史，
  首次可用 `since=1m` 兜底。

## 许可证

本项目采用 [MIT](LICENSE) 许可证。
