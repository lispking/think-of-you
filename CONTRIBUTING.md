# 贡献指南

欢迎 issue 与 PR。这个项目很小，规则也不多，但有几条是设备的硬约束，绕不过去。

## 环境

| 想做什么 | 需要什么 |
| --- | --- |
| 跑契约测试 | 标准 **Lua 5.4**（设备运行环境，不需要任何第三方库） |
| 在电脑上看效果 | [LingClaw-SDK](https://github.com/LISTENAI/LingClaw-SDK) 的桌面模拟器 |
| 烧到真机 | Android Platform Tools（`adb`）+ 一台支持 ADB 调试的 Mini |

```sh
git clone git@github.com:lispking/think-of-you.git
cd think-of-you
lua tests/mock_think.lua
```

## 开发循环

1. 用模拟器打开 `think-of-you.lua`，改完保存会**自动重载**，能立刻看到画面与按键结果。
2. 跑一遍 `lua tests/mock_think.lua`。
3. 烧到真机试试按键：`./flash.sh`。

## 目录约定

```
think-of-you.lua   应用本体
flash.sh           烧录脚本
assets/            README 用的界面截图
docs/              说明文档
tests/             测试
.github/           CI 与模板
```

**`think-of-you.lua` 必须保持单文件。** 设备端只能跑一个脚本，运行环境不提供
`require`、`io`、`package`，上传的就是这一个文件。同理**不要引入构建步骤**：
改完直接烧，没有编译产物。

## 代码风格

- 4 空格缩进，UTF-8，文件内用分节注释（`-- ─────` 标题）分段，顺序保持：
  配置 → 状态 → 自过滤 → 存档 → 长势 → 时间轴 → 画面 → 消息 → 发送 → 各玩法 → 回调。
- 注释写**为什么**，不复述代码。
- 新增可调项一律放进文件顶部的配置区，并在 README 的配置表里补一行。
- **外部数据必须逐项校验类型与范围。** 运行环境没有 `pcall`，参数非法会直接终止应用，
  所以存档、消息体、对端参数都要先检查再用。

### 运行环境不提供的东西

不要在应用里使用：`io`、`os`、`package`、`debug`、`coroutine`、动态加载、
`print`、`warn`、`pcall`、`xpcall`、`setmetatable`。

时间只有 `clock.now()`（**秒**精度，未校时返回 `nil`）和 `on_tick` 的 `dt_ms`；
不要依赖 `os.time`。

### 额度（越界会抛异常或画不出来）

| 项 | 上限 |
| --- | --- |
| 每帧矩形 | 128 |
| 每帧文字 | 8 段，单段 ≤63 字节 |
| 源码 | 64 KB（真机实测比这更宽裕，但别顶） |
| HTTP body / url | 8192 / 511 字节 |
| 存档 | 32 项 / 1024 字节，写入间隔 ≥10 秒 |

## 测试

任何**行为改动**都要在 `tests/mock_think.lua` 里补断言。

替身不是"能跑就行"：它按设备文档逐项校验参数，越界当场报错。
所以扩展替身时要照文档写限制，**不要放水**——它放过的越界，会在真机上变成崩溃。

涉及时间的场景用现成的工具推进：

- `advance(ms)`：同时推进运行时间和墙上时钟（测轮询节奏、节拍、合奏开场）。
- `jump_wall(sec)`：只跳墙上时钟（测长势按真实时间回落）。

## 提交规范

用 [Conventional Commits](https://www.conventionalcommits.org/)：

```
<type>(<scope>): <subject>

<为什么这样改、代价是什么，用多段英文说明>
```

- `subject` 用小写英文祈使句，≤50 字符，末尾不加句号。
- 正文用英文、多段（空行分隔），重点写**为什么**和**代价**，不要复述 diff。
- **每个提交都要能跑通 `lua tests/mock_think.lua`。** 如果行为改动必须同步改测试，
  就放进同一个提交里——留一个测试红的中间提交，比提交大一点糟得多。
- 不要加 `Co-Authored-By` 之类的署名尾注。

## 不要提交的东西

- **真实 `TOPIC`。** 它相当于密码，只写在被忽略的本机副本里
  （`device-*.lua`、`*.local.lua` 已被 `.gitignore` 挡住），应用本体保持占位值。
- 设备产物与调试副本：`device-flash.lua`、`device-flash.topic`、`device-app.lua` 等。
- 设备序列号、日志之类只在本机有意义的东西。

## PR 自查清单

- [ ] `lua tests/mock_think.lua` 全部通过
- [ ] 行为改动带了对应断言；替身没有放水
- [ ] 文档同步了（README 配置表 / `docs/`）
- [ ] 提交信息符合上面的规范，且每个提交都是绿的
- [ ] 没有夹带真实 `TOPIC` 或其他本机信息
