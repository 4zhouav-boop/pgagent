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

    @Published private(set) var started = false
    @Published private(set) var lastError = ""
    @Published private(set) var frames = 0
    @Published private(set) var lastFrameAt: Date?
    /// ⭐ 最近一帧（JPEG 数据）—— 识别模块直接读
    private(set) var lastFrame: Data?

    private var lastSeq = -1
    private var watchTimer: Timer?
    /// ⭐ 宿主窗口（强引用住 —— ⛔ 别让 UIKit 提前释放它，否则 picker 不响应）
    private var hostHost: UIWindow?

    // MARK: - 路径

    static func docsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func frameURL() -> URL {
        docsURL().appendingPathComponent(frameName)
    }

    static func stopFlagURL() -> URL {
        docsURL().appendingPathComponent(stopFlagName)
    }

    // MARK: - ⭐⭐ 程序化启动录屏（⛔ 不用人手点）

    @discardableResult
    func start() -> Bool {
        lastError = ""
        NSLog("PGAgent BroadcastStarter: start() 进入")
        // ① 清掉停止标志（荔枝的做法：`startBroadcast() - 已删除停止录屏标志文件`）
        try? FileManager.default.removeItem(at: Self.stopFlagURL())

        // ② 检查扩展在不在（⭐ 排查「扩展没注册」）
        let extOK = Self.extensionExists()
        NSLog("PGAgent BroadcastStarter: 扩展已注册 = %@", extOK ? "是" : "否")

        // ③ 建 picker 并程序化触发
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            button.sendActions(for: .touchUpInside)
            NSLog("PGAgent BroadcastStarter: 已 sendActions(.touchUpInside)")
        }
        started = true
        NSLog("PGAgent BroadcastStarter: 已触发 %@", Self.extensionBundleID)

        // ③ 开始盯文件（扩展每写一帧，我们就更新一次）
        startWatching()
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
    func stop() {
        watchTimer?.invalidate(); watchTimer = nil
        let u = Self.stopFlagURL()
        try? Data("stop".utf8).write(to: u)
        started = false
        NSLog("PGAgent BroadcastStarter: 已放停止标志 %@", u.path)
    }

    // MARK: - ⭐ 盯 Documents/lastframe.jpg（本机读取，⛔ 不需要网络）

    private func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollFrame()
        }
    }

    /// 读一次帧文件（顺手处理 .tmp 原子写残留）
    func pollFrame() {
        let u = Self.frameURL()
        // 清掉可能的 .tmp 残留
        let tmp = u.appendingPathExtension("tmp")
        if FileManager.default.fileExists(atPath: tmp.path) {
            try? FileManager.default.removeItem(at: tmp)
        }
        guard let d = try? Data(contentsOf: u), !d.isEmpty else { return }
        onFrame(d, seq: frames + 1)
    }

    /// 扩展送帧进来时调用（HTTP 路也走这里）
    @discardableResult
    func onFrame(_ data: Data, seq: Int) -> Bool {
        if seq >= 0 && seq < lastSeq { return false }
        lastSeq = seq
        lastFrame = data
        frames += 1
        lastFrameAt = Date()
        DispatchQueue.main.async { self.objectWillChange.send() }
        return true
    }

    func snapshot() -> [String: Any] {
        [
            "started": started,
            "frames": frames,
            "lastFrameAgo": lastFrameAt.map { Date().timeIntervalSince($0) } ?? -1,
            "lastFrameBytes": lastFrame?.count ?? 0,
            "error": lastError,
            "extension": Self.extensionBundleID,
            "extensionExists": Self.extensionExists(),
            "extensions": Self.listExtensions(),
            "framePath": Self.frameURL().path,
            "stopFlagExists": FileManager.default.fileExists(atPath: Self.stopFlagURL().path),
            "docs": (try? FileManager.default.contentsOfDirectory(
                        atPath: Self.docsURL().path)) ?? [],
        ]
    }
}
