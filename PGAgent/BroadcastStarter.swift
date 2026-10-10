import Foundation
import ReplayKit
import UIKit

/// ⭐⭐⭐⭐ 「眼」—— **程序化启动 ReplayKit 广播**（荔枝/所有 RPA App 的做法）。
///
/// ## 依据（GitHub 实证）
/// `livekit/client-sdk-swift#1065`（2026-07-27 merged）：
/// > Both now activate the picker using **only public API**: locate the picker's `UIButton`
/// > subview and fire it via `sendActions(for: .touchUpInside)`.
/// > … **Tested on a physical iPhone: the system broadcast picker opens via `requestActivation()`,
/// > shows the app's broadcast extension preselected, and the broadcast starts and publishes normally**
///
/// 其完整实现只有几行：
/// ```swift
/// static func showPicker(for preferredExtension: String?) {
///     let view = RPSystemBroadcastPickerView()
///     view.preferredExtension = preferredExtension
///     view.showsMicrophoneButton = false
///     view.triggerPicker()          // 找 UIButton → sendActions(.touchUpInside)
/// }
/// ```
///
/// ## 优点（对比快捷指令）
/// | 项 | 快捷指令 | 录屏扩展 |
/// |---|---|---|
/// | 取画面 | 导入一次，每帧切前台 | **自动启动，连续帧** |
/// | 帧率 | ~0.5 fps | **实时（限流到 2 fps 就够识别）** |
/// | 需要人手 | 导入一次 | **完全不用** |
///
/// ## 链路
/// ```
/// 主 App: BroadcastStarter.start()
///   → RPSystemBroadcastPickerView().triggerPicker()
///   → iOS 启动 PGShot 扩展
///   → 扩展每帧 POST http://127.0.0.1:8899/frame
///   → 主 App 收到帧 ⇒ 存 Documents ⇒ 这就是「眼」
/// ```
final class BroadcastStarter: ObservableObject {

    /// 扩展的 bundle id（⛔ 必须与 project.yml 里一致）
    static let extensionBundleID = "run.pgagent.PGAgent.PGShot"

    @Published private(set) var started = false
    @Published private(set) var lastError = ""
    @Published private(set) var frames = 0
    @Published private(set) var lastFrameAt: Date?

    /// ⭐ 最近一帧（JPEG 数据）—— 识别模块直接读这个
    private(set) var lastFrame: Data?

    private var lastFrameSeq = -1

    /// ⭐⭐ 程序化启动录屏（⛔ 不用人手点）
    @discardableResult
    func start() -> Bool {
        lastError = ""
        let picker = RPSystemBroadcastPickerView(
            frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = Self.extensionBundleID
        picker.showsMicrophoneButton = false
        picker.autoresizingMask = []

        // ⭐ 关键：找它内部的 UIButton，直接触发
        //    （`livekit#1065` 实测过的公开 API 做法）
        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
            lastError = "RPSystemBroadcastPickerView 里没找到 UIButton"
            NSLog("PGAgent BroadcastStarter: %@", lastError)
            return false
        }

        // 加到一个临时窗口上（有些人反馈不在视图层级里 sendActions 不生效）
        let host = UIWindow(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
        host.rootViewController = UIViewController()
        host.rootViewController?.view.addSubview(picker)
        host.isHidden = false
        host.windowLevel = .alert + 1

        button.sendActions(for: .touchUpInside)
        started = true
        NSLog("PGAgent BroadcastStarter: 已触发 %@", Self.extensionBundleID)

        // 用完释放（⛔ 别让窗口常驻）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            picker.removeFromSuperview()
            host.isHidden = true
        }
        return true
    }

    /// 扩展通过 HTTP POST 送帧进来时调用
    @discardableResult
    func onFrame(_ data: Data, seq: Int) -> Bool {
        // ⛔ 只收更新的帧（防止乱序）
        if seq >= 0 && seq < lastFrameSeq { return false }
        lastFrameSeq = seq
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
        ]
    }
}
