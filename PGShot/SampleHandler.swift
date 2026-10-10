import ReplayKit
import UIKit

/// ⭐⭐⭐⭐ 「眼」—— **录屏广播扩展**（这是荔枝/所有 RPA App 的真正做法）。
///
/// ## 为什么这条路对
/// · 第三方 App **无法截别的 App 的屏**（沙箱）
/// · 但 **ReplayKit 广播扩展** 能拿到**整块屏幕的连续视频帧**
/// · 而且主 App 可以用 `RPSystemBroadcastPickerView` + `sendActions(for: .touchUpInside)`
///   **程序化启动它**（⛔ 不用人手点）—— 见 `livekit/client-sdk-swift#1065` 的实测报告：
///   > Tested on a physical iPhone: the system broadcast picker opens via `requestActivation()`,
///   > shows the app's broadcast extension preselected, and **the broadcast starts and publishes normally**
///
/// ## 链路
/// ```
/// 主 App: RPSystemBroadcastPickerView().triggerPicker()   ← 程序化启动
///   ↓
/// iOS 启动本扩展 (RPBroadcastSampleHandler)
///   ↓
/// processSampleBuffer(每帧) ⇒ 编码成 JPEG ⇒ 写进共享容器
///   ↓
/// 主 App 读共享容器 ⇒ 得到「眼」
/// ```
///
/// ## ⚠️ 免费 Apple ID 的约束（`_note_1798` 实测）
/// · 描述文件里**只有 4 项 entitlement**（application-identifier / team-identifier /
///   get-task-allow / keychain-access-groups）⇒ **⛔ 不能用 App Group**
/// · ⇒ 所以扩展与主 App 之间**不能走 App Group 共享目录**
/// · ✅ 替代：扩展写到自己沙箱的 `Documents`，主 App 通过 **IPC socket** 收
///   （LiveKit 也是这个做法：`BroadcastUploader(socketPath:)`）
/// · 但 socket 需要 `NSFileCoordinator`/共享容器在扩展里可达……
///
/// ## ⭐ 本实现的取舍
/// 先用**最简单能验证的方式**：扩展把帧写成 JPEG 到自己 Documents，
/// 主 App 用 `UIFileSharingEnabled` 暴露的同一路径读（同进程组不同容器时不可行时，
/// 退回「扩展直接发 HTTP 给主 App 的 127.0.0.1 端口」——但扩展在自己的沙箱里，
/// 127.0.0.1 是**同一台设备**，所以**可以**连主 App 的 HTTP 服务！）。
///
/// ⇒ 采用：**扩展 → HTTP POST 到主 App 的 127.0.0.1:8899/frame**（本机回环，同一设备）。
class SampleHandler: RPBroadcastSampleHandler {

    private var seq = 0
    private var lastSent = Date.distantPast
    private var fps = 2.0                 // 默认 2 fps（够识别用，省电省流量）
    private let port: UInt16 = 8899
    private var session: URLSession?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        NSLog("PGShot broadcastStarted")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 2
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    override func broadcastPaused() { NSLog("PGShot broadcastPaused") }
    override func broadcastResumed() { NSLog("PGShot broadcastResumed") }

    override func broadcastFinished() {
        NSLog("PGShot broadcastFinished")
        session?.invalidateAndCancel()
        session = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        // 限流：默认 2 fps
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= (1.0 / fps) else { return }
        lastSent = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let img = UIImage(cgImage: cg)
        guard let jpg = img.jpegData(compressionQuality: 0.6) else { return }

        seq += 1
        post(jpg, seq: seq)
    }

    /// ⭐ 发到主 App 的 HTTP 服务（**同一台设备**，所以 127.0.0.1 通）
    private func post(_ data: Data, seq: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/frame?seq=\(seq)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        session?.dataTask(with: req) { _, _, err in
            if let err = err {
                NSLog("PGShot frame post failed: %@", String(describing: err))
            }
        }.resume()
    }
}
