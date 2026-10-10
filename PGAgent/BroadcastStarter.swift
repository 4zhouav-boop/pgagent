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

    /// 扩展的 bundle id（⛔ 必须与 project.yml 一致）
    static let extensionBundleID = "run.pgagent.PGAgent.PGShot"

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
        // ① 清掉停止标志（荔枝的做法：`startBroadcast() - 已删除停止录屏标志文件`）
        try? FileManager.default.removeItem(at: Self.stopFlagURL())

        // ② 建 picker 并程序化触发
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Self.extensionBundleID
        picker.showsMicrophoneButton = false

        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
            lastError = "RPSystemBroadcastPickerView 里没找到 UIButton"
            NSLog("PGAgent BroadcastStarter: %@", lastError)
            return false
        }

        // 放到一个屏幕外的宿主窗口（有些 iOS 版本要求它在视图层级里）
        let host = UIWindow(frame: CGRect(x: -120, y: -120, width: 44, height: 44))
        host.rootViewController = UIViewController()
        host.rootViewController?.view.addSubview(picker)
        host.isHidden = false
        host.windowLevel = .alert + 1

        button.sendActions(for: .touchUpInside)
        started = true
        NSLog("PGAgent BroadcastStarter: 已触发 %@", Self.extensionBundleID)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            picker.removeFromSuperview()
            host.isHidden = true
        }

        // ③ 开始盯文件（扩展每写一帧，我们就更新一次）
        startWatching()
        return true
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
            "framePath": Self.frameURL().path,
        ]
    }
}
