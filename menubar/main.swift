// DSH 菜单栏指示器（macOS 屏幕右上角，两个胶囊并排，外面罩一块共用的背景板）：
//
//   1. 工作状态 —— 蓝胶囊「工作中」/ 灰胶囊「空闲」/ 深灰胶囊「离线」
//   2. 峰谷时段 —— 红胶囊「峰」（高峰全价）/ 绿胶囊「谷」（空闲半价）
//
// 两项都读同一个状态文件（由 dsh-indicators 插件的宿主半边写出）：
//   ~/Library/Application Support/dsh-indicators/status.json
//   { v, pid, updatedAt, work: { running, total, sessions }, peak: { kind, why, ... } | null }
// 可用 DSH_INDICATORS_STATUS_FILE 覆盖（覆盖时插件与这里要指同一个文件）。
// peak 段为 null（规则读不到）时，峰谷那一项整项隐藏，不留说不清的状态。
//
// 图标样式：一块液态玻璃质感的圆角板，把两个胶囊（实心圆角 + 白字）托在一起。
// R 角按**同心圆角**算：板圆角 = 胶囊圆角 + 内边距，弧线共用圆心。状态切换走补间
// 动画：底色在 sRGB 里滚过去、文字交叉淡化、整块板跟着缓动（见 tweenDuration）。
// 用 2x 位图渲染，避免 Retina 上文字发虚。
//
// 本进程由 dsh-indicators 插件的宿主半边 spawn，DSH 退出时被它杀掉，所以
// 「DSH 开着才有指示器」。另有三条兜底防止留下孤儿：状态文件里的 pid 换代
// 就让位、宿主进程探测不到就立刻退、连续离线超过 selfQuitAfter 也退。
//
// 编译（无需 Xcode 工程，只需 Command Line Tools）：
//   swiftc -O -swift-version 5 -o MenuBarIndicators main.swift
//
// 自检（都不开界面）：
//   ./MenuBarIndicators --dump             打印一次解析结果
//   ./MenuBarIndicators --board /tmp/board 导出各状态与补间中间帧的 PNG

import AppKit
import Foundation

// MARK: - 状态文件

/// 状态文件里的一行会话。
struct SessionRow: Decodable {
    let id: String
    let status: String
    let cwd: String?
}

/// work 段：谁在运行。
struct WorkSection: Decodable {
    let running: Int
    let total: Int
    let sessions: [SessionRow]?
}

/// peak 段：现在是全价还是半价。
struct PeakSection: Decodable {
    /// "peak" 或 "off"。
    let kind: String
    let why: String?
    let timezone: String?
    let nextSwitchAt: Double?
    let nextKind: String?
    let rulesUpdatedAt: String?
    let sourceName: String?
}

/// approval 段：此刻有几个授权请求在等待用户授权。
struct ApprovalSection: Decodable {
    /// 待处理的授权请求数；0 或整段缺失都表示没有。
    let pending: Int
}

/// 宿主半边写出的整份状态。
struct IndicatorsFile: Decodable {
    let updatedAt: Double
    let pid: Int?
    let work: WorkSection?
    let peak: PeakSection?
    /// 授权请求数。旧版宿主不写这一段，所以要可选。
    let approval: ApprovalSection?
}

// MARK: - 工作状态

/// 工作状态呈现的三种状态。
enum WorkState {
    /// 有 agent 在运行；carried = 运行中的会话数。
    case working(Int)
    /// DSH 进程存活但没有 agent 在运行；carried = 存活的会话数。
    case idle(Int)
    /// DSH 已退出，或心跳过期。
    case offline

    /// 胶囊上的文字。
    ///
    /// 只写「工作中」，不带数字 —— 跑几个会话这件事在菜单栏上没意义（挤不下也读不
    /// 过来）。具体哪些对话在运行，见悬停提示和下拉菜单，那里列出了名称。
    var pillText: String {
        switch self {
        case .working: return "工作中"
        case .idle: return "空闲"
        case .offline: return "离线"
        }
    }

    /// 胶囊底色。
    var pillColor: NSColor {
        switch self {
        case .working: return Palette.working
        case .idle: return Palette.idle
        case .offline: return Palette.offline
        }
    }
}

/// 解析出来的工作状态。
struct WorkResolved {
    let state: WorkState
    let sessions: [SessionRow]
    /// 心跳距今毫秒数；读不到文件为 nil。
    let ageMs: Double?
    /// 写出这份状态的 DSH 宿主进程 pid。
    let hostPid: Int?
}

// MARK: - 峰谷状态

/// 解析出来的峰谷状态。
struct PeakResolved {
    let isPeak: Bool
    let why: String?
    let nextSwitchAt: Double?
    /// 下次切换后的档位，true = 峰。
    let nextIsPeak: Bool?
    let rulesUpdatedAt: String?
    let sourceName: String?
    let timezone: String

    /// 胶囊上的文字。
    var pillText: String { isPeak ? "峰" : "谷" }

    /// 胶囊底色。
    var pillColor: NSColor { isPeak ? Palette.peak : Palette.off }
}

// MARK: - 配色

/// 胶囊配色：实心高饱和底 + 白字，保证对比度。
/// 峰/谷沿用侧边栏小标那对色值，两处观感一致。
enum Palette {
    /// 工作中 —— 蓝。特意不用绿：绿色留给「谷」，两项并排时才分得开。
    static let working = hex(0x1B4FD8)
    /// 空闲 —— 中灰。
    static let idle = hex(0x6E6E73)
    /// 离线 —— 深灰。
    static let offline = hex(0x3A3A3C)
    /// 峰 —— 红。比原来的砖红更正：色相压到纯红（H=0）、饱和度拉高，白字在它上面
    /// 的对比度仍有 4.8:1，醒目但不影响读数。
    static let peak = hex(0xE01B1B)
    /// 谷 —— 绿。
    static let off = hex(0x0A7F45)
    /// 授权告警条的底色 —— 金黄。整条铺满，是菜单栏上最醒目的一块，用于提示待处理事项。
    /// 这两个色只在「需要授权」那一条上用，不参与状态胶囊。
    static let alertFill = hex(0xF7B500)
    /// 授权告警条上的字 —— 近黑。压在金黄底上对比度 11.6:1，比先前白底配黄字
    /// 那种 2:1 的糊法清楚太多了。
    static let alertInk = hex(0x141414)

    /// #RRGGBB → NSColor（sRGB）。
    /// - Parameter value: 十六进制色值。
    /// - Returns: 不透明颜色。
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 背景板配色：一块「液态玻璃」质感的圆角板，把两个胶囊托在一起。
///
/// 菜单栏图标是位图，不会跟着系统外观自己变，所以这里显式分深浅两套，由
/// makeBoard 按当前外观取；外观切换时 refresh 会重画（外观进指纹）。
enum BoardPalette {
    /// 玻璃板的竖直渐变：顶部亮、底部沉，给板一点厚度。
    /// - Parameter dark: 当前是否深色外观。
    /// - Returns: [顶部色, 底部色]。
    static func glass(dark: Bool) -> [NSColor] {
        dark
            ? [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0.10)]
            : [NSColor(white: 1, alpha: 0.82), NSColor(white: 1, alpha: 0.58)]
    }

    /// 玻璃边缘：一圈细白线。浅色壁纸下就靠它把板的轮廓勾出来。
    /// - Parameter dark: 当前是否深色外观。
    /// - Returns: 描边色。
    static func edge(dark: Bool) -> NSColor {
        NSColor(white: 1, alpha: dark ? 0.30 : 0.92)
    }

    /// 板内顶部那一道高光，玻璃的「反光」。
    /// - Parameter dark: 当前是否深色外观。
    /// - Returns: 高光色。
    static func gloss(dark: Bool) -> NSColor {
        NSColor(white: 1, alpha: dark ? 0.18 : 0.60)
    }

    /// 板内底部的一线暗影，和高光配对，板子才有立体感。
    /// - Parameter dark: 当前是否深色外观。
    /// - Returns: 暗影色。
    static func shade(dark: Bool) -> NSColor {
        NSColor(white: 0, alpha: dark ? 0.16 : 0.05)
    }

    /// 胶囊内顶部的高光：很淡的一层白，让实色胶囊也有珠子般的圆润感。
    static let pillGloss = NSColor(white: 1, alpha: 0.18)

    /// 黄条的描边：一点点黑。金黄板压在浅色壁纸或蓝色菜单栏上都看得清边界，深色
    /// 外观也一样，所以这条不分深浅。底色本身见 `Palette.alertFill`。
    static let alertEdge = NSColor(white: 0, alpha: 0.18)
}

// MARK: - 路径与阈值

/// 状态文件路径：环境变量优先，其次固定的 Application Support 位置。
let statusFilePath: String = {
    if let override = ProcessInfo.processInfo.environment["DSH_INDICATORS_STATUS_FILE"], !override.isEmpty {
        return override
    }
    return (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/dsh-indicators/status.json")
}()

/// 超过这么久没心跳就当 DSH 已经退出。
let staleAfterMs: Double = 15_000

// MARK: - 解析

/// 上一次读到的状态文件修改时间与解码结果。
///
/// 宿主每 5 秒才写一次（心跳），读取端却每秒读一次 —— 文件未变动时无需重新读盘解码。
/// 注意只缓存「文件内容」这一半：心跳是否过期仍然按当前时间现算，不然离线判定会失灵。
private var cachedStatusMtime: Date?
private var cachedStatusFile: IndicatorsFile?

/// 读状态文件；文件没变过就直接返回上次的解码结果。
/// - Returns: 解析好的文件内容；读不到或解析失败时为 nil。
func statusFileIfChanged() -> IndicatorsFile? {
    let mtime = (try? FileManager.default.attributesOfItem(atPath: statusFilePath))?[.modificationDate] as? Date
    if let mtime, mtime == cachedStatusMtime, let hit = cachedStatusFile {
        return hit
    }
    guard let data = FileManager.default.contents(atPath: statusFilePath),
          let file = try? JSONDecoder().decode(IndicatorsFile.self, from: data) else {
        cachedStatusMtime = mtime
        cachedStatusFile = nil
        return nil
    }
    cachedStatusMtime = mtime
    cachedStatusFile = file
    return file
}

/// 读取并解析整份状态文件（带 mtime 缓存，见 `statusFileIfChanged`）。
/// - Returns: work、peak 两段加待授权数；文件缺失、损坏或心跳过期时 work = 离线、
///   peak = nil、待授权数 = 0（心跳过期的那份状态已经不可信，不能拿它报授权）。
func resolve() -> (work: WorkResolved, peak: PeakResolved?, pendingApprovals: Int) {
    let offline = WorkResolved(state: .offline, sessions: [], ageMs: nil, hostPid: nil)
    guard let file = statusFileIfChanged() else {
        return (offline, nil, 0)
    }
    let ageMs = Date().timeIntervalSince1970 * 1000 - file.updatedAt
    guard ageMs <= staleAfterMs else {
        let stale = WorkResolved(
            state: .offline,
            sessions: file.work?.sessions ?? [],
            ageMs: ageMs,
            hostPid: file.pid
        )
        return (stale, nil, 0)
    }
    let running = file.work?.running ?? 0
    let total = file.work?.total ?? 0
    let state: WorkState = running > 0 ? .working(running) : .idle(total)
    let work = WorkResolved(state: state, sessions: file.work?.sessions ?? [], ageMs: ageMs, hostPid: file.pid)
    let pending = max(0, file.approval?.pending ?? 0)
    guard let section = file.peak else { return (work, nil, pending) }
    let peak = PeakResolved(
        isPeak: section.kind == "peak",
        why: section.why,
        nextSwitchAt: section.nextSwitchAt,
        nextIsPeak: section.nextKind.map { $0 == "peak" },
        rulesUpdatedAt: section.rulesUpdatedAt,
        sourceName: section.sourceName,
        timezone: section.timezone ?? "Asia/Shanghai"
    )
    return (work, peak, pending)
}

/// 会话在菜单里的显示名：有 cwd 就用最后一级目录名，否则用会话 id 前 8 位。
/// - Parameter row: 状态文件里的一行。
/// - Returns: 显示名。
func displayName(for row: SessionRow) -> String {
    if let cwd = row.cwd, !cwd.isEmpty {
        let base = (cwd as NSString).lastPathComponent
        if !base.isEmpty { return base }
    }
    return String(row.id.prefix(8))
}

/// 把时刻按规则时区格式化成「10月8日 09:00」。
/// - Parameters:
///   - ms: 毫秒时间戳。
///   - timeZone: IANA 时区名。
/// - Returns: 显示文本。
func formatMoment(_ ms: Double, timeZone: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
}

/// 胶囊字体：10.5pt semibold。建一次就够，不必每帧 `systemFont`。
let pillFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

/// 不透明文字用的属性（量宽度、预渲染文字都用它）。
let pillOpaqueAttributes: [NSAttributedString.Key: Any] = [
    .font: pillFont,
    .foregroundColor: NSColor.white,
]

/// 文字 alpha 量化级数。
///
/// 交叉淡化时 alpha 是连续值，而 CoreGraphics 的字形光栅化缓存是按 (字符, alpha)
/// 建条目的 —— 连续值等于喂它无穷多个键。实测：连续 60 次状态切换后进程涨了 22MB
/// 且不回落，把 alpha 量化到 32 级后同样 60 次只涨 13MB 并中途回落。32 级在 0.3 秒
/// 的动画里肉眼分辨不出。
let textAlphaSteps: CGFloat = 32

/// 属性字典缓存：key =「颜色|量化后的 alpha」。动画里 alpha 只有 32 档、颜色也就几种，
/// 命中率接近 100%，省掉每帧重建字典。
var pillAttributeCache: [String: [NSAttributedString.Key: Any]] = [:]

/// 胶囊的字体与文字属性（带缓存 + alpha 量化）。
/// - Parameters:
///   - alpha: 文字不透明度，内部量化到 `textAlphaSteps` 级。
///   - color: 文字颜色。
/// - Returns: 画胶囊文字用的属性字典。
func pillAttributes(alpha: CGFloat = 1, color: NSColor = .white) -> [NSAttributedString.Key: Any] {
    let quantized = (alpha * textAlphaSteps).rounded() / textAlphaSteps
    let key = "\(color.description)|\(quantized)"
    if let hit = pillAttributeCache[key] { return hit }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: pillFont,
        .foregroundColor: color.withAlphaComponent(quantized),
    ]
    pillAttributeCache[key] = attributes
    return attributes
}

/// 文字宽度缓存：`size(withAttributes:)` 是 CoreText 调用，动画里每帧量一遍太浪费。
/// 胶囊文字翻来覆去就那几个（工作中 / 空闲 / 离线 / 峰 / 谷 / 需要授权），命中率极高。
var textWidthCache: [String: CGFloat] = [:]

/// 量一行文字的宽度，带缓存。
/// - Parameter text: 文字。
/// - Returns: 宽度（点，向上取整）。
func cachedTextWidth(_ text: String) -> CGFloat {
    if let hit = textWidthCache[text] { return hit }
    let width = ceil((text as NSString).size(withAttributes: pillOpaqueAttributes).width)
    textWidthCache[text] = width
    return width
}

/// 尺寸常量。R 角按**同心圆角**来：外圆角 = 内圆角 + 内边距，两块弧线共用圆心，
/// 板边和胶囊边之间那一圈留白才处处等宽（macOS 26/27 那套圆角规则）。
enum Metrics {
    /// 胶囊高度。
    static let pillHeight: CGFloat = 16
    /// 胶囊左右留白。
    static let pillHPad: CGFloat = 6
    /// 胶囊圆角 = 高的一半，胶囊形。
    static let pillRadius: CGFloat = pillHeight / 2
    /// 板边到胶囊之间的留白。
    static let boardPad: CGFloat = 3
    /// 授权告警条里文字左右的留白：比胶囊的留白宽，那块黄才显得舒展。
    static let alertHPad: CGFloat = 14
    /// 板里两颗胶囊之间的间距。
    static let boardGap: CGFloat = 4
    /// 板圆角 = 8 + 3 = 11，正好也是板高 22 的一半 —— 板本身就是一个胶囊形，
    /// 与里面的胶囊同心。
    static let boardRadius: CGFloat = pillRadius + boardPad
    /// 板高 = 胶囊高 + 上下各一份内边距。
    static let boardHeight: CGFloat = pillHeight + boardPad * 2
}

/// 一颗胶囊的样子。动画就是在两份参数之间插值，所以字段都挑可插值的。
struct PillVisual {
    /// 身份：补间按 id 配对（峰谷 "peak"、工作状态 "work"）。
    let id: String
    /// 胶囊上的文字。
    var text: String
    /// 底色。
    var color: NSColor
    /// 文字宽度。
    var textWidth: CGFloat
    /// 整体不透明度；0 表示收起来了。
    var alpha: CGFloat

    /// 从「文字 + 底色」造一颗，文字宽度走缓存。
    /// - Parameters:
    ///   - id: 身份。
    ///   - text: 胶囊文字。
    ///   - color: 底色。
    ///   - alpha: 整体不透明度。
    init(id: String, text: String, color: NSColor, alpha: CGFloat = 1) {
        self.init(
            id: id,
            text: text,
            color: color,
            textWidth: cachedTextWidth(text),
            alpha: alpha
        )
    }

    /// 字段给齐（插值时用）。
    /// - Parameters:
    ///   - id: 身份。
    ///   - text: 胶囊文字。
    ///   - color: 底色。
    ///   - textWidth: 文字宽度。
    ///   - alpha: 整体不透明度。
    init(id: String, text: String, color: NSColor, textWidth: CGFloat, alpha: CGFloat) {
        self.id = id
        self.text = text
        self.color = color
        self.textWidth = textWidth
        self.alpha = alpha
    }

    /// 此刻占多宽。alpha 归零时宽度也归零，板子才会跟着收拢。
    var width: CGFloat { (textWidth + Metrics.pillHPad * 2) * alpha }
}

/// 补间里的一颗胶囊：从 from 走到 to。哪一侧是 nil，就表示它正在出现或正在消失。
struct PillTween {
    let id: String
    let from: PillVisual?
    let to: PillVisual?
}

/// 补间时长（秒）：够看清过渡，又不至于让人等。
///
/// 可用环境变量 `DSH_INDICATORS_TWEEN_MS` 覆盖（毫秒）。排查动画时把它调大，
/// 每一帧都看得清。
let tweenDuration: TimeInterval = {
    if let raw = ProcessInfo.processInfo.environment["DSH_INDICATORS_TWEEN_MS"],
       let ms = Double(raw), ms > 0 {
        return ms / 1000
    }
    return 0.30
}()

/// 补间帧率。
///
/// 这里**没有**降到 30fps。原本是打算靠降帧省 CPU 的（实测确实能省四成），但把绘制
/// 换成「预渲染 + 合成」之后，60fps 的成本已经掉到 10% 上下（原来 22~29%）—— 再降帧
/// 就是拿动画质量换那 4 个点，不划算。真想省电，把这里改成 30 即可。
///
/// 为什么不挂 CADisplayLink 跟 VSync 对齐：那个 API 要落在 NSView 上
/// （`NSView.displayLink(target:selector:)`），而菜单栏状态项只有一个系统给的
/// NSStatusBarButton，往里添加子视图会干扰系统自身的绘制。何况这里只是更新一张 image，
/// 合成本来就是系统按刷新率做的 —— 与其追帧率，不如把每帧做便宜。
let tweenFPS: Double = 60

/// ease-out cubic：起步快、收尾稳，跟系统状态切换的节奏一致。
/// - Parameter t: 线性进度 0…1。
/// - Returns: 缓动后的进度。
func easeOutCubic(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

/// 线性插值。
/// - Parameters:
///   - a: 起点。
///   - b: 终点。
///   - t: 进度 0…1。
/// - Returns: 插值结果。
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// sRGB 空间里插颜色。峰↔谷、空闲↔工作中都是这么滚过去的。
/// - Parameters:
///   - a: 起点色。
///   - b: 终点色。
///   - t: 进度 0…1。
/// - Returns: 插值色。
func lerpColor(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    guard let ca = a.usingColorSpace(.sRGB), let cb = b.usingColorSpace(.sRGB) else {
        return t < 0.5 ? a : b
    }
    return NSColor(
        srgbRed: lerp(ca.redComponent, cb.redComponent, t),
        green: lerp(ca.greenComponent, cb.greenComponent, t),
        blue: lerp(ca.blueComponent, cb.blueComponent, t),
        alpha: lerp(ca.alphaComponent, cb.alphaComponent, t)
    )
}

/// 补间走到 t 时这颗胶囊的样子。
/// - Parameters:
///   - tween: 一颗胶囊的补间。
///   - t: 进度 0…1。
/// - Returns: 插值后的胶囊参数。
func resolve(_ tween: PillTween, t: CGFloat) -> PillVisual {
    let from = tween.from
    let to = tween.to
    let color = lerpColor(from?.color ?? to!.color, to?.color ?? from!.color, t)
    let textWidth = lerp(from?.textWidth ?? 0, to?.textWidth ?? 0, t)
    let alpha = lerp(from?.alpha ?? 0, to?.alpha ?? 0, t)
    let text = t < 0.5 ? (from?.text ?? to!.text) : (to?.text ?? from!.text)
    return PillVisual(id: tween.id, text: text, color: color, textWidth: textWidth, alpha: alpha)
}

/// 文字预渲染缓存：key =「文字|颜色」→ 透明底、完全不透明的文字位图。
///
/// 动画里同一行字要画几十遍，每遍只是 alpha 不同。把字形光栅化的结果留下来，之后
/// 每帧只做一次位图合成（`draw(_:fraction:)`），不再碰 CoreText —— `sample` 里
/// `CGGlyphBitmapCreateWithPathAndDilation` 一直是最大的单个热点。
var textSpriteCache: [String: NSImage] = [:]

/// 取（或生成）一行文字的 sprite。
/// - Parameters:
///   - text: 文字。
///   - color: 文字颜色。
/// - Returns: 透明底、alpha = 1 的文字位图（四周留 1pt 余量给抗锯齿）。
func textSprite(_ text: String, color: NSColor) -> NSImage {
    let key = "\(text)|\(color.description)"
    if let hit = textSpriteCache[key] { return hit }
    let measured = (text as NSString).size(withAttributes: pillAttributes(alpha: 1, color: color))
    let size = NSSize(width: ceil(measured.width) + 2, height: ceil(measured.height) + 2)
    let image = makeBitmapImage(size: size) { _ in
        (text as NSString).draw(
            at: NSPoint(x: 1, y: 1),
            withAttributes: pillAttributes(alpha: 1, color: color)
        )
    }
    textSpriteCache[key] = image
    return image
}

/// 在胶囊正中画一行字（走 sprite 缓存，alpha 交给合成）。
/// - Parameters:
///   - text: 文字。
///   - alpha: 不透明度。
///   - centerX: 胶囊中心 x。
///   - rect: 胶囊外框。
///   - color: 文字颜色；默认白。
func drawPillText(_ text: String, alpha: CGFloat, centerX: CGFloat, rect: NSRect, color: NSColor = .white) {
    guard alpha > 0.01, !text.isEmpty else { return }
    let sprite = textSprite(text, color: color)
    let size = sprite.size
    // 位置取整：让文字落在整像素上，别因为半像素偏移发虚。
    let origin = NSPoint(
        x: (centerX - size.width / 2).rounded(),
        y: (rect.midY - size.height / 2).rounded()
    )
    sprite.draw(
        at: origin,
        from: NSRect(origin: .zero, size: size),
        operation: .sourceOver,
        fraction: alpha
    )
}

/// 开一块 2x 位图并交给 `body` 按「点」作图，画完包成 NSImage。
///
/// 自己按屏幕缩放画 2x 位图，而不是让 AppKit 放大 1x 图：胶囊里是文字，缩放会
/// 发虚。`body` 拿到的上下文里 rep.size 已经声明成点，因此**不能**再自己
/// scaleBy —— 再缩放一次就会画出边界，被位图裁掉半边（该问题在实际编译中出现过）。
/// - Parameters:
///   - size: 图片尺寸（点）。
///   - body: 作图闭包。
/// - Returns: 非模板图片，颜色不会被系统菜单栏着色覆盖。
func makeBitmapImage(size: NSSize, _ body: (NSGraphicsContext) -> Void) -> NSImage {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(ceil(size.width * scale)),
        pixelsHigh: Int(ceil(size.height * scale)),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return NSImage(size: size)
    }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    if let context = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = context
        body(context)
        context.flushGraphics()
    }
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: size)
    image.addRepresentation(rep)
    image.isTemplate = false
    return image
}

/// 画一个「实心圆角胶囊 + 白字」的图标（`--pill` 自检用）。
/// - Parameters:
///   - text: 胶囊上的文字。
///   - background: 底色。
/// - Returns: 非模板图片。
func makePill(_ text: String, background: NSColor) -> NSImage {
    let visual = PillVisual(id: "pill", text: text, color: background)
    let size = NSSize(width: visual.width, height: Metrics.pillHeight)
    return makeBitmapImage(size: size) { _ in
        let rect = NSRect(origin: .zero, size: size)
        let pill = NSBezierPath(
            roundedRect: rect,
            xRadius: Metrics.pillRadius,
            yRadius: Metrics.pillRadius
        )
        background.setFill()
        pill.fill()
        drawPillGloss(in: pill, rect: rect, alpha: 1)
        drawPillText(text, alpha: 1, centerX: rect.midX, rect: rect)
    }
}

/// 胶囊内顶部那一线高光，让实色胶囊也有一点珠子般的圆润感。
/// - Parameters:
///   - pill: 胶囊路径（拿来裁切）。
///   - rect: 胶囊外框。
///   - alpha: 整体不透明度。
func drawPillGloss(in pill: NSBezierPath, rect: NSRect, alpha: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    pill.addClip()
    BoardPalette.pillGloss
        .withAlphaComponent(BoardPalette.pillGloss.alphaComponent * alpha)
        .setFill()
    NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// 玻璃板底的预渲染缓存。
///
/// 板底是「纯垂直渐变 + 水平方向处处一样」，所以只要渲一条「左圆角 + 2pt 芯 + 右圆角」
/// 的窄条，画的时候把中间那段拉长就行 —— 像素级等价，却省掉了每帧的渐变填充、圆角
/// 路径裁剪和描边（`sample` 里 `RGBA32_shade_axial_RGB` 与 `Clipper2Lib` 是仅次于
/// 字形光栅化的两块热点）。
///
/// key 里的 alertness 量化到 1/16：玻璃板 ↔ 金黄条只在进/出告警时过渡，16 档够用。
var boardSpriteCache: [String: NSImage] = [:]

/// 板底 sprite 中间那截可拉伸部分的宽度（点）。
let boardSpriteCoreWidth: CGFloat = 2

/// 取（或生成）一块板底的 sprite。
/// - Parameters:
///   - alertness: 告警条浓度 0…1（内部量化到 1/16）。
///   - dark: 是否深色外观。
/// - Returns: 宽 = 两个圆角 + 2pt 芯、高 = 板高的位图。
func boardSprite(alertness: CGFloat, dark: Bool) -> NSImage {
    let quantized = (alertness * 16).rounded() / 16
    let key = "\(quantized)|\(dark)"
    if let hit = boardSpriteCache[key] { return hit }

    let cap = Metrics.boardRadius
    let size = NSSize(width: cap * 2 + boardSpriteCoreWidth, height: Metrics.boardHeight)
    let image = makeBitmapImage(size: size) { _ in
        let bounds = NSRect(origin: .zero, size: size)
        let board = NSBezierPath(roundedRect: bounds, xRadius: cap, yRadius: cap)
        let glassFade = 1 - quantized
        if glassFade > 0.01,
           let gradient = NSGradient(colors: BoardPalette.glass(dark: dark).map {
               $0.withAlphaComponent($0.alphaComponent * glassFade)
           }) {
            gradient.draw(in: board, angle: -90)
        }
        NSGraphicsContext.saveGraphicsState()
        board.addClip()
        if glassFade > 0.01 {
            let gloss = BoardPalette.gloss(dark: dark)
            gloss.withAlphaComponent(gloss.alphaComponent * glassFade).setFill()
            NSRect(x: 0, y: Metrics.boardHeight - 1, width: size.width, height: 1).fill()
            let shade = BoardPalette.shade(dark: dark)
            shade.withAlphaComponent(shade.alphaComponent * glassFade).setFill()
            NSRect(x: 0, y: 0, width: size.width, height: 1).fill()
        }
        if quantized > 0.01 {
            let fill = Palette.alertFill
            fill.withAlphaComponent(fill.alphaComponent * quantized).setFill()
            board.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        board.lineWidth = 1
        if glassFade > 0.01 {
            let edge = BoardPalette.edge(dark: dark)
            edge.withAlphaComponent(edge.alphaComponent * glassFade).setStroke()
            board.stroke()
        }
        if quantized > 0.01 {
            BoardPalette.alertEdge
                .withAlphaComponent(BoardPalette.alertEdge.alphaComponent * quantized)
                .setStroke()
            board.stroke()
        }
    }
    boardSpriteCache[key] = image
    return image
}

/// 把板底 sprite 画成目标宽度：左右两个圆角原样贴，中间那段拉长。
/// - Parameters:
///   - sprite: 板底 sprite。
///   - width: 目标宽度。
func drawBoardSprite(_ sprite: NSImage, width: CGFloat) {
    let cap = Metrics.boardRadius
    let core = boardSpriteCoreWidth
    let height = Metrics.boardHeight
    let sourceHeight = sprite.size.height
    let middle = max(width - cap * 2, 0)
    // 左圆角
    sprite.draw(
        in: NSRect(x: 0, y: 0, width: cap, height: height),
        from: NSRect(x: 0, y: 0, width: cap, height: sourceHeight),
        operation: .sourceOver,
        fraction: 1
    )
    // 中段：纯水平拉伸。板的渐变是垂直的，水平方向本来就处处一样，所以不失真。
    if middle > 0 {
        sprite.draw(
            in: NSRect(x: cap, y: 0, width: middle, height: height),
            from: NSRect(x: cap, y: 0, width: core, height: sourceHeight),
            operation: .sourceOver,
            fraction: 1
        )
    }
    // 右圆角
    sprite.draw(
        in: NSRect(x: max(width - cap, 0), y: 0, width: cap, height: height),
        from: NSRect(x: cap + core, y: 0, width: cap, height: sourceHeight),
        operation: .sourceOver,
        fraction: 1
    )
}

/// 画菜单栏上真正显示的那一项：**一块板 + 板里并排的胶囊**。
///
/// 两个指示器必须合成一张图才能共用一块板 —— 拆成两个 NSStatusItem 的话，中间
/// 那道间距由系统来排，板就断成两半了。
///
/// `alertness` 决定这是哪种板：0 = 液态玻璃板 + 实色胶囊 + 白字；1 = 授权告警的
/// 金黄条 + 近黑字（胶囊底整个退掉，只剩字）。中间值就是两者的交叉淡化，所以
/// 「有请求等待授权」是从正常状态平滑过渡过去的，不是瞬间替换整张图片。
/// - Parameters:
///   - tweens: 从左到右的胶囊补间；空数组返回 1pt 的空图。
///   - t: 补间进度 0…1（静止时传 1）。
///   - alertness: 告警条浓度 0…1。
///   - appearance: 当前外观，决定玻璃的深浅（黄条不随外观变）。
/// - Returns: 非模板图片。
func makeBoard(
    tweens: [PillTween],
    t: CGFloat,
    alertness: CGFloat,
    appearance: NSAppearance
) -> NSImage {
    guard !tweens.isEmpty else { return NSImage(size: NSSize(width: 1, height: 1)) }

    let pills = tweens.map { resolve($0, t: t) }
    // 告警条的文字留白比胶囊宽；留白跟着 alertness 走，宽度变化才是连续的。
    let hPad = lerp(Metrics.pillHPad, Metrics.alertHPad, alertness)
    func pillWidth(_ pill: PillVisual) -> CGFloat { (pill.textWidth + hPad * 2) * pill.alpha }
    // 间距按相邻两颗的「存在度」取小：一颗正在淡出/淡入的胶囊只占对应的份额，
    // 全隐的那颗不该还把板撑出一个空档 —— 普通态切到告警条时最容易看出来。
    func spacing(after index: Int) -> CGFloat {
        guard index < pills.count - 1 else { return 0 }
        return Metrics.boardGap * min(pills[index].alpha, pills[index + 1].alpha)
    }
    let width = pills.enumerated().reduce(Metrics.boardPad * 2) { total, pair in
        total + pillWidth(pair.element) + spacing(after: pair.offset)
    }
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    return makeBitmapImage(size: NSSize(width: max(width, 1), height: Metrics.boardHeight)) { _ in
        // 板底走预渲染 sprite + 九宫格拉伸：渐变、圆角裁剪、描边不再逐帧重做。
        drawBoardSprite(boardSprite(alertness: alertness, dark: dark), width: width)

        var x = Metrics.boardPad
        for (index, pill) in pills.enumerated() {
            let width = pillWidth(pill)
            drawPill(tweens[index], resolved: pill, t: t, alertness: alertness, at: x, width: width)
            x += width + spacing(after: index)
        }
    }
}

/// 画一颗胶囊：插值过的底色 + 顶部高光 + 文字。文字变了就交叉淡化。
///
/// 告警态（alertness → 1）下胶囊底整个淡出、文字转近黑 —— 金黄条上就只剩一行
/// 黑字，不再有彩色胶囊。
/// - Parameters:
///   - tween: 这颗胶囊的补间。
///   - resolved: 它在这一帧的参数。
///   - t: 补间进度。
///   - alertness: 告警条浓度 0…1。
///   - x: 胶囊左边缘。
///   - width: 胶囊宽度。
func drawPill(
    _ tween: PillTween,
    resolved: PillVisual,
    t: CGFloat,
    alertness: CGFloat,
    at x: CGFloat,
    width: CGFloat
) {
    guard resolved.alpha > 0.01, width > 0.5 else { return }
    let rect = NSRect(
        x: x,
        y: Metrics.boardPad,
        width: width,
        height: Metrics.pillHeight
    )
    let pill = NSBezierPath(
        roundedRect: rect,
        xRadius: Metrics.pillRadius,
        yRadius: Metrics.pillRadius
    )
    let pillAlpha = resolved.alpha * (1 - alertness)
    if pillAlpha > 0.01 {
        resolved.color.withAlphaComponent(pillAlpha).setFill()
        pill.fill()
        drawPillGloss(in: pill, rect: rect, alpha: pillAlpha)
    }

    // 胶囊态白字 → 告警态黑字：中间那段会经过灰，正好压在同步变黄的底上，一闪而过。
    let textColor = lerpColor(.white, Palette.alertInk, alertness)
    let from = tween.from?.text
    let to = tween.to?.text
    if from == to {
        drawPillText(
            to ?? "",
            alpha: resolved.alpha,
            centerX: rect.midX,
            rect: rect,
            color: textColor
        )
    } else {
        if let from {
            drawPillText(
                from,
                alpha: (1 - t) * resolved.alpha,
                centerX: rect.midX,
                rect: rect,
                color: textColor
            )
        }
        if let to {
            drawPillText(
                to,
                alpha: t * resolved.alpha,
                centerX: rect.midX,
                rect: rect,
                color: textColor
            )
        }
    }
}

/// 探测一个进程是否还存在。
/// - Parameter pid: 状态文件里记的 DSH 宿主 pid。
/// - Returns: true 表示进程存在（或无权探测，保守判定为存活）。
func processAlive(_ pid: Int) -> Bool {
    if pid <= 0 { return true }
    if kill(pid_t(pid), 0) == 0 { return true }
    // ESRCH = 进程不存在；EPERM = 存在但无权限探测，按存活处理。
    return errno != ESRCH
}

// MARK: - 菜单栏控制器

/// 管着菜单栏上那一个状态项：一块背景板，板里并排两个胶囊。
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var work = WorkResolved(state: .offline, sessions: [], ageMs: nil, hostPid: nil)
    private var peak: PeakResolved?
    /// 等待用户授权的请求数。
    private var pendingApprovals = 0
    private var lastSignature = ""
    /// 屏上此刻的样子（动画中就是插值出来的中间态）。
    private var displayed: [PillVisual] = []
    /// 告警条浓度：0 = 普通玻璃板，1 = 授权金黄条（见 makeBoard）。
    private var alertness: CGFloat = 0
    /// 进行中的补间；nil = 静止。alertFrom/alertTo 是告警条浓度这一段的起止。
    private var tween: (
        items: [PillTween],
        target: [PillVisual],
        start: TimeInterval,
        alertFrom: CGFloat,
        alertTo: CGFloat
    )?
    /// 补间期间逐帧重绘用的计时器。
    private var frameTimer: Timer?
    /// 上一次真正画出去的进度值，用来跳掉肉眼分不出的帧（见 stepTween）。
    private var lastDrawnT: CGFloat = -1
    /// 第一次见到的 DSH 宿主进程 pid。它一变就说明 DSH 重启过 ——
    /// 本实例让位给插件新拉起来的那一个，免得菜单栏挂出两套指示器。
    private var hostPid: Int?
    /// 连续「离线」的起点，用来兜底 DSH 崩溃（正常退出时插件会直接杀掉本进程）。
    private var offlineSince: Date?
    /// 离线持续多久就自己退出。
    private let selfQuitAfter: TimeInterval = 30

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 只建一个状态项：两个胶囊画在同一张图上，才能共用一块背景板。
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        refresh()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 重新读状态；只有真的变了才重画，避免菜单栏每秒闪动。
    @objc func refresh() {
        let next = resolve()
        if supervise(next.work) { return }
        // 外观也进指纹：浅色 ↔ 深色切换时板底色要跟着重画。
        let signature = signatureOfWork(next.work)
            + "||" + signatureOfPeak(next.peak)
            + "||" + appearanceSignature()
            + "||auth\(next.pendingApprovals)"
        work = next.work
        peak = next.peak
        pendingApprovals = next.pendingApprovals
        if signature != lastSignature || item.button?.image == nil {
            lastSignature = signature
            // 首次上屏直接画，之后的状态变化都走补间。
            showPills(
                currentPills(),
                alert: pendingApprovals > 0 ? 1 : 0,
                animated: item.button?.image != nil
            )
            item.menu = sharedMenu()
        }
    }

    /// 与 DSH 的生死绑定。
    /// - Parameter next: 本次工作状态解析结果。
    /// - Returns: true 表示本实例正在退出，调用方不要再画界面。
    private func supervise(_ next: WorkResolved) -> Bool {
        if let pid = next.hostPid {
            if hostPid == nil {
                hostPid = pid
            } else if hostPid != pid {
                // 状态文件里的 pid 换了 = DSH 换了一代；新的一代会由插件另起实例。
                NSApp.terminate(nil)
                return true
            }
        }
        if case .offline = next.state {
            // DSH 正常退出时插件会直接杀掉本进程；这里兜底它没跑到的情况
            // （宿主被 SIGKILL、或退出路径没走析构）。先看进程还在不在 ——
            // 进程没了就立刻走，不用陪等到超时。
            if let pid = hostPid, !processAlive(pid) {
                NSApp.terminate(nil)
                return true
            }
            if offlineSince == nil {
                offlineSince = Date()
            } else if Date().timeIntervalSince(offlineSince!) >= selfQuitAfter {
                NSApp.terminate(nil)
                return true
            }
        } else {
            offlineSince = nil
        }
        return false
    }

    /// 工作状态的指纹：状态标签 + 每个会话的 id 与忙闲。
    /// - Parameter resolved: 一次解析结果。
    /// - Returns: 指纹字符串。
    private func signatureOfWork(_ resolved: WorkResolved) -> String {
        let rows = resolved.sessions.map { "\($0.id):\($0.status)" }.joined(separator: ",")
        return resolved.state.pillText + "|" + rows
    }

    /// 峰谷状态的指纹；隐藏时也有稳定的字符串。
    /// - Parameter state: 一次解析结果。
    /// - Returns: 指纹字符串。
    private func signatureOfPeak(_ state: PeakResolved?) -> String {
        guard let state else { return "hidden" }
        return "\(state.isPeak)|\(state.why ?? "")|\(state.nextSwitchAt ?? 0)"
    }

    /// 当前外观的指纹：浅色还是深色。外观变了板底色就得重画。
    /// - Returns: "light" 或 "dark"。
    private func appearanceSignature() -> String {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    }

    /// 菜单栏此刻该显示哪几颗胶囊。
    ///
    /// 有请求等待授权时**整条让给授权提示** —— 金黄条上只有一行黑字，峰谷和工作
    /// 状态都先让位：那两件事再急也不用用户动手，授权不用就会卡住。
    ///
    /// 平时从左到右是「峰谷 → 工作状态」：工作状态靠屏幕边缘、变化也最勤，让它
    /// 待在最右边不动，视觉上最稳。峰谷读不到时只剩工作状态那一颗。
    /// - Returns: 目标胶囊列表。
    private func currentPills() -> [PillVisual] {
        if pendingApprovals > 0 {
            let text = pendingApprovals > 1 ? "需要授权 \(pendingApprovals)" : "需要授权"
            return [PillVisual(id: "approval", text: text, color: Palette.alertInk)]
        }
        var pills: [PillVisual] = []
        if let state = peak {
            pills.append(PillVisual(id: "peak", text: state.pillText, color: state.pillColor))
        }
        pills.append(PillVisual(id: "work", text: work.state.pillText, color: work.state.pillColor))
        return pills
    }

    /// 把菜单栏切到新的胶囊组合 / 告警条。
    ///
    /// 状态切换走补间：底色在 sRGB 里滚过去，文字交叉淡化，胶囊宽度（连带整块板
    /// 的宽度）一起缓动 —— 峰谷读数消失时那一颗是「收拢着淡出」的，不会瞬间少一
    /// 块。进/出授权告警条也一样：玻璃板与黄条交叉淡化，不是换一张图。
    /// - Parameters:
    ///   - next: 目标胶囊列表。
    ///   - alert: 目标告警条浓度：0 = 普通，1 = 「需要授权」金黄条。
    ///   - animated: 是否走动画（首次上屏直接画）。
    private func showPills(_ next: [PillVisual], alert: CGFloat, animated: Bool) {
        guard let button = item.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = tooltip()

        guard animated, !displayed.isEmpty else {
            displayed = next
            alertness = alert
            button.image = makeBoard(
                tweens: next.map { PillTween(id: $0.id, from: $0, to: $0) },
                t: 1,
                alertness: alertness,
                appearance: NSApp.effectiveAppearance
            )
            return
        }

        let items = makeTweens(from: displayed, to: next)
        // 胶囊一模一样、告警浓度也没变，则无需动画。
        guard items.contains(where: { !same($0.from, $0.to) }) || alert != alertness else { return }
        startTween(items, target: next, alert: alert)
    }

    /// 按 id 把「现在屏上的」和「接下来要显示的」配成补间。
    ///
    /// 顺序以目标列表为准；只在旧列表里有的（正在消失的）按它原来的位置插回去，
    /// 于是峰谷那颗是从左边收回去的，而不是从右边跑掉。
    /// - Parameters:
    ///   - from: 当前屏上的胶囊。
    ///   - to: 目标胶囊。
    /// - Returns: 补间列表。
    private func makeTweens(from: [PillVisual], to: [PillVisual]) -> [PillTween] {
        var order = to.map(\.id)
        for (index, pill) in from.enumerated() where !order.contains(pill.id) {
            order.insert(pill.id, at: min(index, order.count))
        }
        return order.map { id in
            PillTween(id: id, from: from.first { $0.id == id }, to: to.first { $0.id == id })
        }
    }

    /// 两侧是不是同一个状态（省掉没必要的动画）。
    /// - Parameters:
    ///   - a: 一侧。
    ///   - b: 另一侧。
    /// - Returns: true 表示文字、底色、宽度、透明度全一样。
    private func same(_ a: PillVisual?, _ b: PillVisual?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return a.text == b.text
                && a.textWidth == b.textWidth
                && a.alpha == b.alpha
                && a.color == b.color
        default:
            return false
        }
    }

    /// 起一段补间，并确保帧循环已启动。
    /// - Parameters:
    ///   - items: 补间列表。
    ///   - target: 目标胶囊（动画跑完屏上就是它）。
    ///   - alert: 目标告警条浓度。
    private func startTween(_ items: [PillTween], target: [PillVisual], alert: CGFloat) {
        // 新一段补间从「什么都没画过」开始，第一帧无论如何都要落地。
        lastDrawnT = -1
        tween = (
            items: items,
            target: target,
            start: Date().timeIntervalSince1970,
            alertFrom: alertness,
            alertTo: alert
        )
        if frameTimer == nil {
            let timer = Timer(timeInterval: 1.0 / tweenFPS, repeats: true) { [weak self] _ in
                self?.stepTween()
            }
            RunLoop.main.add(timer, forMode: .common)
            frameTimer = timer
        }
    }

    /// 补间的一帧。
    private func stepTween() {
        guard let anim = tween, let button = item.button else { return }
        let raw = min(max((Date().timeIntervalSince1970 - anim.start) / tweenDuration, 0), 1)
        let t = easeOutCubic(raw)
        // 跳帧：ease-out 的尾巴上 t 的增量越来越小，肉眼分不出来的帧就别画了。
        // 条件里带 `raw < 1`，保证收尾那一帧一定落地。
        if raw < 1, abs(t - lastDrawnT) < 0.004 { return }
        lastDrawnT = t
        // 每帧都记下插值结果：万一动画被打断，下一段能从当前的样子接着走。
        displayed = anim.items.map { resolve($0, t: t) }
        alertness = lerp(anim.alertFrom, anim.alertTo, t)
        button.image = makeBoard(
            tweens: anim.items,
            t: t,
            alertness: alertness,
            appearance: NSApp.effectiveAppearance
        )
        trace(raw, t)

        if raw >= 1 {
            tween = nil
            frameTimer?.invalidate()
            frameTimer = nil
            displayed = anim.target
            alertness = anim.alertTo
            // 收尾必须用目标态再画一帧：补间列表里还留着那颗宽度归零的胶囊，它
            // 会多占用一个间距，板子右边会空出一块（收拢动画尤其明显）。
            button.image = makeBoard(
                tweens: anim.target.map { PillTween(id: $0.id, from: $0, to: $0) },
                t: 1,
                alertness: alertness,
                appearance: NSApp.effectiveAppearance
            )
            trace(1, 1)   // 收尾这一帧也记一笔，日志里能看到最终板宽
        }
    }

    /// 是否把补间的每一帧打到 stderr。排查动画节奏时开：`DSH_INDICATORS_TRACE=1`。
    private let traceEnabled = ProcessInfo.processInfo.environment["DSH_INDICATORS_TRACE"] == "1"

    /// 打一行补间日志：进度、告警浓度、板宽、每颗胶囊的透明度与文字宽。
    /// - Parameters:
    ///   - raw: 线性进度。
    ///   - t: 缓动后的进度。
    private func trace(_ raw: CGFloat, _ t: CGFloat) {
        guard traceEnabled else { return }
        // 板宽按当前告警浓度算：告警条的文字留白比胶囊宽，间距按存在度取小。
        let hPad = lerp(Metrics.pillHPad, Metrics.alertHPad, alertness)
        func spacing(after index: Int) -> CGFloat {
            guard index < displayed.count - 1 else { return 0 }
            return Metrics.boardGap * min(displayed[index].alpha, displayed[index + 1].alpha)
        }
        let pills = displayed
            .map { "\($0.text)α\(String(format: "%.2f", $0.alpha))tw\(String(format: "%.1f", $0.textWidth))" }
            .joined(separator: " ")
        let board = displayed.enumerated().reduce(Metrics.boardPad * 2) { total, pair in
            total + (pair.element.textWidth + hPad * 2) * pair.element.alpha + spacing(after: pair.offset)
        }
        let line = "tween raw=\(String(format: "%.3f", raw))"
            + " t=\(String(format: "%.3f", t))"
            + " alert=\(String(format: "%.2f", alertness))"
            + " board=\(String(format: "%.1f", board))pt"
            + " [\(pills)]\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// 合并后的悬停提示：授权（有的话）+ 工作状态 + 峰谷。
    /// - Returns: 提示文本。
    private func tooltip() -> String {
        var blocks: [String] = []
        if pendingApprovals > 0 {
            blocks.append("有 \(pendingApprovals) 个操作等待在 DSH 中授权")
        }
        blocks.append(workTooltip())
        if let state = peak { blocks.append(peakTooltip(state)) }
        return blocks.joined(separator: "\n")
    }

    /// 工作状态的悬停提示。
    private func workTooltip() -> String {
        var lines: [String] = []
        switch work.state {
        case .working(let n):
            lines.append("DSH Agent：工作中（\(n) 个运行中）")
        case .idle(let n):
            lines.append("DSH Agent：空闲（\(n) 个会话在线）")
        case .offline:
            lines.append("DSH Agent：离线")
            if let age = work.ageMs {
                lines.append("最后一次心跳在 \(Int(age / 1000)) 秒前")
            } else {
                lines.append("找不到状态文件")
            }
        }
        for row in work.sessions.prefix(5) where row.status == "running" {
            lines.append("• " + displayName(for: row))
        }
        return lines.joined(separator: "\n")
    }

    /// 峰谷的悬停提示。
    /// - Parameter state: 峰谷状态。
    /// - Returns: 提示文本。
    private func peakTooltip(_ state: PeakResolved) -> String {
        var lines: [String] = [
            state.isPeak ? "DeepSeek API：峰（高峰时段，全价）" : "DeepSeek API：谷（空闲时段，半价）"
        ]
        if let why = state.why { lines.append("判定依据：" + why) }
        if let next = state.nextSwitchAt {
            let moment = formatMoment(next, timeZone: state.timezone)
            lines.append("下次切换：" + moment + " → " + ((state.nextIsPeak ?? false) ? "峰" : "谷"))
        }
        var footer: [String] = []
        if let updated = state.rulesUpdatedAt { footer.append("规则更新于 " + updated) }
        if let source = state.sourceName { footer.append(source) }
        if !footer.isEmpty { lines.append(footer.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }

    /// 下拉菜单：只留两个动作。
    ///
    /// 刻意不列对话 —— 状态随时在变，一行行列出来又长又看不完（实测开了 9 个对话时菜单
    /// 几乎占满半屏），而菜单栏真正需要回答的问题只有一个：要不要现在把 DSH 调到前面来。
    /// 想知道有哪些对话在运行，看悬停 tooltip；要在具体某个对话里干活，去 DSH 里点。
    /// - Returns: 菜单。
    private func sharedMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "打开 DeepSeek Harness", action: #selector(openDSH), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出菜单栏指示器", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openDSH() {
        // 优先唤醒已经打开的 DeepSeek Harness；没开就用浏览器打开 Web GUI。
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL else { continue }
            if url.lastPathComponent.hasPrefix("DeepSeek Harness") {
                app.activate()
                return
            }
        }
        if let url = URL(string: "http://127.0.0.1:19387") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

/// 自检用：一板静止的胶囊（或告警条）。
/// - Parameters:
///   - pills: 胶囊列表。
///   - t: 补间进度（静止传 1）。
///   - alertness: 告警条浓度 0…1。
///   - dark: 是否深色外观。
/// - Returns: 菜单栏图标。
func boardImage(_ pills: [PillVisual], t: CGFloat, alertness: CGFloat = 0, dark: Bool) -> NSImage {
    makeBoard(
        tweens: pills.map { PillTween(id: $0.id, from: $0, to: $0) },
        t: t,
        alertness: alertness,
        appearance: NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
    )
}

/// 把一张图写成 PNG 并打印尺寸（自检用）。
/// - Parameters:
///   - image: 图片。
///   - path: 目标路径。
func writePNG(_ image: NSImage, to path: String) {
    let reps = image.representations
        .map { "\($0.pixelsWide)x\($0.pixelsHigh)px" }
        .joined(separator: ",")
    print("\((path as NSString).lastPathComponent): \(image.size.width)x\(image.size.height)pt reps=\(reps)")
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

// --pill <前缀>：把几个胶囊图标写成 PNG 并打印真实尺寸，用来核对样式，
// 不用启动界面。排查菜单栏图标被裁/发虚时先跑这个。
if let index = CommandLine.arguments.firstIndex(of: "--pill") {
    let prefix = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : "/tmp/indicator-pill"
    let samples: [(String, NSColor, String)] = [
        ("work", Palette.working, "工作中"),
        ("idle", Palette.idle, "空闲"),
        ("offline", Palette.offline, "离线"),
        ("peak", Palette.peak, "峰"),
        ("off", Palette.off, "谷"),
    ]
    print("screen scale = \(NSScreen.main?.backingScaleFactor ?? 2)")
    for (name, color, text) in samples {
        writePNG(makePill(text, background: color), to: "\(prefix)-\(name).png")
    }
    exit(0)
}

// --board <前缀>：把「玻璃板 + 胶囊」的几种状态写成 PNG（浅色/深色各一遍），
// 再导出两组补间的中间帧（状态切换 / 峰谷收拢淡出），用来核对质感、同心圆角和
// 动画节奏，全程不用启动界面。
if let index = CommandLine.arguments.firstIndex(of: "--board") {
    let prefix = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : "/tmp/indicator-board"
    let idle = [
        PillVisual(id: "peak", text: "谷", color: Palette.off),
        PillVisual(id: "work", text: "空闲", color: Palette.idle),
    ]
    let busy = [
        PillVisual(id: "peak", text: "峰", color: Palette.peak),
        PillVisual(id: "work", text: "工作中", color: Palette.working),
    ]
    let statics: [(String, [PillVisual])] = [
        ("idle-off", idle),
        ("work-peak", busy),
        ("idle-nopeak", [idle[1]]),
    ]
    // 授权告警：整条金黄底 + 近黑字，别的什么都不显示。
    let alertPills = [PillVisual(id: "approval", text: "需要授权", color: Palette.alertInk)]
    print("screen scale = \(NSScreen.main?.backingScaleFactor ?? 2)")
    for (name, pills) in statics {
        for dark in [false, true] {
            writePNG(boardImage(pills, t: 1, dark: dark), to: "\(prefix)-\(name)-\(dark ? "dark" : "light").png")
        }
    }
    for dark in [false, true] {
        writePNG(
            boardImage(alertPills, t: 1, alertness: 1, dark: dark),
            to: "\(prefix)-alert-\(dark ? "dark" : "light").png"
        )
    }

    let steps: [(String, CGFloat)] = [("t00", 0), ("t35", 0.35), ("t70", 0.70), ("t100", 1)]
    // 空→忙：底色从绿/灰滚到红/蓝，文字同时交叉淡化。
    let morph = [
        PillTween(id: "peak", from: idle[0], to: busy[0]),
        PillTween(id: "work", from: idle[1], to: busy[1]),
    ]
    // 峰谷读数消失：那一颗收拢着淡出，板子跟着变窄。
    let collapse = [
        PillTween(id: "peak", from: idle[0], to: nil),
        PillTween(id: "work", from: idle[1], to: idle[1]),
    ]
    // 普通 → 需要授权：两颗胶囊收掉，黄条带着黑字长出来。
    let toAlert = [
        PillTween(id: "peak", from: idle[0], to: nil),
        PillTween(id: "work", from: idle[1], to: nil),
        PillTween(id: "approval", from: nil, to: alertPills[0]),
    ]
    let aqua = NSAppearance(named: .aqua) ?? NSApp.effectiveAppearance
    for (label, raw) in steps {
        let t = easeOutCubic(raw)
        writePNG(
            makeBoard(tweens: morph, t: t, alertness: 0, appearance: aqua),
            to: "\(prefix)-morph-\(label).png"
        )
        writePNG(
            makeBoard(tweens: collapse, t: t, alertness: 0, appearance: aqua),
            to: "\(prefix)-collapse-\(label).png"
        )
        writePNG(
            makeBoard(tweens: toAlert, t: t, alertness: t, appearance: aqua),
            to: "\(prefix)-toalert-\(label).png"
        )
    }
    exit(0)
}

// --dump：不开界面，打印一次解析结果后退出。给自动化/自检用。
if CommandLine.arguments.contains("--dump") {
    let resolved = resolve()
    let workName: String
    switch resolved.work.state {
    case .working: workName = "working"
    case .idle: workName = "idle"
    case .offline: workName = "offline"
    }
    var payload: [String: Any] = [
        "workState": workName,
        "workRunning": resolved.work.sessions.filter { $0.status == "running" }.count,
        "workSessions": resolved.work.sessions.count,
        "workAgeMs": resolved.work.ageMs ?? -1,
        "path": statusFilePath,
        "exists": FileManager.default.fileExists(atPath: statusFilePath),
    ]
    if let peak = resolved.peak {
        payload["peakState"] = peak.isPeak ? "peak" : "off"
        payload["peakWhy"] = peak.why ?? ""
        payload["peakNextSwitchAt"] = peak.nextSwitchAt ?? -1
        payload["peakVisible"] = true
    } else {
        payload["peakState"] = "unavailable"
        payload["peakVisible"] = false
    }
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

let app = NSApplication.shared
let controller = MenuBarController()
app.delegate = controller
app.run()
