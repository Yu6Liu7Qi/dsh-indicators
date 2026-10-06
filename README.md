# dsh-indicators

在 macOS 菜单栏上，一眼看出 DSH 在不在干活。

屏幕右上角一块玻璃板，里面两个胶囊：左边是 DeepSeek API 的峰谷时段（绿「谷」/ 红「峰」），
右边是 DSH 的工作状态（蓝「工作中」/ 灰「空闲」/ 深灰「离线」）。一旦有操作在等你授权，
整条换成黄底黑字的「需要授权」，别的什么都不显示。

```
平时        [ 谷 │ 空闲 ]        [ 峰 │ 工作中 ]
等你点头    [    需要授权    ]
```

- **零依赖**：宿主半边只用 Node 内置模块；菜单栏 App 是随仓库发布的 Swift 小程序，装插件不会往
  你的 profile 里塞任何 npm 包。
- **纯宿主插件**：没有浏览器半边，DSH 窗口里不留任何东西。
- **生死跟着 DSH**：DSH 启动它才出现、DSH 退出它就消失，不用配登录项。

## 快速开始

### 装

需要 macOS 13+，并且已经装了 DSH。

```bash
# 装进某个 profile（dsh plugin 会把参数转给 pnpm，所以 git / npm / 本地路径都行）
dsh plugin --profile <你的 profile> add github:<用户名>/dsh-indicators
```

装完确认 profile 的 `package.json` 里 `dsh.profile.bundles` 有 `dsh-indicators` ——
用 DSH 设置里的插件管理器装会自动写进去；直接 `pnpm add` 的话要自己补一行。

不用管编译：仓库里带着 **universal 二进制**（arm64 + x86_64，最低 macOS 13），装上就能跑。
装了 Xcode Command Line Tools 的话，安装时 `prepare` 会顺手按你机器的 SDK 重编一份。

### 用

重启 DSH，菜单栏右上角就出现了。

- **点一下**：菜单列出**所有活着的对话**及忙闲（`●` 在跑 / `○` 空闲），下面还有「打开
  DeepSeek Harness」和「退出菜单栏指示器」。
- **悬停**：工作状态（几个对话在跑）、峰谷依据、下次切换时间、待授权数量。

### 卸

```bash
dsh plugin --profile <你的 profile> remove dsh-indicators
```

再把 profile 的 `package.json` 里 `dsh.profile.bundles` 中那一行删掉。菜单栏图标会随
DSH 一起消失。

## 它怎么工作

```
DSH（宿主进程）
  └─ lib/index.js ──写──▶ ~/Library/Application Support/dsh-indicators/status.json
                            │
  menubar/MenuBarIndicators ┘ 只读这份 JSON，画图、动画、菜单
  （由插件 spawn，插件卸载时被杀）
```

宿主半边盯三类东西：

| 数据 | 来源 |
| --- | --- |
| 工作状态 | `agent/status`（idle ⇄ running）、`agent/created`、`agent/disposed`，覆盖**所有**对话 |
| 峰谷时段 | `data/peak-valley.json` 里的规则，按声明的时区算墙上时间 |
| 待授权 | `session/event` 里的 `approval/asked` 与 `approval/decided`，按审批 id 配对 |

> 授权为什么不用 `approval/request`：那是个 waterfall，GUI 的 answerer 会先 claim 掉请求，
> 排在链尾的插件收不到。落进会话日志的那对 durable 事件才谁都看得见。

状态文件是个**开放的接口** —— 它很简单，你完全可以拿别的脚本去驱动这个菜单栏 App：

```json
{
  "v": 2,
  "pid": 51470,
  "updatedAt": 1791275700885,
  "work": { "running": 1, "total": 3,
            "sessions": [{ "id": "session-…", "status": "running", "cwd": "/path" }] },
  "peak": { "kind": "off", "why": "国庆节假期", "nextSwitchAt": 1791421200000,
            "nextKind": "peak", "timezone": "Asia/Shanghai" },
  "approval": { "pending": 0 }
}
```

`updatedAt` 超过 15 秒没刷新，菜单栏就当 DSH 已经退出、显示「离线」。

## 自定义

| 想改什么 | 改哪儿 |
| --- | --- |
| 颜色（胶囊、玻璃板、告警条） | `menubar/main.swift` 里的 `Palette` / `BoardPalette` |
| 尺寸、圆角、留白、（同心）半径 | 同上，`Metrics` |
| 动画时长与缓动 | `tweenDuration`、`easeOutCubic` |
| 峰谷规则（节假日、时段） | `data/peak-valley.json` |
| 状态文件位置 | 环境变量 `DSH_INDICATORS_STATUS_FILE`（插件和 App 要指同一个） |

改完 `node scripts/build-menubar.mjs` 重编，重启 DSH 生效。

## 自检（都不用启动界面）

```bash
node scripts/build-menubar.mjs --check          # 看二进制的架构与最低系统版本
./menubar/MenuBarIndicators --dump              # 打印一次解析结果
./menubar/MenuBarIndicators --board /tmp/board  # 导出各种状态与动画中间帧的 PNG
./menubar/MenuBarIndicators --pill  /tmp/pill   # 导出单个胶囊

# 看补间动画的每一帧（毫秒）
DSH_INDICATORS_TWEEN_MS=2000 DSH_INDICATORS_TRACE=1 ./menubar/MenuBarIndicators
```

## 已知限制

- **峰谷那一项是 DeepSeek API 的定价时段**，不用 DeepSeek 的话可以换掉
  `data/peak-valley.json`，或者无视它。
- **只在 macOS 上有意义**（`package.json` 里写了 `os: ["darwin"]`）。
- **未签名二进制**：`git clone` / pnpm 装下来的通常不带 quarantine 标记，直接能跑；要是你
  另外打包成 zip 分发，对方可能需要 `xattr -d com.apple.quarantine` 或在访达里右键打开。
- **同时跑多个 DSH 进程会打架**：状态文件只有一个，比如再开一个 `dsh headless`，两边会互相
  覆盖，指示器会来回闪。

## 开发

```
lib/index.js              宿主半边（DSH 插件）
menubar/main.swift        菜单栏 App（纯 AppKit，不认识 DSH）
menubar/MenuBarIndicators 编译产物，universal，提交进仓库
scripts/build-menubar.mjs 编译脚本
data/peak-valley.json     峰谷规则
cordis.patch.yml          把宿主半边挂进 profile 的 bundle patch
```

编译菜单栏 App 有两个坑，脚本里都处理了，手动编的时候别踩：

1. **必须钉 `-target`**。不钉的话最低系统版本会跟着编译机的 SDK 走 —— 在一台
   macOS 28 上编出来的二进制，macOS 26 的用户打不开。
2. **`-target` 必须配 `-sdk`**。只给 `-target` 会报
   `unable to load standard library for target ...`，即使机器上装着好几个 SDK。

### 发布前

- `package.json` 里的 `repository` / `author` 还空着，填上你自己的。
- `LICENSE` 里的版权人现在是 `dsh-indicators contributors`，按需替换。
