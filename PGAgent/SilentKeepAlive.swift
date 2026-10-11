import AVFoundation
import Foundation

/// ⭐⭐⭐⭐⭐ 「活」—— **静音音频保活**（比 PiP 简单、可靠得多，§2235）。
///
/// ## 为什么用这招
/// iOS 会在 App 退后台几十秒后**挂起**它。我们的 `Runner`（自主循环）
/// 跑在 App 里 ⇒ 一挂就冻 ⇒ 用户看到的就是「跑一半停了」。
///
/// ### 两条保活路对比（实测）
/// | 路 | 需要什么 | 实测结果 |
/// |---|---|---|
/// | **PiP 画中画** | `AVPictureInPictureController` + 图层真的在渲染 + 音频会话 | ⚠️ `possible` 能到 true，但**起不来**（反复试了 3 个原因）|
/// | **静音音频** ⭐ | `UIBackgroundModes:[audio]` + `.playback` 会话 + **循环播一个静音 buffer** | ✅ **系统认定的标准做法** |
///
/// 📏 依据：`UIBackgroundModes: audio` 的语义就是「App 在后台**放音频**」；
///    只要**真的有音频在播**（哪怕是静音），系统**不会挂起**这个 App。
///    这也是很多「后台常驻」App 的做法。
///
/// ⚠️ 关键点：必须**真的播放**（`AVAudioPlayer.play()` 一个静音文件，
///    或 `AVAudioEngine` 持续输出）—— 只 `setActive(true)` **不算播**，
///    系统照样挂起（这就是之前 PiP 之外的另一个坑）。
///
/// ## 免费 Apple ID 能不能用
/// ✅ 能。`audio` **不需要额外 entitlement**（与 `bluetooth-central` 不同，
///    那个免费账号拿不到，`_note_1798` 踩过）。
public final class SilentKeepAlive {

    public static let shared = SilentKeepAlive()
    private init() {}

    private var player: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?
    private(set) var started = false
    private(set) var lastError = ""
    /// ⭐ §2300 自愈守护（主线程定时器）—— 见 `installWatchdog()`
    private var watchdog: Timer?
    private var resumptions = 0

    /// ⭐⭐⭐⭐⭐ §2300 **为什么必须有它（真机血案）**
    ///
    /// ## 现象
    /// 装完 v0.10.43 后真机实测：
    /// ```
    ///   keepalive: started=True  playing=False     ← ⛔ 声音已经不在播了，可 started 还是 True
    ///   → App 在后台被系统挂起 ⇒ HTTP 8899 断 ⇒ switchToApp 后的 grab() 拿不到帧
    ///   → 表现：「回了桌面并且点开了快手，但后面一步都走不动」
    /// ```
    /// 根因：`AVAudioPlayer` 会被 **中断**（interruption）而暂停，而社区版
    /// 声音一旦不播，`UIBackgroundModes:[audio]` 就**不再保护**这个 App。
    /// ⛔ 而 `started` 只是我自己记的一个 Bool → 它**不会自己变回 false**
    /// ⇒ 所以只看 `started` 会得到**假阳性**（“保活已开”）。
    ///
    /// ## 修法（两道）
    /// ① 监听 `AVAudioSession.interruptionNotification` ⇒ `.ended` 时**立即重播**；
    /// ② **定时自检**（每 5s）：`player` 存在但 `!isPlaying` ⇒ 重播（兜住任何其他原因）。
    private func installWatchdog() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main) { [weak self] note in
                guard let self = self else { return }
                let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
                let t = AVAudioSession.InterruptionType(rawValue: raw)
                NSLog("PGAgent KeepAlive: 收到中断通知 type=%@", "\(raw)")
                if t == .ended { self.resume() }
            }

        // ⛔ 必须在**主线程**建 Timer（同 `BroadcastStarter.startWatching` 的血案：
        //    后台队列的 RunLoop 从不 run ⇒ timer 永远不触发）。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.watchdog?.invalidate()
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                guard let self = self, self.started else { return }
                if let p = self.player, !p.isPlaying { self.resume() }
            }
        }
    }

    /// 重播静音（幂等：已在播就什么都不做）
    private func resume() {
        guard let p = player, !p.isPlaying else { return }
        // ⛔ 重播前**重新声明 `.mixWithOthers`**：中断（如接电话/别的 App 抢会话）
        //    后系统可能把类别恢复成默认值 ⇒ 不重声明就又会被中断。
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default,
                                                            options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
        let ok = p.play()
        resumptions += 1
        NSLog("PGAgent KeepAlive: 自愈重播 ok=%@ 第%d次", ok ? "是" : "否", resumptions)
    }

    /// 生成一段**静音** WAV（44.1kHz 单声道，1 秒）
    ///
    /// 为什么自己造：⛔ 不想往包里塞音频资源文件（构建/签名更麻烦）；
    /// ✅ 直接在内存里造一个合法 WAV 交给 `AVAudioPlayer` 循环播。
    private func makeSilentWAV(seconds: Double = 1.0,
                              sampleRate: Double = 44100) -> Data? {
        let frames = Int(seconds * sampleRate)
        let dataBytes = frames * 2                 // 16-bit mono
        var d = Data()

        func le32(_ v: UInt32) { var x = v.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var x = v.littleEndian
            withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        le32(16)                                   // fmt chunk size
        le16(1)                                    // PCM
        le16(1)                                    // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate) * 2)               // byte rate
        le16(2)                                    // block align
        le16(16)                                   // bits
        d.append(contentsOf: Array("data".utf8))
        le32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))           // ⭐ 全 0 = 静音
        return d
    }

    /// ⭐ 开始保活。返回是否成功。
    @discardableResult
    func start() -> Bool {
        if started { return true }
        lastError = ""

        // ① 音频会话：`.playback`（后台可播）+ 激活
        //    ⛔ 不要 `.mixWithOthers`（会让系统认为我们不是主会话）
        // ⭐⭐⭐⭐⭐ §2302 **必须 `.mixWithOthers`（真机血案推出来的）**
        //
        // ## 现象
        // 以前用**独占** `.playback`（options: []）：只要前台换成**有声 App**（快手/快手极速版都在放视频），
        // iOS 会把我们的静音播放**中断掉** ⇒ 扫地程序一旦不再播音频，
        // `UIBackgroundModes:[audio]` 就**不再保护**这个 App ⇒ iOS 挂起它。
        // 真机铁证：点开快手后 **5 分钟一步都走不动**（HTTP 8899 断，只能靠把 App 拉回前台才恢复）。
        //
        // ⛔ 上一版的推理是错的（原注释：“不要 .mixWithOthers，会让系统认为我们不是主会话”）——
        //   “主会话”这个概念对我们**无用**：我们要的只是“**一直有音频在播**”而已。
        //
        // ## 为什么 `.mixWithOthers` 就对
        // 它告诉系统：**我不抢声音，可以和别人一起放** ⇒ 快手放它的，我放我的静音，
        // **不会互相中断** ⇒ 我们的“有音频在播”这个事实一直成立 ⇒ 后台保护持续生效。
        // 📏 这也是很多“后台常驻 + 不干扰音乐”类 App 的标准做法。
        let sess = AVAudioSession.sharedInstance()
        do {
            try sess.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try sess.setActive(true)
        } catch {
            lastError = "音频会话失败: \(error)"
            NSLog("PGAgent KeepAlive: %@", lastError)
            return false
        }

        // ② 造静音 WAV 并**循环播**
        guard let wav = makeSilentWAV() else {
            lastError = "静音 WAV 生成失败"
            return false
        }
        do {
            let p = try AVAudioPlayer(data: wav)
            p.numberOfLoops = -1          // ⭐ 无限循环
            p.volume = 0.0                // ⭐ 真的没声音
            p.prepareToPlay()
            guard p.play() else {
                lastError = "AVAudioPlayer.play() 返回 false"
                NSLog("PGAgent KeepAlive: %@", lastError)
                return false
            }
            player = p
        } catch {
            lastError = "AVAudioPlayer 失败: \(error)"
            NSLog("PGAgent KeepAlive: %@", lastError)
            return false
        }

        started = true
        installWatchdog()          // ⭐ §2300 装上自愈守护
        NSLog("PGAgent KeepAlive: ✅ 静音音频保活已启动（循环播放）")
        return true
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        player?.stop()
        player = nil
        engine?.stop()
        engine = nil
        node = nil
        started = false
        NSLog("PGAgent KeepAlive: 已停止")
    }

    func snapshot() -> [String: Any] {
        [
            "started": started,
            "playing": player?.isPlaying ?? false,
            "volume": player?.volume ?? -1,
            "loops": player?.numberOfLoops ?? 0,
            // ⭐ §2300 出诊断：自愈重播次数（⛔ 不是 0 就说明真的中断过）
            "resumptions": resumptions,
            "error": lastError,
            "audioCategory": AVAudioSession.sharedInstance().category.rawValue,
            "audioActive": AVAudioSession.sharedInstance().isOtherAudioPlaying == false,
        ]
    }
}
