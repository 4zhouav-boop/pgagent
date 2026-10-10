import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ 「大脑」—— **自主循环**（App 自己在手机上跑，⛔ 不需要 PC）。
///
/// ## 架构来源
/// 结合了 **荔枝RPA** 的实测优点（`_note_2010` / `_note_2011`）与我们的既有优势。
///
/// ### 从荔枝学的（日志实证）
/// | # | 项 | 荔枝实测 | 本实现 |
/// |---|---|---|---|
/// | 1 | **广告停留** | `settingsAdTimeMin/Max = 40/60` 秒 | `ad_stay_min/max` |
/// | 2 | **OCR 超时** | 10.1 秒 / 99 次尝试 | `ocr_timeout_s` / `ocr_max_tries` |
/// | 3 | **杂七杂八处理** | 专门一轮清理弹窗 | `cleanupPass()` |
/// | 4 | **滑动快慢** | `hs=100` 快甩 / `hs=2000` 慢拖 | `SwipeSpeed` |
/// | 5 | **避让区滑动** | y 766~1789（避开顶/底栏）| `swipe_y_top/bot_pct` |
/// | 6 | **转化关键词** | `领取福利-立即下载-…` | `conversion_keyword` |
/// | 7 | **关键词同义词组** | 每组 5~10 个 | 配置里扩充 |
/// | 8 | **画中画保活** | PiP + `showPiPLog` | `PiPManager` |
///
/// ### 我们保留的优势
/// · **HID 绝对坐标 0..32767**（设备无关，⛔ 不用按分辨率换算）—— `_note_2012`
/// · **配置驱动**（改逻辑只推 JSON，⛔ 不重装）
/// · **⛔ 不盲点**（坐标来自识别结果）
///
/// ## 铁律
/// · ⛔ **先找到再点**
/// · ⛔ **广告页放行**（用户令：「都是跑循环广告」）⇒ **待够时间**，⛔ 不点 ✕
/// · ⛔ **认不出就停**（不猜、不硬闯）
final class Runner: ObservableObject {

    // MARK: - 状态（HTTP 可查）

    @Published private(set) var running = false
    @Published private(set) var step = 0
    @Published private(set) var lastPage = "-"
    @Published private(set) var lastAction = "-"
    @Published private(set) var lastError = ""
    @Published private(set) var stopReason = "-"
    @Published private(set) var trace: [String] = []
    /// ⭐ 广告停留进度（0..1）—— 给 PiP 显示用
    @Published private(set) var adProgress: Double = 0

    private let cfgStore: ConfigStore
    private let grabber: ScreenGrabber
    private let ble: BLEController
    private let log: (String) -> Void
    /// ⭐ v0.9.0：优先从录屏帧取画面（⛔ 不用快捷指令、⛔ 不用前台）
    private weak var broadcaster: BroadcastStarter?

    private let q = DispatchQueue(label: "pgagent.runner", qos: .userInitiated)
    private var cancelFlag = false

    init(cfgStore: ConfigStore, grabber: ScreenGrabber, ble: BLEController,
         broadcaster: BroadcastStarter? = nil,
         log: @escaping (String) -> Void) {
        self.cfgStore = cfgStore
        self.grabber = grabber
        self.ble = ble
        self.broadcaster = broadcaster
        self.log = log
    }

    // MARK: - 参数（全部来自配置，带荔枝实测默认值）

    private var maxSteps: Int { cfgStore.cfg?.settings?.loop_max_steps ?? 40 }
    private var stepWait: Double { cfgStore.cfg?.settings?.loop_step_wait ?? 1.5 }
    private var grabTimeout: Double { cfgStore.cfg?.settings?.loop_grab_timeout ?? 10.0 }
    private var stallLimit: Int { cfgStore.cfg?.settings?.loop_stall_limit ?? 3 }
    /// ⭐ 广告停留（荔枝 40/60 秒）
    private var adStayMin: Double { cfgStore.cfg?.settings?.ad_stay_min ?? 40 }
    private var adStayMax: Double { cfgStore.cfg?.settings?.ad_stay_max ?? 60 }
    /// ⭐ OCR 超时（荔枝 10.1s / 99 次）
    private var ocrTimeout: Double { cfgStore.cfg?.settings?.ocr_timeout_s ?? 10.0 }
    private var ocrMaxTries: Int { cfgStore.cfg?.settings?.ocr_max_tries ?? 99 }
    /// ⭐ 滑动参数
    private var swipeTopPct: Double { cfgStore.cfg?.settings?.swipe_y_top_pct ?? 0.30 }
    private var swipeBotPct: Double { cfgStore.cfg?.settings?.swipe_y_bot_pct ?? 0.70 }
    private var swipeSpeed: BLEController.SwipeSpeed {
        switch cfgStore.cfg?.settings?.swipe_video_speed ?? "fast" {
        case "slow": return .slow
        case "mid":  return .mid
        default:     return .fast
        }
    }
    /// ⭐ 转化关键词（荔枝 `领取福利-立即下载-…`）
    private var conversionKeywords: [String] {
        cfgStore.cfg?.settings?.conversionKeywords ?? []
    }

    private func v(_ a: Double, _ b: Double) -> Double { cfgStore.cfg?.settings?.base_w ?? 451 }
    private var baseW: Double { cfgStore.cfg?.settings?.base_w ?? 451 }
    private var baseH: Double { cfgStore.cfg?.settings?.base_h ?? 977 }
    private var yFix: Double { cfgStore.cfg?.settings?.y_fix ?? 4 }

    // MARK: - 控制

    func start(dest: String?) {
        // ⛔⛔ 本方法会被 HTTP handler（后台队列）和 UI 按钮（主线程）**两条路**调用。
        // 所有 `@Published` 字段**只能在主线程改**（§2212：后台改 @Published
        // ⇒ SwiftUI 在后台线程收到通知 ⇒ 崩 / 或被看门狗判死锁）。
        // ⚠️ 已在主线程时必须**直接执行**（⛔ 不能 async 后干等 ⇒ 自死锁）。
        if Thread.isMainThread {
            startOnMain(dest: dest)
        } else {
            DispatchQueue.main.async { self.startOnMain(dest: dest) }
        }
    }

    private func startOnMain(dest: String?) {
        guard !running else { log("§run ⚠️ 已在跑，忽略"); return }
        cancelFlag = false
        running = true
        step = 0
        trace.removeAll()
        lastError = ""
        stopReason = "-"
        adProgress = 0
        q.async { [weak self] in self?.loop(dest: dest) }
    }

    func stop() {
        // `cancelFlag` 是普通 Bool（非 @Published）⇒ 任意线程可写，循环里每步都会读
        cancelFlag = true
        log("§run ⛔ 收到停止请求")
    }

    func snapshot() -> [String: Any] {
        [
            "running": running,
            "step": step,
            "page": lastPage,
            "action": lastAction,
            "stopReason": stopReason,
            "error": lastError,
            "adProgress": adProgress,
            "trace": Array(trace.suffix(40)),
        ]
    }

    /// 给 PiP 显示的一行状态
    func pipLine() -> String {
        if !running { return "停 \(stopReason)" }
        if adProgress > 0 {
            return "广告 \(Int(adProgress * 100))%  \(lastPage)"
        }
        return "步\(step) \(lastPage) \(lastAction)"
    }

    // MARK: - 主循环

    private func loop(dest: String?) {
        defer {
            DispatchQueue.main.async { self.running = false }
            log("§run === 结束：\(stopReason) ===")
        }

        guard let cfg = cfgStore.cfg else { finish("配置未加载"); return }

        let rec = Recognizer(templatesDir: ConfigStore.templatesDir())
        let nav = Navigator(cfg: cfg, rec: rec, ble: ble) { [weak self] s in
            self?.append(s)
        }

        let target = dest ?? cfg.settings?.target ?? "center"
        log("§run ▶️ 开始 目标=\(target) 最大步数=\(maxSteps) 广告停留=\(Int(adStayMin))~\(Int(adStayMax))s")

        var stall = 0
        var lastSig = ""

        for k in 0..<maxSteps {
            if cancelFlag { finish("用户停止"); return }
            DispatchQueue.main.async { self.step = k + 1 }

            // ① 抓帧
            guard let img = grabSync() else {
                finish("抓帧失败：\(grabber.lastError)")
                return
            }

            // ② 判页
            let page = nav.pageHere(img) ?? "unknown"
            DispatchQueue.main.async { self.lastPage = page }

            // ③ 到目的地了吗？
            if page == target {
                finish("✅ 已到达 \(target)（第 \(k + 1) 步）")
                return
            }

            // ④ ⛔⛔ 广告页：**待够时间**，⛔ 不点 ✕（用户令 + 荔枝 40/60 秒）
            if page == "ad_video" {
                log("§run ⛔ 广告页 ⇒ 放行（待够 \(Int(adStayMin))~\(Int(adStayMax))s，⛔ 不点 ✕）")
                DispatchQueue.main.async { self.lastAction = "ad-stay" }
                adStayLoop()
                continue
            }

            // ⑤ 卡死检测
            let sig = signature(img)
            if sig == lastSig {
                stall += 1
                if stall >= stallLimit {
                    finish("⛔ 画面 \(stallLimit) 次未变（卡死）⇒ 停手")
                    return
                }
            } else {
                stall = 0
                lastSig = sig
            }

            // ⑥ ⭐ 杂七杂八处理（荔枝的「杂七杂八处理」）—— 弹窗优先
            if nav.runFunnel(img) {
                DispatchQueue.main.async { self.lastAction = "funnel" }
                sleep(stepWait)
                continue
            }

            // ⑦ ⭐ 转化关键词检查（荔枝的 `settingsConversionKeyword`）
            if !conversionKeywords.isEmpty {
                let hits = rec.findWords(img, words: conversionKeywords, roi: nil,
                                         minHits: 1, minConfidence: 0.5)
                if hits != nil {
                    log("§run ⭐ 命中转化关键词 ⇒ 按 \(cfgStore.cfg?.settings?.conversion_swipe ?? 3) 次滑动")
                    DispatchQueue.main.async { self.lastAction = "convert" }
                    conversionSwipe()
                    continue
                }
            }

            // ⑧ 页面图上前进一跳
            if let p = cfg.pages[page], let go = p.go, go != "stop" {
                if nav.tap(go, img: img) {
                    DispatchQueue.main.async { self.lastAction = "tap:\(go)" }
                    sleep(stepWait)
                    continue
                }
                log("§run ⚠️ 在 \(page) 想点 \(go) 但没找到")
            }

            // ⑨ ⛔ 认不出出路 ⇒ 停手（⛔ 不盲点）
            finish("⛔ 在 \(page) 认不出出路 ⇒ 停手")
            return
        }

        finish("达到最大步数 \(maxSteps)")
    }

    // MARK: - ⭐ 广告停留（荔枝 settingsAdTimeMin/Max）

    /// 广告页**待够**时间，⛔ 不点 ✕。
    /// 荔枝实测 `settingsAdTimeMin/Max = 40/60` ⇒ 至少 40 秒，最多 60 秒。
    private func adStayLoop() {
        let stay = Double.random(in: adStayMin...max(adStayMin, adStayMax))
        var left = stay
        while left > 0 && !cancelFlag {
            let d = min(0.5, left)
            Thread.sleep(forTimeInterval: d)
            left -= d
            let prog = 1.0 - (left / stay)
            DispatchQueue.main.async { self.adProgress = prog }
        }
        DispatchQueue.main.async { self.adProgress = 0 }
        log("§run ✅ 广告停留完成（\(Int(stay))s）")
    }

    // MARK: - ⭐ 转化滑动（荔枝 settingsConversionSwipe = 3）

    private func conversionSwipe() {
        let n = cfgStore.cfg?.settings?.conversion_swipe ?? 3
        for i in 0..<n {
            if cancelFlag { return }
            let midX = baseW / 2.0
            let yBot = baseH * swipeBotPct
            let yTop = baseH * swipeTopPct
            let cmd = BLEController.swipe(x1: midX, y1: yBot, x2: midX, y2: yTop,
                                          speed: swipeSpeed,
                                          baseW: baseW, baseH: baseH, yFix: yFix)
            _ = ble.send(cmd)
            log("   §convert 滑动 \(i + 1)/\(n)  \(cmd)")
            sleep(1.2)
        }
    }

    // MARK: - 工具

    /// 同步抓一帧（循环在自己的队列上，可以阻塞）
    ///
    /// ⭐ v0.9.0 取帧优先级：
    ///   ① **录屏帧**（`BroadcastStarter.lastFrame`）—— ⛔ 不用快捷指令、⛔ 不用前台
    ///   ② 快捷指令截图（兜底）
    ///
    /// ⭐ 也带**超时重试**（荔枝实测：10.1 秒 / 99 次尝试）
    private func grabSync() -> UIImage? {
        // ① 录屏帧（首选）
        if let b = broadcaster {
            for _ in 0..<max(1, ocrMaxTries / 10) {
                if cancelFlag { return nil }
                if let d = b.lastFrame, let im = UIImage(data: d) {
                    return im
                }
                // 没帧就去读一次文件（扩展是异步写的）
                b.pollFrame()
                if let d = b.lastFrame, let im = UIImage(data: d) {
                    return im
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            log("   §grab 录屏帧没等到，退回快捷指令")
        }

        // ② 快捷指令截图（兜底）
        for attempt in 0..<max(1, ocrMaxTries / 10) {
            if cancelFlag { return nil }
            let sem = DispatchSemaphore(value: 0)
            var url: URL?
            grabber.grab(timeout: grabTimeout) { u, _ in
                url = u
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + grabTimeout + 4)
            if let u = url, let im = UIImage(contentsOfFile: u.path) {
                return im
            }
            if attempt > 0 {
                log("   §grab 第 \(attempt + 1) 次未拿到帧，重试…")
            }
        }
        return nil
    }

    /// 画面签名：用极小的灰度缩略图做指纹
    private func signature(_ img: UIImage) -> String {
        let w = 16, h = 32
        guard let cg = img.cgImage else { return "-" }
        var buf = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return "-"
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf.map { String($0 / 64) }.joined()
    }

    private func append(_ s: String) {
        log(s)
        DispatchQueue.main.async {
            self.trace.append(s)
            if self.trace.count > 400 { self.trace.removeFirst(self.trace.count - 400) }
        }
    }

    private func sleep(_ s: Double) {
        var left = s
        while left > 0 && !cancelFlag {
            let d = min(0.2, left)
            Thread.sleep(forTimeInterval: d)
            left -= d
        }
    }

    private func finish(_ reason: String) {
        DispatchQueue.main.async { self.stopReason = reason }
        log("§run \(reason)")
    }
}
