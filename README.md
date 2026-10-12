# dsh-indicators

DeepSeek Harness 的 macOS 菜单栏指示器：无需切换窗口，即可掌握 DSH 的运行状态。

屏幕右上角一块玻璃板，里面并排两个胶囊 —— 左边是 DeepSeek API 的峰谷时段（绿「谷」/ 红
「峰」），右边是 DSH 的工作状态（蓝「工作中」/ 灰「空闲」/ 深灰「离线」）。一旦有操作等待
授权，整条换成黄底黑字的「需要授权」。

```
平时        [ 谷 │ 空闲 ]        [ 峰 │ 工作中 ]
等待授权    [    需要授权    ]
```

- **零依赖**：宿主半边只用 Node 内置模块；菜单栏 App 是随仓库分发的 Swift 小程序，安装过程
  不会向 profile 写入任何 npm 包。
- **纯宿主插件**：没有浏览器半边，DSH 界面里不出现任何元素。
- **生命周期跟随 DSH**：DSH 启动时出现，DSH 退出时消失，无需配置登录项。

## 快速开始

### 安装

要求 macOS 13 及以上，且已安装 DSH。

```bash
# dsh plugin 会把参数转给 pnpm，因此 git / npm / 本地路径均可
dsh plugin --profile <profile 名> add github:<用户名>/dsh-indicators
```

安装后确认 profile 的 `package.json` 中 `dsh.profile.bundles` 含 `dsh-indicators`：通过 DSH
设置里的插件管理器安装会自动写入，直接 `pnpm add` 则需要手动补一行。

仓库已包含**预编译的 universal 二进制**（arm64 + x86_64，最低 macOS 13），安装后即可运行。
若本机装有 Xcode Command Line Tools，安装时 `prepare` 脚本会按本机 SDK 重新编译一份；未安装
则保留仓库中已有的二进制，不影响安装。

### 使用

重启 DSH 后，图标出现在菜单栏右上角。

- **单击**：菜单只有两项 —— 「打开 DeepSeek Harness」和「退出菜单栏指示器」。
- **悬停**：显示工作状态（含正在运行的对话名）、峰谷判定依据、下次切换时间、待授权数量。

> 菜单里刻意不列对话：状态随时在变，一行行列出来又长又看不完，而菜单栏真正需要回答的
> 问题只有一个 —— 要不要现在把 DSH 调到前面来。

### 卸载

```bash
dsh plugin --profile <profile 名> remove dsh-indicators
```

再从 profile 的 `package.json` 中删除 `dsh.profile.bundles` 里的对应行。菜单栏图标随 DSH
一同消失。

## 工作原理

```
DSH（宿主进程）
  └─ lib/index.js ──写──▶ ~/Library/Application Support/dsh-indicators/status.json
                            │
  menubar/MenuBarIndicators ┘ 只读这份 JSON，负责绘制、动画与菜单
  （由插件 spawn，插件卸载时终止）
```

宿主半边订阅三类数据：

| 数据 | 来源 |
| --- | --- |
| 工作状态 | `agent/status`（idle ⇄ running）、`agent/created`、`agent/disposed`，覆盖**所有**对话 |
| 峰谷时段 | `data/peak-valley.json` 中的规则，按声明的时区计算墙上时间 |
| 待授权 | `session/event` 中的 `approval/asked` 与 `approval/decided`，按审批 id 配对 |

> 待授权数据为什么不订阅 `approval/request`：那是个 waterfall，GUI 的 answerer 会先 claim
> 掉请求，排在链尾的插件收不到。落进会话日志的那对 durable 事件对所有监听者可见。

状态文件是一个**开放的接口** —— 格式简单，也可以由其他脚本驱动这个菜单栏 App：

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

`updatedAt` 超过 15 秒未刷新，菜单栏即判定 DSH 已退出并显示「离线」。

## 性能

菜单栏小程序最容易被忽略的一点是：它一直在那儿。实测数据（Apple Silicon）：

| 场景 | CPU | 常驻内存 |
| --- | --- | --- |
| 静止 | 0.0 – 0.1% | 12 MB |
| 状态切换动画（60fps，持续 0.3 秒） | 8.8 – 12% | 同上 |

动画只在状态真正变化时运行，平时不占 CPU。做法集中在 `menubar/main.swift`：

- **文字与板底预渲染为 sprite**：字形光栅化、渐变填充、圆角路径裁剪都只执行一次，之后每帧
  只做位图合成 —— `sample` 显示字形光栅化原本是最大的单个热点。
- **板底用九宫格拉伸**：板底是纯垂直渐变，水平方向处处一致，因此只渲染一条「左圆角 + 2pt 芯
  + 右圆角」的窄条，绘制时拉长中段。像素级等价。
- **文字 alpha 量化到 32 级**：CoreGraphics 的字形缓存按 (字符, alpha) 建立条目，连续变化的
  alpha 相当于不断产生新缓存键 —— 这是「连续切换状态后内存只涨不落」的主因。
- **动画尾部跳帧**：ease-out 后半段肉眼无法分辨的帧直接跳过。
- **状态文件按 mtime 跳过解码**：宿主每 5 秒才写入一次，无需每秒读盘解析。

优化过程实测（同一段 30 秒长动画 + 60 次状态切换）：

| 版本 | 帧率 | 动画期 CPU | 60 次切换后内存增长 |
| --- | --- | --- | --- |
| 优化前 | 60fps | 22 – 29% | +22 MB |
| 仅缓存层，并降至 30fps | 30fps | 7.8 – 10.1% | +11 MB |
| 再引入预渲染 | 30fps | 5.6 – 7.3% | +2 MB |
| **最终（预渲染 + 恢复 60fps）** | 60fps | **8.8 – 12%** | **+2 MB** |

最后一行是有意为之：预渲染降低了单帧成本后，就不再需要靠降帧节省 CPU —— 为 4 个百分点牺牲
动画流畅度并不划算。如需更省电，把 `tweenFPS` 改为 30 即可。

## 自定义

| 要修改的内容 | 位置 |
| --- | --- |
| 颜色（胶囊、玻璃板、告警条） | `menubar/main.swift` 中的 `Palette` / `BoardPalette` |
| 尺寸、圆角、留白、（同心）半径 | 同上，`Metrics` |
| 动画时长与缓动 | `tweenDuration`、`easeOutCubic` |
| 峰谷规则（节假日、时段） | `data/peak-valley.json` |
| 状态文件位置 | 环境变量 `DSH_INDICATORS_STATUS_FILE`（插件与 App 必须指向同一文件） |

修改后执行 `node scripts/build-menubar.mjs` 重新编译，重启 DSH 生效。

## 自检（均无需启动图形界面）

```bash
node scripts/build-menubar.mjs --check          # 查看二进制的架构与最低系统版本
./menubar/MenuBarIndicators --dump              # 打印一次状态解析结果
./menubar/MenuBarIndicators --board /tmp/board  # 导出各种状态与动画中间帧的 PNG
./menubar/MenuBarIndicators --pill  /tmp/pill   # 导出单个胶囊

# 逐帧输出补间动画（毫秒）
DSH_INDICATORS_TWEEN_MS=2000 DSH_INDICATORS_TRACE=1 ./menubar/MenuBarIndicators
```

## 已知限制

- **峰谷项对应 DeepSeek API 的定价时段**：不使用 DeepSeek 时，可以替换
  `data/peak-valley.json`，或忽略该项。
- **仅在 macOS 上有意义**：`package.json` 中已声明 `os: ["darwin"]`。
- **二进制未签名**：通过 `git clone` 或 pnpm 安装通常不带 quarantine 标记，可直接运行；
  若另行打包 zip 分发，接收方可能需要 `xattr -d com.apple.quarantine` 或在访达中右键打开。
- **多个 DSH 进程会相互干扰**：状态文件只有一份，例如另开一个 `dsh headless`，两者会交替
  覆盖，指示器随之反复变化。

## 开发

```
lib/index.js              宿主半边（DSH 插件）
menubar/main.swift        菜单栏 App（纯 AppKit，不依赖 DSH）
menubar/MenuBarIndicators 编译产物，universal，随仓库提交
scripts/build-menubar.mjs 编译脚本
data/peak-valley.json     峰谷规则
cordis.patch.yml          将宿主半边挂载进 profile 的 bundle patch
```

编译菜单栏 App 有两个必须注意的点，脚本已处理，手动编译时同样适用：

1. **必须固定 `-target`**。否则最低系统版本会跟随编译机的 SDK —— 在 macOS 28 上编译出的
   二进制，macOS 26 的用户无法打开。
2. **`-target` 必须搭配 `-sdk`**。只给 `-target` 会报
   `unable to load standard library for target ...`，即使本机装有多个 SDK。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
