import ReplayKit
import UIKit

/// ⭐⭐⭐⭐⭐ 「眼」—— **录屏广播扩展**（荔枝/所有 RPA App 的真正做法）。
///
/// ## 架构（v0.9.0 改：写文件，⛔ 不发 HTTP）
/// ```
/// 主 App: RPSystemBroadcastPickerView().triggerPicker()   ← 程序化启动
///   ↓
/// iOS 启动本扩展
///   ↓
/// processSampleBuffer(每帧) ⇒ JPEG ⇒ 写进**自己的 Documents**
///   ↓
/// PC: AFC 通道 house_arrest 读 Documents/lastframe.jpg
///   ↓
/// ⛔ 不需要 App 在前台、⛔ 不需要网络、⛔ 不需要同网段
/// ```
///
/// ## 为什么改（§2020 实测对比）
/// | 方式 | 需 App 前台 | 需网络 | 需同网段 |
/// |---|---|---|---|
/// | HTTP POST（v0.7/0.8）| ⛔ **需要** | ✅ | ✅ |
/// | **写 Documents + AFC 读** | ⛔ **不需要** | ⛔ **不需要** | ⛔ **不需要** |
///
/// **⭐ 关键实测**：`HouseArrestService(bundle_id:..., documents_only=True)`
/// 能直接读扩展/主 App 的 Documents ⇒ **这是最稳的「眼」。**
///
/// ## ⚠️ 扩展与主 App 的 Documents 是**同一个**吗？
/// **是** —— 主 App 和它的 appex **共享同一个容器**（同一个 bundle id 前缀）。
/// ⇒ 扩展写 `Documents/lastframe.jpg` ⇒ 主 App 和 PC(AFC) 都能读到。
///
/// ## 免费账号约束（`_note_1798`）
/// ⛔ 没有 App Group entitlement ⇒ 不能用共享组目录
/// ✅ 但用**自己的 Documents** 就够了（同容器）
class SampleHandler: RPBroadcastSampleHandler {

    private var seq = 0
    private var lastWrite = Date.distantPast
    /// ⭐ 写盘频率（帧/秒）—— 2 fps 够识别用，省电省 IO
    private let fps = 2.0
    /// ⭐ 降采样后的宽度（识别够用，写盘快）
    private let outWidth: CGFloat = 451

    /// 停止标志文件名（主 App 放/删它来控制录屏，照荔枝的做法 `_note_2011` §8）
    private let stopFlag = "stop_broadcast"

    private var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        NSLog("PGShot broadcastStarted dir=%@", dir.path)
        // ⭐ 启动时清掉停止标志（主 App 也会清一次，双保险）
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(stopFlag))
    }

    override func broadcastPaused() { NSLog("PGShot broadcastPaused") }
    override func broadcastResumed() { NSLog("PGShot broadcastResumed") }

    override func broadcastFinished() {
        NSLog("PGShot broadcastFinished")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        // ① 限流
        let now = Date()
        guard now.timeIntervalSince(lastWrite) >= (1.0 / fps) else { return }
        lastWrite = now

        // ② 停止标志（荔枝用文件当控制信号）
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(stopFlag).path) {
            NSLog("PGShot 收到停止标志 ⇒ 结束广播")
            finishBroadcastWithError(nil)
            return
        }

        // ③ 出图
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let img = UIImage(cgImage: cg)

        // ④ 降采样（省 IO，识别够用）
        let scaled = downscale(img, toWidth: outWidth)
        guard let jpg = scaled.jpegData(compressionQuality: 0.7) else { return }

        // ⑤ 写盘（⭐ 原子写：先写 .tmp 再 rename，避免 PC 读到半截）
        seq += 1
        write(jpg, name: "lastframe.jpg")
        // 每 10 帧留一张存档（调试用）
        if seq % 10 == 0 {
            write(jpg, name: "frame_\(seq).jpg")
        }
    }

    // MARK: - 工具

    private func downscale(_ img: UIImage, toWidth w: CGFloat) -> UIImage {
        guard img.size.width > w else { return img }
        let scale = w / img.size.width
        let newSize = CGSize(width: w, height: (img.size.height * scale).rounded())
        let r = UIGraphicsImageRenderer(size: newSize)
        return r.image { _ in img.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private func write(_ data: Data, name: String) {
        let dst = dir.appendingPathComponent(name)
        let tmp = dir.appendingPathComponent(name + ".tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            // 原子替换（PC 端要么看到旧的完整帧，要么看到新的完整帧）
            _ = try? FileManager.default.replaceItemAt(dst, withItemAt: tmp)
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: tmp)
            }
            if !FileManager.default.fileExists(atPath: dst.path) {
                try data.write(to: dst, options: .atomic)
            }
        } catch {
            NSLog("PGShot 写帧失败: %@", String(describing: error))
        }
    }
}
