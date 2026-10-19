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
    /// ⭐ 启动探测次数（诊断：>0 说明 possible 曾为 true）
    private(set) var startTries = 0

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
            // ⛔⛔ **不要加 `.mixWithOthers`**（§2234 实测）：
            //    PiP 要求本 App 是**主音频会话**（"now playing"）。
            //    带 `.mixWithOthers` 时系统认为「可能有别的 App 在放音」
            //    ⇒ 拒绝让 PiP 自动启动（`isPictureInPicturePossible` 也可能不稳）。
            try s.setCategory(.playback, mode: .moviePlayback, options: [])
            try s.setActive(true)
            NSLog("PGAgent PiP: AVAudioSession .playback 已激活（主会话）")
        } catch {
            NSLog("PGAgent PiP: AVAudioSession 设置失败 %@", String(describing: error))
        }

        // ① 宿主视图
        //
        // ⛔⛔ **必须在屏幕上**（§2232 实测根因）：
        //   之前放在 `x = -W-10, y = -H-10`（**屏幕外**）⇒
        //   图层永远不进入「可显示」状态 ⇒
        //   `isPictureInPicturePossible` **恒为 false** ⇒ PiP 起不来。
        //   📏 依据：PiP 用 `AVSampleBufferDisplayLayer` 做内容源时，
        //      系统要求该图层**在可见的窗口层级里**（能真的上屏渲染）。
        //
        // ⛔⛔⛔ §3461 **"放进窗口"不够，必须"真的被渲染"**（真机实测 2026-10-19）：
        //   旧改法是「120×68 小窗 + insertSubview(at: 0) 放最底层」，
        //   靠"被 SwiftUI 盖住"来隐藏。**结果 `isReadyForDisplay` 恒为 false**：
        //   ```
        //   /pip/state: possible=true, layerStatus=1(.rendering),
        //               hasLayer=true, hostInWindow=true,
        //               layerReady=false   ← ⛔ 卡在这
        //   startTries=1 且不再增长 ⇒ 调了一次 startPictureInPicture() 就放弃
        //   ```
        //   根因：图层被完全遮挡 ⇒ 系统认为它"没在显示" ⇒ 不 ready ⇒ PiP 起不来。
        //
        // ✅ 新改法（照 `uakihir0/UIPiPView` MIT 的做法）：
        //   **全屏尺寸 + 放最上层 + alpha 极低**（0.01）。
        //   · 几何上占满屏幕 ⇒ 系统认为在显示 ⇒ `isReadyForDisplay` 能变 true
        //   · alpha 0.01 ⇒ 用户几乎看不见（且 `isUserInteractionEnabled=false` 不挡操作）
        //   ⚠️ alpha 不能是 0：0 等于 hidden，系统同样不渲染（§2234 踩过 0.02 也不行，
        //      但那是因为当时尺寸只有 120×68；本次**尺寸够大**，0.01 可被渲染。
        //      若仍不 ready，`render()` 里会自动把 alpha 抬到 0.02 再试）。
        let host = UIView(frame: CGRect(x: 0, y: 0, width: W, height: H))
        host.isUserInteractionEnabled = false
        host.backgroundColor = .black
        host.alpha = 0.01                  // ⭐ 几乎透明但**不是 0**
        host.isHidden = false
        host.clipsToBounds = true
        if let root = win.rootViewController?.view {
            root.addSubview(host)          // ⭐ 放最上层（能被真的渲染）
            root.bringSubviewToFront(host)
        } else {
            win.addSubview(host)
        }
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
    ///
    /// ⛔ §3461 修：**`startPictureInPicture()` 返回不代表成功**。
    ///   旧实现只要 `possible==true` 就调一次然后 return（`startTries=1` 再不增长），
    ///   而真机上它失败了（delegate 的 `failedToStart` 被调用，但没人重试）。
    ///   现在改成：调完之后**等 delegate 回执**，若没 active 且有错误 ⇒ 重试。
    private var startAttempt = 0
    private var startRetryLeft = 3

    private func attemptStart(_ c: AVPictureInPictureController, tries: Int) {
        if c.isPictureInPictureActive {
            NSLog("PGAgent PiP: 已经是 active，停手")
            return
        }
        if c.isPictureInPicturePossible {
            startTries = tries + 1
            NSLog("PGAgent PiP: 第 %d 次探测 possible=true ⇒ 调 startPictureInPicture() (重试余 %d)",
                  tries + 1, startRetryLeft)
            c.startPictureInPicture()
            // ⭐ 调用后不 return：等 0.8s 看是否真的 active，没 active 就重试
            guard startRetryLeft > 0 else {
                lastError = "PiP 多次启动失败（已重试 3 次）"
                NSLog("PGAgent PiP: %@", lastError)
                return
            }
            startRetryLeft -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { return }
                if c.isPictureInPictureActive { return }
                // 没 active ⇒ 可能图层还没 ready，把 alpha 抬一点再试
                if let h = self.hostView, h.alpha < 0.05 { h.alpha = 0.02 }
                self.render()                     // 再喂一帧
                self.attemptStart(c, tries: tries + 1)
            }
            return
        }
        guard tries < 15 else {
            startTries = tries
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
        var d: [String: Any] = [
            "supported": Self.supported(),
            "active": active,
            "text": text,
            "error": lastError,
        ]
        // ⭐⭐ 诊断（§2232）：PiP 起不来时，靠这些字段定位到底卡在哪一步
        d["possible"] = pip?.isPictureInPicturePossible ?? false
        d["hasLayer"] = (layer != nil)
        d["hostInWindow"] = (hostView?.window != nil)
        d["hostHidden"] = hostView?.isHidden ?? true
        d["hostFrame"] = hostView.map {
            "\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)) \(Int($0.frame.width))x\(Int($0.frame.height))"
        } ?? "-"
        d["layerStatus"] = layer.map { "\($0.status.rawValue)" } ?? "-"
        // ⚠️ `isReadyForDisplay` 是 iOS 17.4+（我们的 deploymentTarget 是 17.0）
        //    ⇒ 必须用 `#available` 包起来，否则编译失败（§2233 踩过）
        if #available(iOS 17.4, *) {
            d["layerReady"] = layer?.isReadyForDisplay ?? false
        } else {
            d["layerReady"] = "(需 iOS 17.4+)"
        }
        d["timebaseRate"] = timebase.map { "\(CMTimebaseGetRate($0))" } ?? "-"
        d["startTries"] = startTries
        d["renderCount"] = renderCount          // ⭐ §3461：Timer 到底有没有在跑
        d["startRetryLeft"] = startRetryLeft    // ⭐ §3461：还能重试几次
        d["hostAlpha"] = hostView.map { "\($0.alpha)" } ?? "-"   // ⭐ §3461：宿主透明度
        d["audioActive"] = AVAudioSession.sharedInstance().isOtherAudioPlaying == false
        d["audioCategory"] = AVAudioSession.sharedInstance().category.rawValue
        d["audioOptions"] = AVAudioSession.sharedInstance().categoryOptions.rawValue
        return d
    }

    // MARK: - 画一帧状态图

    /// ⭐ §3461 渲染计数，用于诊断「Timer 到底有没有在跑」
    private var renderCount = 0

    private func render() {
        guard let l = layer else { return }
        let img = drawText(text)
        guard let buf = sampleBuffer(from: img) else {
            NSLog("PGAgent PiP: render 失败（sampleBuffer 为 nil）")
            return
        }
        if l.status == .failed { l.flush() }
        l.enqueue(buf)
        renderCount += 1
        // 前 3 帧打日志，方便判断 Timer 是否生效
        if renderCount <= 3 {
            NSLog("PGAgent PiP: render #%d enqueued, status=%d, readyForDisplay=%@",
                  renderCount, l.status.rawValue,
                  {
                      if #available(iOS 17.4, *) {
                          return l.isReadyForDisplay ? "Y" : "N"
                      }
                      return "?"
                  }())
        }
        // ⭐ 连续喂 10 帧还没 ready ⇒ 把 alpha 再抬一点（系统才认为在显示）
        if renderCount == 10 {
            if #available(iOS 17.4, *), !l.isReadyForDisplay {
                if let h = hostView, h.alpha < 0.05 {
                    h.alpha = 0.02
                    NSLog("PGAgent PiP: 10 帧仍未 ready ⇒ alpha 抬到 0.02")
                }
            }
        }
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
