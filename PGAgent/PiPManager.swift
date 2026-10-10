import AVFoundation
import AVKit
import Foundation
import UIKit

/// ⭐⭐⭐⭐ 「活」—— **画中画（PiP）保活**（照 **荔枝RPA** 的做法，`_note_2011` §7）。
///
/// ## 为什么需要
/// iOS 会把退到后台的 App **挂起**（我们的 Runner 一挂就被冻）。
/// 荔枝的解法（日志实证）：
/// ```
/// "画中画管理器初始化完成"                      // ViewController.swift:99
/// "画中画未启动，日志: 点击 317,614"             // hzh.swift:160  ← 把动作显示在 PiP 里
/// "画中画未启动，日志: _启动中 10s 剩余8秒"
/// ```
/// **⇒ 它用一个**画中画小窗**同时做两件事：**
///   ① **保活**（PiP 播放期间 App 不会被挂起）
///   ② **可视化**（把当前动作/进度显示在小窗里，用户能看到）
///
/// ## 实现
/// 用 `AVPictureInPictureController` + 一个**自绘视频源**：
/// ```
/// AVSampleBufferDisplayLayer  ⇐  每秒画一张「状态图」（文字渲染）
///        ↓
/// AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer:...))
/// ```
/// ⛔ 不需要额外 entitlement（前台启动一次后即可后台续命）。
///
/// ## 备注
/// · `AVPictureInPictureController.isPictureInPictureSupported()` 要先检查
/// · 后台音频模式（`UIBackgroundModes: audio`）会显著提高 PiP 存活率，
///   但**免费 Apple ID 拿不到** `audio` 相关的后台声明 ⇒ 先只用 PiP。
final class PiPManager: NSObject, ObservableObject {

    @Published private(set) var active = false
    @Published private(set) var lastError = ""
    /// 当前要显示的文字（Runner 每秒更新）
    @Published var text = "PGAgent"

    private var layer: AVSampleBufferDisplayLayer?
    private var pip: AVPictureInPictureController?
    private var timer: Timer?
    private var hostView: UIView?
    /// ⭐ 图层的时间基准（PiP 要求图层「在播」才会变 possible）
    private var timebase: CMTimebase?

    /// 画面尺寸（小一点省资源）
    private let W = 320, H = 180

    static func supported() -> Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// ⭐ 启动 PiP：建一个隐藏的 host view + display layer，然后起 PiP
    ///
    /// ⛔⛔ **本方法会碰 UIKit（UIView / CALayer / UIWindow）⇒ 必须跑在主线程。**
    /// 但它被 HTTP handler 调用（handler 在 `global(qos:.userInitiated)`），
    /// ⇒ 所以这里**统一走 `MainThread.run`** 切回主线程，
    ///   否则会复现 §2212 的 `_dispatch_assert_queue_fail` 崩溃。
    @discardableResult
    func start() -> Bool {
        if Thread.isMainThread { return startOnMain() }
        let r = MainThread.run { self.startOnMain() }
        guard r != nil else {
            // ⛔ `lastError` 是 @Published ⇒ 只能在主线程改
            DispatchQueue.main.async { self.lastError = "等主线程超时（PiP 启动失败）" }
            return false
        }
        return r ?? false
    }

    /// ⭐ **只在主线程**执行的 PiP 启动（由 `start()` 负责线程切换）
    private func startOnMain() -> Bool {
        guard Self.supported() else {
            lastError = "本机不支持画中画"
            return false
        }
        if active { return true }

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let win = scene.windows.first else {
            lastError = "拿不到 window"
            return false
        }

        // ⓪ ⭐⭐⭐ **必须配 AVAudioSession**（§2230 实测踩坑）
        //
        // 之前 `isPictureInPicturePossible` 一直是 **false** ⇒ PiP 起不来 ⇒
        // App 一切后台就被挂起 ⇒ `/run` 闭环走不完。
        //
        // 📏 根因：`AVPictureInPictureController` 用
        //    `AVSampleBufferDisplayLayer` 当内容源时，**系统仍要求 App 有一个
        //    可播放的音频会话**（PiP 的语义是「视频播放」）。
        //    ⛔ 不设 ⇒ `isPictureInPicturePossible=false`，且**永远不会变 true**。
        // ✅ 设为 `.playback`（+ `setActive(true)`）即可。
        //    ⚠️ 想让它**在后台**也活着，还需要 Info.plist 里
        //       `UIBackgroundModes: [audio]`（见 project.yml）。
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .moviePlayback,
                              options: [.mixWithOthers])
            try s.setActive(true)
            NSLog("PGAgent PiP: AVAudioSession .playback 已激活")
        } catch {
            NSLog("PGAgent PiP: AVAudioSession 设置失败 %@", String(describing: error))
        }

        // ① 隐藏宿主视图（⛔ 别影响 UI）
        let host = UIView(frame: CGRect(x: -W - 10, y: -H - 10, width: W, height: H))
        host.isUserInteractionEnabled = false
        host.backgroundColor = .black
        win.addSubview(host)
        hostView = host

        // ② 显示层
        let l = AVSampleBufferDisplayLayer()
        l.frame = host.bounds
        l.videoGravity = .resizeAspect
        // ⭐ 给图层一个**时间基准**：没有它图层不会进入 `.rendering`，
        //    PiP 也就永远「不可用」（§2230）
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &tb)
        if let tb = tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1.0)
            l.controlTimebase = tb
            timebase = tb
        }
        host.layer.addSublayer(l)
        layer = l

        // ③ PiP 控制器
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            lastError = "PiP 不支持"
            return false
        }
        let src = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: l,
            playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: src)
        c.delegate = self
        pip = c

        // ④ 先画一帧（⛔ 没内容 PiP 起不来）
        render()

        // ⑤ 起 PiP
        //
        // ⚠️ `isPictureInPicturePossible` **不是立刻**为 true
        //    （图层要先进入能播的状态）⇒ 轮询等它，最多 ~3 秒。
        //    ⛔ 之前只等 0.3 秒就判死 ⇒ 几乎必然拿到 false（§2230 实测）。
        attemptStart(c, tries: 0)

        // ⑥ 每秒重画（= 持续有帧 ⇒ App 不被挂起）
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.render()
        }
        return true
    }

    /// ⭐ 轮询等待 `isPictureInPicturePossible` 再启动（最多 ~3 秒）
    ///
    /// 为什么必须轮询：这个属性依赖图层/音频会话进入可播状态，
    /// 刚建好时**必然**是 false（§2230 实测：等 0.3s 拿到 false，
    /// 而框架自己会在准备好后回调 delegate）。
    private func attemptStart(_ c: AVPictureInPictureController, tries: Int) {
        if c.isPictureInPictureActive { return }
        if c.isPictureInPicturePossible {
            c.startPictureInPicture()
            NSLog("PGAgent PiP: startPictureInPicture() 已调用（第 %d 次探测）", tries + 1)
            return
        }
        guard tries < 15 else {
            lastError = "PiP 当前不可用（isPictureInPicturePossible=false，等 3s）"
            NSLog("PGAgent PiP: %@", lastError)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.attemptStart(c, tries: tries + 1)
        }
    }

    func stop() {
        // ⛔ 同样碰 UIKit（removeFromSuperlayer / removeFromSuperview）⇒ 必须主线程
        if !Thread.isMainThread {
            MainThread.run { self.stopOnMain() }
            return
        }
        stopOnMain()
    }

    private func stopOnMain() {
        timer?.invalidate(); timer = nil
        if let c = pip, c.isPictureInPictureActive {
            c.stopPictureInPicture()
        }
        pip = nil
        timebase = nil
        layer?.removeFromSuperlayer()
        layer = nil
        hostView?.removeFromSuperview()
        hostView = nil
        DispatchQueue.main.async { self.active = false }
    }

    func snapshot() -> [String: Any] {
        [
            "supported": Self.supported(),
            "active": active,
            "text": text,
            "error": lastError,
        ]
    }

    // MARK: - 画一帧状态图

    private func render() {
        guard let l = layer else { return }
        let img = drawText(text)
        guard let buf = sampleBuffer(from: img) else { return }
        if l.status == .failed { l.flush() }
        l.enqueue(buf)
    }

    /// 把文字画成 UIImage（黑底白字，居中，自动缩小）
    private func drawText(_ s: String) -> UIImage {
        let size = CGSize(width: W, height: H)
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: para,
            ]
            let rect = CGRect(x: 8, y: 0, width: size.width - 16, height: size.height)
            (s as NSString).draw(in: rect, withAttributes: attrs)
        }
    }

    /// UIImage → CMSampleBuffer（PiP 要的格式）
    ///
    /// ⚠️ `CMVideoFormatDescriptionCreateForImageBuffer` **只接受 `CVImageBuffer`**
    ///    （⛔ 不是 `CGImage`）⇒ 必须先把 CGImage 画进 `CVPixelBuffer`。
    private func sampleBuffer(from img: UIImage) -> CMSampleBuffer? {
        guard let cg = img.cgImage else { return nil }

        // ① 建 CVPixelBuffer
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, W, H,
                                     kCVPixelFormatType_32BGRA,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let pixelBuffer = pb else { return nil }

        // ② 把 CGImage 画进去
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: base,
                                  width: W, height: H,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

        // ③ 格式描述
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &fmt)
        guard let f = fmt else { return nil }

        // ④ SampleBuffer
        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 1),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescription: f,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sb)
        return sb
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = true }
        NSLog("PGAgent PiP: 已启动")
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = false }
        NSLog("PGAgent PiP: 已停止")
    }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError e: Error) {
        DispatchQueue.main.async { self.active = false; self.lastError = "\(e)" }
        NSLog("PGAgent PiP 启动失败: %@", String(describing: e))
    }
}

extension PiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(
        _ c: AVPictureInPictureController) -> CMTimeRange {
        // 无限时长 ⇒ PiP 不会自己结束
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(
        _ c: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
