import Foundation
import ReplayKit
import UIKit

/// ⭐⭐⭐⭐⭐ 「眼」—— **程序化启动 ReplayKit 广播 + 读帧**（v0.9.0）。
///
/// ## 两条取帧路（都保留）
/// | 路 | 谁读 | 需 App 前台 | 需网络 |
/// |---|---|---|---|
/// | **A. 本机文件**（默认）| App 自己读 Documents | ⛔ 不需要（扩展写）| ⛔ 不需要 |
/// | **B. AFC 通道**（PC）| PC 用 house_arrest 读 | ⛔ 不需要 | ⛔ 不需要 |
///
/// **⇒ 扩展把帧写进 Documents/lastframe.jpg，谁都能读。**
///
/// ## 程序化启动（照 `livekit/client-sdk-swift#1065` 的实测做法）
/// ```swift
/// let view = RPSystemBroadcastPickerView()
/// view.preferredExtension = "run.pgagent.PGAgent.PGShot"
/// view.showsMicrophoneButton = false
/// // ⭐ 找内部 UIButton，直接触发（只用公开 API）
/// view.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
/// ```
final class BroadcastStarter: ObservableObject {

    /// 扩展的 bundle id
    ///
    /// ⚠️⚠️ **不能写死** —— 签名工具（爱思）会在签名时插入 team 后缀：
    /// ```
    /// 我们构建时:  run.pgagent.PGAgent.PGShot
    /// 爱思签名后:  run.pgagent.PGAgent.8W9ZSMW4UW.PGShot   ← team id 插在中间
    /// ```
    /// ⇒ 所以**从已安装的 App 包里动态找**（`PlugIns/*.appex` 的 CFBundleIdentifier）。
    static var extensionBundleID: String {
        if let cached = _cachedExtID { return cached }
        guard let url = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil) else {
            // 兜底：用构建时的名字
            return "run.pgagent.PGAgent.PGShot"
        }
        for it in items where it.pathExtension == "appex" {
            let plist = it.appendingPathComponent("Info.plist")
            if let d = NSDictionary(contentsOf: plist),
               let bid = d["CFBundleIdentifier"] as? String {
                _cachedExtID = bid
                return bid
            }
        }
        return "run.pgagent.PGAgent.PGShot"
    }

    private static var _cachedExtID: String?

    /// 帧文件名（⭐ 与 PGShot/SampleHandler.swift 一致）
    static let frameName = "lastframe.jpg"
    /// 停止标志文件名
    static let stopFlagName = "stop_broadcast"

    /// ⭐⭐⭐⭐ 「眼」的取帧目录。
    ///
    /// **§2210 关键实测**：扩展和主 App 的 Documents 是**两个不同容器**
    /// ```
    /// 主 App 容器 : .../PGAgent.8W9ZSMW4UW/Documents        ⇒ 只有 pgconfig
    /// 扩展容器    : .../PGAgent.8W9ZSMW4UW.PGShot/Documents ⇒ 128 个帧 ✅
    /// ```
    /// ⇒ 帧必须落在 **App Group 共享容器** `<group>/Documents/frames/` 里，两边同目录。
    ///
    /// 取帧顺序（**先共享，后本容器**）：
    ///   ① App Group 共享目录（扩展写这里 ⇒ 主 App 直接读）⭐ 推荐
    ///   ② 本 App 的 Documents（老版本扩展写这里；兜底/兼容）
    static func framesDir() -> URL? {
        AppGroup.framesDir()
    }

    /// 帧文件的候选位置（按优先级）：共享容器优先，然后本容器
    private static func frameCandidates(_ name: String) -> [URL] {
        var out: [URL] = []
        if let d = AppGroup.framesDir() {
            out.append(d.appendingPathComponent(name))
        }
        out.append(docsURL().appendingPathComponent(name))
        return out
    }

    @Published private(set) var started = false
    @Published private(set) var lastError = ""
    /// ⚠️ 这是**给 UI 的**计数（只能在主线程读）
    @Published private(set) var frames = 0
    /// ⚠️ 这是**给 UI 的**最近帧时间（只能在主线程读）
    @Published private(set) var lastFrameAt: Date?

    /// ⭐ **任意线程**可安全读的帧计数（与 `frames` 同步递增）
    ///
    /// 为什么要有两个：`frames`是 `@Published`（UI 用，主线程）；
    /// 而 HTTP handler / Runner 在后台线程 ⇒ 读 `frames` 是数据竞争。
    /// ⇒ 后台一律读这个（受 `frameLock` 保护）。
    var frameCount: Int {
        frameLock.lock(); defer { frameLock.unlock() }
        return _frameCount
    }
    private var _frameCount = 0
    /// ⭐ 最近一帧（JPEG 数据）—— 识别模块直接读
    ///
    /// ⚠️ 这是**加锁的计算属性**（底层 `_lastFrame`）：
    /// 写方是 timer / HTTP handler，读方是 `Runner.grabSync`（另一个队列）
    /// ⇒ 必须串行化，否则会读到「Data 正在被替换」的中间态。
    var lastFrame: Data? {
        frameLock.lock(); defer { frameLock.unlock() }
        return _lastFrame
    }
    private var _lastFrame: Data?

    /// ⭐ 最近一帧的到达时间（任意线程读写，⛔ 不是 @Published）
    private var lastFrameReceivedAt: Date?
    private var lastSeq = -1
    /// ⭐ 上一帧的修改时间（判新用；见 `pollFrame`）
    private var lastFrameMTime: Date?
    /// ⭐ 最近一帧来自哪个文件（诊断用）
    private(set) var lastFramePath = "-"
    /// ⛔ **帧状态锁**：`pollFrame`（主线程 timer）与 `Runner.grabSync`
    ///    （runner 队列）会**并发**碰 `lastFrame` / `lastSeq` / `lastFrameMTime`
    ///    ⇒ 必须串行化，否则读到半更新的状态。
    ///    ⚠️ 铁律：**持锁期间绝不调用外部代码**（否则易死锁）。
    private let frameLock = NSLock()
    private var watchTimer: Timer?
    /// ⭐ 宿主窗口（强引用住 —— ⛔ 别让 UIKit 提前释放它，否则 picker 不响应）
    private var hostHost: UIWindow?

    // MARK: - 路径

    static func docsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// ⚠️ 帧**不在**这里（扩展写在共享容器）—— 仅供 `/rec/save` 等写文件用
    static func frameURL() -> URL {
        docsURL().appendingPathComponent(frameName)
    }

    /// ⭐ 共享容器里的帧路径（没有共享容器 ⇒ nil）
    static func sharedFrameURL() -> URL? {
        AppGroup.framesDir()?.appendingPathComponent(frameName)
    }

    /// ⭐ 停止标志的**两个**候选位置（主 App 写在共享容器 + 自己 Documents 都放）
    static func stopFlagURLs() -> [URL] {
        var out: [URL] = []
        if let d = AppGroup.framesDir() {
            out.append(d.appendingPathComponent(stopFlagName))
        }
        out.append(docsURL().appendingPathComponent(stopFlagName))
        return out
    }

    static func stopFlagURL() -> URL {
        stopFlagURLs()[0]
    }

    /// ⭐⭐ 找到**当前最新的一帧**文件（共享容器优先），并返回它的 mtime+大小
    ///
    /// 为什么要比 mtime：扩展以 2fps 覆写同一个 `lastframe.jpg`，
    /// 只比大小会漏帧（画面变了但字节数相同）⇒ **用 mtime 判新**。
    private func newestFrameFile() -> (URL, Date, Int)? {
        let fm = FileManager.default
        var best: (URL, Date, Int)?
        for u in Self.frameCandidates(Self.frameName) {
            guard let a = try? fm.attributesOfItem(atPath: u.path),
                  let m = a[.modificationDate] as? Date,
                  let n = (a[.size] as? NSNumber)?.intValue, n > 0 else { continue }
            if best == nil || m > best!.1 { best = (u, m, n) }
        }
        return best
    }

    // MARK: - ⭐⭐ 程序化启动录屏（⛔ 不用人手点）

    @discardableResult
    func start() -> Bool {
        // ⛔ `lastError` 是 @Published ⇒ 只能在主线程改（本方法会被后台 handler 调）
        if Thread.isMainThread { lastError = "" }
        else { DispatchQueue.main.async { self.lastError = "" } }
        NSLog("PGAgent BroadcastStarter: start() 进入")
        // ① 清掉停止标志（荔枝的做法：`startBroadcast() - 已删除停止录屏标志文件`）
        //    两个位置都清（纯文件操作，⛔ 不碰 UIKit，任何线程都安全）
        for u in Self.stopFlagURLs() { try? FileManager.default.removeItem(at: u) }

        // ② 检查扩展在不在（⭐ 排查「扩展没注册」）
        let extOK = Self.extensionExists()
        NSLog("PGAgent BroadcastStarter: 扩展已注册 = %@", extOK ? "是" : "否")
        // ⭐ 顺带确认共享容器（这是「眼」能不能用的**决定因素**）
        NSLog("PGAgent BroadcastStarter: 共享帧目录 = %@",
              Self.framesDir()?.path ?? "⛔ 无（帧将读不到！）")

        // ③ ⛔⛔ **UIKit 全部回主线程**
        //
        // 本方法会被 HTTP handler 调用，而 handler 跑在
        // `DispatchQueue.global(qos:.userInitiated)`（见 HTTPServer.handleAsync）
        // ⇒ 在**后台线程**碰 UIKit（RPSystemBroadcastPickerView / UIWindow /
        //   addSubview / makeKeyAndVisible）⇒ iOS 直接崩：
        //   `EXC_BREAKPOINT (SIGTRAP)` ← `_dispatch_assert_queue_fail`
        //   ← `-[UIImageView setHidden:]` ← `-[UIButton layoutSubviews]`
        //   （真机崩溃日志 `PGAgent-2026-10-10-161734.ips`）
        //
        // ⚠️ **已在主线程时必须直接调用**（UI 按钮走这条路）——
        //    否则 `DispatchQueue.main.async` + 等信号量 ⇒ **自死锁**。
        let ok = Thread.isMainThread ? startOnMain()
                                     : (MainThread.run { self.startOnMain() } ?? false)
        guard ok else { return false }

        // ⛔ `started` 也是 @Published ⇒ 主线程改
        setStarted(true)
        NSLog("PGAgent BroadcastStarter: 已触发 %@", Self.extensionBundleID)

        // ④ 开始盯文件（扩展每写一帧，我们就更新一次）
        startWatching()
        return true
    }

    /// ⭐ 安全地改 `started`（`@Published` ⇒ 只能在主线程）
    private func setStarted(_ v: Bool) {
        if Thread.isMainThread { started = v }
        else { DispatchQueue.main.async { self.started = v } }
    }

    /// ⭐ **只在主线程**执行的 UIKit 部分（由 `start()` 用信号量同步调用）。
    private func startOnMain() -> Bool {
        // 建 picker 并程序化触发
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Self.extensionBundleID
        picker.showsMicrophoneButton = false
        NSLog("PGAgent BroadcastStarter: picker subviews = %d", picker.subviews.count)

        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
            lastError = "RPSystemBroadcastPickerView 里没找到 UIButton（subviews=\(picker.subviews.count)）"
            NSLog("PGAgent BroadcastStarter: %@", lastError)
            return false
        }
        NSLog("PGAgent BroadcastStarter: 找到 UIButton，准备 sendActions")

        // 放进一个**可见**的宿主窗口（有些 iOS 版本要求它在可见层级里才会响应）
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        host.rootViewController = UIViewController()
        host.rootViewController?.view.addSubview(picker)
        host.isHidden = false
        host.windowLevel = .alert + 1
        host.makeKeyAndVisible()
        hostHost = host          // ⭐ 强引用住（⛔ 别让它被释放）

        // 让视图先布局一帧，再触发（更快更稳）
        picker.layoutIfNeeded()
        button.sendActions(for: .touchUpInside)
        NSLog("PGAgent BroadcastStarter: 已 sendActions(.touchUpInside)")
        return true
    }

    /// ⭐ 检查扩展有没有注册进 App（排查「extension not found」）
    static func extensionExists() -> Bool {
        guard let url = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil) else { return false }
        return items.contains { $0.pathExtension == "appex" }
    }

    /// ⭐ 列出已注册的广播扩展（诊断用）
    static func listExtensions() -> [String] {
        guard let url = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "appex" }.map { $0.lastPathComponent }
    }

    /// 停止录屏：放一个停止标志文件（荔枝的做法）
    ///
    /// ⭐ 写到**两个**位置：扩展优先看共享容器，但它也可能退回自己的/
    ///    主 App 的 Documents ⇒ 都放一份，确保扩展一定收到。
    func stop() {
        // ⭐ timer 只在主线程动（invalidate 跨线程可能崩/无效）
        if Thread.isMainThread {
            watchTimer?.invalidate(); watchTimer = nil
        } else {
            DispatchQueue.main.async { self.watchTimer?.invalidate(); self.watchTimer = nil }
        }
        for u in Self.stopFlagURLs() {
            try? Data("stop".utf8).write(to: u)
            NSLog("PGAgent BroadcastStarter: 已放停止标志 %@", u.path)
        }
        setStarted(false)
    }

    // MARK: - ⭐ 盯帧文件（**共享容器优先**，⛔ 不需要网络）

    /// ⭐⭐ 开始轮询帧文件。
    ///
    /// ⛔⛔ **必须回主线程建 Timer**（§2212 同类坑）：
    /// `Timer.scheduledTimer` 会把 timer 挂到**当前线程**的 RunLoop 上，
    /// 并要求该 RunLoop **正在跑**。本方法由 HTTP handler（后台队列）调用 ⇒
    /// 建在后台队列上 ⇒ 那个 RunLoop 从不 run ⇒ **timer 永远不触发** ⇒
    /// 「录屏在跑，但 App 一帧都读不到」（正是「眼瞎」的另一个成因）。
    ///
    /// ⇒ 统一：**主线程建 timer**（主 RunLoop 一直在跑，必然触发）。
    private func startWatching() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.startWatching() }
            return
        }
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollFrame()
        }
    }

    /// 读一次帧（顺手处理 `.tmp` 原子写残留）
    ///
    /// ⭐ 判新用 **mtime**（不是字节数）：扩展 2fps 覆写同名文件，
    ///    画面变了但压缩后字节数可能相同 ⇒ 只比大小会漏帧。
    @discardableResult
    func pollFrame() -> Bool {
        // 清掉可能的 .tmp 残留（write() 用 name+".tmp"）—— 纯文件操作，锁外做
        for u in Self.frameCandidates(Self.frameName + ".tmp") {
            if FileManager.default.fileExists(atPath: u.path) {
                try? FileManager.default.removeItem(at: u)
            }
        }
        guard let (u, m, n) = newestFrameFile() else { return false }

        // ⭐ 临界区：只用**纯内存**判断与更新（⛔ 不读 @Published、⛔ 不碰文件）
        frameLock.lock()
        if let last = lastFrameMTime, m <= last { frameLock.unlock(); return false }
        let nextSeq = lastSeq + 1
        frameLock.unlock()

        guard let d = try? Data(contentsOf: u), !d.isEmpty else { return false }

        frameLock.lock()
        lastFrameMTime = m
        lastFramePath = u.path
        frameLock.unlock()

        onFrame(d, seq: nextSeq)
        _ = n
        return true
    }

    /// ⭐ 取「当前帧是否已就绪」的快照（供 Runner 判断）
    ///
    /// ⚠️ 必须读 `_lastFrame`（**不是** `lastFrame`）：`lastFrame` 的 getter
    ///    自己会拿 `frameLock`，而 `NSLock` **不可重入** ⇒ 在锁内调它会**自死锁**。
    func hasFrame() -> Bool {
        frameLock.lock(); defer { frameLock.unlock() }
        return _lastFrame != nil
    }

    /// 扩展送帧进来时调用（HTTP 路也走这里）
    ///
    /// ⛔ `@Published` 属性（`frames` / `lastFrameAt`）**只能在主线程改**，
    /// 否则 SwiftUI 会在后台线程收到变更通知 ⇒ 与 §2212 同类的崩。
    /// `lastFrame`（非 Published，识别模块读）可在任意线程写。
    @discardableResult
    func onFrame(_ data: Data, seq: Int) -> Bool {
        // ⭐ 临界区：只做纯内存更新
        frameLock.lock()
        if seq >= 0 && seq < lastSeq { frameLock.unlock(); return false }
        if seq >= 0 { lastSeq = seq }
        _lastFrame = data
        _frameCount += 1
        let n = _frameCount
        lastFrameReceivedAt = Date()
        let at = lastFrameReceivedAt
        frameLock.unlock()

        // ⛔ `@Published`（frames / lastFrameAt）**只能在主线程改**
        if Thread.isMainThread {
            frames = n
            lastFrameAt = at
        } else {
            DispatchQueue.main.async {
                self.frames = n
                self.lastFrameAt = at
            }
        }
        return true
    }

    func snapshot() -> [String: Any] {
        let shared = Self.framesDir()
        // ⭐ 一次性把锁内状态取出来（⛔ 不在字典字面量里多次加锁）
        frameLock.lock()
        let bytes = _lastFrame?.count ?? 0
        let path = lastFramePath
        let mtime = lastFrameMTime
        let recvAt = lastFrameReceivedAt
        frameLock.unlock()
        return [
            "started": started,
            "frames": frameCount,
            "lastFrameAgo": (recvAt ?? lastFrameAt)
                .map { Date().timeIntervalSince($0) } ?? -1,
            "lastFrameBytes": bytes,
            "lastFramePath": path,
            "lastFrameMTime": mtime
                .map { ISO8601DateFormatter().string(from: $0) } ?? "-",
            "error": lastError,
            "extension": Self.extensionBundleID,
            "extensionExists": Self.extensionExists(),
            "extensions": Self.listExtensions(),
            // ⭐⭐ 「眼」的关键诊断：帧到底落在哪、共享容器有没有生效
            "sharedFramesDir": shared?.path ?? "(nil) ⛔ 无共享容器",
            "sharedFrameFile": Self.sharedFrameURL()?.path ?? "(nil)",
            "frameCandidates": Self.frameCandidates(Self.frameName).map { p -> [String: Any] in
                let a = try? FileManager.default.attributesOfItem(atPath: p.path)
                return ["path": p.path,
                        "exists": FileManager.default.fileExists(atPath: p.path),
                        "bytes": (a?[.size] as? NSNumber)?.intValue ?? -1,
                        "mtime": (a?[.modificationDate] as? Date)
                            .map { ISO8601DateFormatter().string(from: $0) } ?? "-"]
            },
            "framePath": Self.frameURL().path,
            "stopFlagExists": Self.stopFlagURLs()
                .contains { FileManager.default.fileExists(atPath: $0.path) },
            "docs": (try? FileManager.default.contentsOfDirectory(
                        atPath: Self.docsURL().path)) ?? [],
        ]
    }
}
