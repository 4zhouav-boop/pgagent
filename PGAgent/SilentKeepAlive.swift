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
        let sess = AVAudioSession.sharedInstance()
        do {
            try sess.setCategory(.playback, mode: .default, options: [])
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
        NSLog("PGAgent KeepAlive: ✅ 静音音频保活已启动（循环播放）")
        return true
    }

    func stop() {
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
            "error": lastError,
            "audioCategory": AVAudioSession.sharedInstance().category.rawValue,
            "audioActive": AVAudioSession.sharedInstance().isOtherAudioPlaying == false,
        ]
    }
}
