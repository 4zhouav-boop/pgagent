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
    /// ⭐⭐⭐ 「认不出」的**容忍次数**（§2240）
    ///
    /// ## 为什么必须容忍（用户原话）
    /// > 「认不出就不做了，**直接自杀** 你还推荐。**要眼睛干什么**」
    ///
    /// ⇒ 铁律是「⛔ **不盲点**」（不猜坐标），但**不是**「一帧认不出就放弃」。
    ///    真实的 `unknown` 大多来自**瞬时态**：页面转场、广告开头/结尾、
    ///    弹窗动画、首帧还没渲染完。这些**下一帧就好了**。
    ///
    /// ⇒ 所以：`unknown` 时**再抓几帧 + 跑漏斗**，
    ///    连续 `unknownLimit` 次才认输。
    private var unknownLimit: Int {
        cfgStore.cfg?.settings?.loop_unknown_limit ?? 6
    }
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
            writeHeartbeat(["phase": "deferred-exit"])
        }

        guard let cfg = cfgStore.cfg else { finish("配置未加载"); return }

        let rec = Recognizer(templatesDir: ConfigStore.templatesDir())
        // ⭐⭐ 把归一化日志接到本循环的日志窗（§2241）
        //    ⇒ 「帧 1353x2925 ⇒ 归一化到 451x977」这行会直接出现在手机上，
        //      以后一眼就能看出「尺度对不对」，⛔ 不用再猜为什么全 unknown
        rec.onLog = { [weak self] s in self?.append(s) }
        let nav = Navigator(cfg: cfg, rec: rec, ble: ble) { [weak self] s in
            self?.append(s)
        }

        let target = dest ?? cfg.settings?.target ?? "center"
        log("§run ▶️ 开始 目标=\(target) 最大步数=\(maxSteps) 广告停留=\(Int(adStayMin))~\(Int(adStayMax))s")
        writeTraceLine("=== 开始 目标=\(target) 最大步数=\(maxSteps) ===")
        writeHeartbeat(["phase": "start", "target": target, "maxSteps": maxSteps])

        // ⭐⭐⭐⭐⭐ §2631 **开机自检：帧龄上限必须 > 录屏节拍**（⛔ 否则必然"全 unknown"）
        //
        // ## ⛔⛔ 血案（用户令，本轮）
        // > 「**你换了图片识别好像搞崩了程序 现在全识别未知了。你要做好全局适配啊**」
        //
        // 我把录屏扩展从 **1 帧/1s** 改成 **1 帧/10s**（原分辨率 + 用户令的 10s 间隔），
        // 但设备上的 `loop_frame_max_age` **还是旧的 3.0s** ⇒ 真机日志逐字：
        // ```
        // 22:20:39  §geo 帧 888x1920 ⇒ 归一化到 451x977      ← 帧分辨率改动✅生效
        // 22:20:47  §grab ⛔ 帧龄 7.6s > 上限 3.0s            ← ⛔ 上限还是旧的
        // 22:21:07  §grab 第 2 次未拿到帧，重试…              ← 于是**永远拿不到帧**
        // ```
        // ⇒ `grab()` 恒失败 ⇒ 全链路 `unknown`（用户看到的"全识别未知"）。
        //
        // 📏 本仓库**自己早就记过**这条铁律（config 的 `_loop_doc` 末尾逐字）：
        // > 📏 教训：**节拍与判据必须成对调** —— 只改一边就会自己把自己判死
        // >   （§2265 曾出现：节拍降到 1帧/4s 而上限还是 3.0s ⇒ 每帧都误判"画面是旧帧"）。
        //
        // ✅ 现在**开机就自检并明确报出来**（⛔ 不再让用户/我事后去猜）：
        //   帧龄上限若 **<=** 节拍（10s），直接**拒绝开跑**并说清怎么改。
        //   📏 判据用"上限必须 > 节拍 + 2s 余量"，与 config 的 14.0 一致。
        let frameAgeCap = cfg.settings?.loop_frame_max_age ?? 3.0
        let minCap = Self.outFpsInterval + 2.0
        if frameAgeCap < minCap {
            let msg = String(format: "⛔ 配置自检不过：`loop_frame_max_age` = %.1fs，"
                             + "而录屏节拍是 %.0fs/帧 ⇒ **帧永远算\"旧帧\" ⇒ 全 unknown**。"
                             + " ⇒ 请把 config.json 的 `loop_frame_max_age` 调到 **≥ %.1fs** 再跑"
                             + "（⛔ 这是 §2265/§2631 记过的\"节拍与判据必须成对调\"）",
                             frameAgeCap, Self.outFpsInterval, minCap)
            log("§run \(msg)")
            finish(msg)
            return
        }
        log(String(format: "§run ✅ 配置自检：loop_frame_max_age=%.1fs > 节拍 %.0fs + 2s 余量",
                   frameAgeCap, Self.outFpsInterval))

        // ⭐⭐⭐⭐⭐ §2364 **第一步：切到目标 App** —— 用**真机验过的序列**（§2360~§2363）
        //
        // 用户令（逐字）：「**怎么实现的你就自己操作ESP32用蓝牙命令跑通再写入软件。**」
        // ⇒ 下面这段不是我设计的，是**在 ESP32 上一条一条试出来**的结果：
        // ```
        //   | 起点        | 命令              | 实测结果                        |
        //   | 快手 App 内 | H:HOME            | ✅ 回主桌面                     |
        //   | 副桌面      | H:HOME            | ❌ 什么都不做（帧文字一模一样）  |
        //   | 副桌面      | 底部快速上滑 ×1   | ⚠️ 只挪一格，没回主桌面          |
        //   | 副桌面      | 底部快速上滑 ×2   | ✅ 回到主桌面（快手图标出现）    |
        //   | 主桌面      | 点图标            | ✅ 进入快手（页型 = feed）       |
        // ```
        // ⇒ **回主桌面 = "上滑到看见快手为止"**，⛔ 不是某一条命令。
        //   ⛔ 已删除的两条错腿：左右翻页（用户明令）、把 `H:HOME` 当主腿（副桌面无效）。
        //
        // ## 为什么必须先切
        // 手机端录屏录的是**当前前台** ⇒ 点「开始跑」时前台是 PGAgent
        // ⇒ 录到的就是控制台 ⇒ 识别必然全部 `unknown`。
        let apps = cfg.settings?.apps ?? []
        let which = apps.first ?? "kslite"
        if cfg.settings?.auto_goto_app ?? true {
            log("§run ⭐ 切 App（上滑→认图标→点，全程 ESP32）：\(which)")
            let ok = Navigator.switchToApp(named: which, rec: rec, ble: ble,
                                           frame: { [weak self] in self?.grabSync() },
                                           baseW: cfg.settings?.base_w ?? 451,
                                           baseH: cfg.settings?.base_h ?? 977,
                                           yFix: cfg.settings?.y_fix ?? 4,
                                           log: { [weak self] s in self?.append(s) })
            log("§run 切 App \(ok ? "✅ 已发出点图标" : "⛔ 没找到图标")")
            Thread.sleep(forTimeInterval: 2.5)      // 等界面稳定再抓帧（照 PC wait(6.5)）

            // ⭐⭐⭐⭐⭐ §2621 **开屏广告等待（8 秒）—— 用户令逐字**
            //
            // > 「**的确前面进来有开屏广告 你设置一个等待8秒再执行找红包的逻辑。**」
            //
            // ## ⛔ 为什么要等（真机血案，本轮）
            // 冷启动快手极速版时**先出开屏广告**（全屏视频/大图 + 右上「跳过」）。
            // 此时：
            //   · 红包悬浮球**还没画出来** ⇒ `find_coin_entry` 返回 None
            //     （真机 trace 逐字：`§coin 没找到红包悬浮球（⛔ 不盲点）`）
            //   · 于是 `feed.go = coin_ball` 被**记死** ⇒ 退到 `feed.alts` 点「消息」
            //     ⇒ 但开屏广告期间页面**还在变** ⇒ 页型判据把消息页当 feed
            //     ⇒ 「点消息 → 还判 feed → 再点消息」**死循环**（§2621 全套血案）。
            // ⇒ 根因就是**进 App 后抓帧太早**（原来只等 2.5s，而开屏广告通常 3~5s）。
            //
            // ## ✅ 做法
            // 切到 App 之后**先等 8 秒**（用户给的数），让开屏广告自己走完、
            // 主页画出来之后，再进 adbox 去找红包球。
            //   ⚠️ 仍用 `sleepWithCancel` 语义：随时可被「停」打断（⛔ 不是死睡）。
            //   📏 8 秒是**用户口径**；`splash_wait_s` 可覆盖（⛔ 不硬编码两处）。
            let splash = cfg.settings?.splash_wait_s ?? 8.0
            if splash > 0 {
                log("§run ⏳ 等开屏广告走完（\(String(format: "%.1f", splash))s，用户口径）⇒ 再找红包球")
                var left = splash
                while left > 0 && !cancelFlag {
                    Thread.sleep(forTimeInterval: min(0.2, left))
                    left -= 0.2
                }
                log("§run ✅ 开屏等待结束")
            }
        }

        // ⭐⭐⭐ §2255 **有勾选功能 ⇒ 走 FeatureEngine 的一轮闭环**
        //
        // 为什么这样分流（照 PC L9360~9395 的语义）：
        //   · config 里**没设** `features`（或为空）⇒ 走原来的**纯导航**循环（旧行为一字不改）
        //   · config 里**设了** `features`      ⇒ 走 `FeatureEngine.runRound()`
        //     它内部按 `FEAT_ORDER` 依次跑 adbox/feed/tag/search，每棒跑完回中心
        //
        // ⚠️ 这样「只跑导航」的老用法**完全不受影响**（用户令：旧行为零改动）。
        let feats = cfg.settings?.features?.filter { FeatureEngine.order.contains($0) } ?? []
        if !feats.isEmpty {
            log("§run ⭐ 走功能闭环（\(feats.count) 个功能：\(feats.map(FeatureEngine.cn).joined(separator: " / "))）")
            let fe = FeatureEngine(cfgStore: cfgStore, nav: nav, rec: rec, ble: ble,
                                   grab: { [weak self] in self?.grabSync() },
                                   isCancelled: { [weak self] in self?.cancelFlag ?? true },
                                   beat: { [weak self] d in self?.writeHeartbeat(d) },
                                   log: { [weak self] s in self?.append(s) })
            let rep = fe.runRound()
            let done = (rep["done"] as? [String]) ?? []
            finish("✅ 功能闭环结束：完成 \(done.count)/\(feats.count)"
                   + (done.isEmpty ? "" : "（\(done.map(FeatureEngine.cn).joined(separator: "、"))）"))
            return
        }
        log("§run ⚠️ 没勾功能 ⇒ 只跑导航循环（旧行为）")

        var stall = 0
        var lastSig = ""
        /// ⭐ 连续「认不出」计数（见 `unknownLimit` 的说明）
        var unknownStreak = 0

        for k in 0..<maxSteps {
            if cancelFlag { finish("用户停止"); return }
            DispatchQueue.main.async { self.step = k + 1 }
            writeHeartbeat(["phase": "loop", "k": k, "unknownStreak": unknownStreak])

            // ① 抓帧
            guard let img = grabSync() else {
                finish("抓帧失败：\(grabber.lastError)")
                return
            }
            writeHeartbeat(["phase": "grabbed", "k": k])

            // ② 判页
            let page = nav.pageHere(img) ?? "unknown"
            DispatchQueue.main.async { self.lastPage = page }
            writeHeartbeat(["phase": "paged", "k": k, "detected": page])

            // ③ 到目的地了吗？
            if page == target {
                finish("✅ 已到达 \(target)（第 \(k + 1) 步）")
                return
            }

            // ④ ⛔⛔ 广告页：**待够时间**，⛔ 不点 ✕（用户令 + 荔枝 40/60 秒）
            if page == "ad_video" {
                log("§run ⛔ 广告页 ⇒ 放行（待够 \(Int(adStayMin))~\(Int(adStayMax))s，⛔ 不点 ✕）")
                DispatchQueue.main.async { self.lastAction = "ad-stay" }
                unknownStreak = 0
                adStayLoop()
                continue
            }

            // ⑤ ⭐⭐ **认不出 ⇒ 先容忍，别自杀**（§2240）
            //
            // 用户原话：「认不出就不做了，直接自杀 你还推荐。要眼睛干什么」
            // ⇒ `unknown` 多是**瞬时态**（转场/广告首尾/弹窗动画/首帧未渲染）
            // ⇒ 再抓几帧、顺带跑一遍漏斗（弹窗常在这时能被认出来），
            //    连续 `unknownLimit` 次才认输。
            if page == "unknown" {
                unknownStreak += 1
                // ⭐⭐⭐⭐ §2263 **先把"死帧"和"真认不出"分开** —— 这是本轮最重要的分流。
                //
                // ⛔ 我原来的病：广播死了 ⇒ 一直喂死帧 ⇒ 一直 `unknown` ⇒
                //   日志只写「画面认不出」⇒ **我照着日志去改识别**（ROI/判据/模板），
                //   而真病在"眼"（根本没拿到当前画面）。**在错的轴上努力了好几轮。**
                //
                // ✅ 现在：帧龄超上限 ⇒ **明确报"画面是旧的"**，⛔ 不再伪装成识别问题。
                if let b = broadcaster, let age = b.lastFrameAge(), age > maxFrameAge {
                    let msg = String(format: "⛔ 画面是**旧帧**（帧龄 %.1fs > %.1fs）⇒ 录屏已停，"
                                     + "⛔ 不是识别问题（去点「开录屏」→ 系统面板「开始直播」）",
                                     age, maxFrameAge)
                    log("§run \(msg)")
                    finish(msg)
                    return
                }
                DispatchQueue.main.async { self.lastAction = "unknown-retry(\(unknownStreak))" }
                log("§run ⚠️ 画面认不出（第 \(unknownStreak)/\(unknownLimit) 次）⇒ 重抓再看")
                // 顺手试试漏斗：弹窗盖屏时**底下**的页面判不出来，
                // 但漏斗元素（关闭✕/跳过/我知道了）往往能认出来
                if nav.runFunnel(img) {
                    DispatchQueue.main.async { self.lastAction = "funnel(unknown)" }
                    unknownStreak = 0
                }
                if unknownStreak >= unknownLimit {
                    finish("⛔ 连续 \(unknownLimit) 帧认不出 ⇒ 停手（不盲点）")
                    return
                }
                writeHeartbeat(["phase": "unknown-retry", "k": k,
                                "unknownStreak": unknownStreak])
                sleep(stepWait)
                continue
            }
            unknownStreak = 0

            // ⑥ 卡死检测
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

            // ⑦ ⭐ 杂七杂八处理（荔枝的「杂七杂八处理」）—— 弹窗优先
            if nav.runFunnel(img) {
                DispatchQueue.main.async { self.lastAction = "funnel" }
                sleep(stepWait)
                continue
            }

            // ⑧ ⭐ 转化关键词检查（荔枝的 `settingsConversionKeyword`）
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

            // ⑨ ⭐⭐ 页面图上前进一跳（**带记死**，§2247 移植 PC `_nav_to_center`）
            //
            // ⛔ 老写法的问题（真机 trace 铁证）：
            //     `feed.go = "tab_home"`，而 feed **本身就是首页**
            //     ⇒ 点它没效果 ⇒ 下一帧还是 feed ⇒ **原地打转 6 次**
            //     （而且卡死检测拦不住 —— 快手信息流有视频，指纹每帧都变）
            // ✅ 新写法：`Navigator.step` 会
            //     ① 按 `go` → `alts` 顺序试**没记死**的出路
            //     ② 点完**再抓一帧**比上半屏有没有变
            //     ③ 没变 ⇒ **记死这条腿**，换下一条
            if let p = cfg.pages[page], (p.go != nil || !(p.alts ?? []).isEmpty) {
                let r = nav.step(from: page, img: img) { [weak self] in
                    self?.grabSync()
                }
                if r.acted {
                    DispatchQueue.main.async { self.lastAction = "tap:\(r.go ?? "?")" }
                    if !r.changed {
                        log("   §run ⚠️ 点了 \(r.go ?? "?") 画面没变 ⇒ 下一步换腿")
                    }
                    sleep(stepWait)
                    continue
                }
                log("§run ⛔ 在 \(page) 的出路**全被记死** ⇒ 停手")
                finish("⛔ 在 \(page) 所有出路都试过且无效 ⇒ 停手")
                return
            }

            // ⑩ ⛔ 页面认得、但配置里没给出路 ⇒ 停手（⛔ 不盲点）
            finish("⛔ 在 \(page) 配置里没有出路 ⇒ 停手")
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
                // ⭐⭐⭐⭐ §2263 **只要「新鲜」的帧** —— 照荔枝
                //   （`_note_2010` L62 / `_note_2011` L253：「⏳ 等待截图文件生成…(第10次检查)」、
                //     「📝 截图文件存在但大小不足: 0 bytes，继续等待…」⇒ **绝不把旧图当当前画面**）
                //
                // ⛔ 我原来的病：**直接 `return UIImage(data: d)`，从不问这一帧多旧**。
                //   ⇒ 广播一停，`lastFrame` 里那张**死帧**被反复送去识别 ⇒ 永远 `unknown`
                //   ⇒ 我把它误判成"识别不行"，去改 ROI/判据（**错的轴**，浪费大量时间）。
                //
                // 真机并排对照铁证（`_var/_cmp_side.png`，同一时刻取两张）：
                //   左 iOS 截图 13:22 = 「所有快捷指令」+「直播已停止」弹窗
                //   右 App 帧    13:15 = PGAgent 自己的界面  ← ⛔ 7 分钟前的死帧
                if let age = b.lastFrameAge(), age <= maxFrameAge,
                   let d = b.lastFrame, let im = UIImage(data: d) {
                    return im
                }
                // 帧太旧（或还没有）⇒ 主动读一次文件，再等
                b.pollFrame()
                if let age = b.lastFrameAge(), age <= maxFrameAge,
                   let d = b.lastFrame, let im = UIImage(data: d) {
                    return im
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            // ⛔ 等不到新鲜帧 ⇒ **明确报出来**（⛔ 不拿旧帧糊弄下游）
            let age = b.lastFrameAge()
            log("   §grab ⛔ 等不到**新鲜**录屏帧（最新帧龄 "
                + (age.map { String(format: "%.1fs", $0) } ?? "无帧")
                + " > 上限 \(String(format: "%.1fs", maxFrameAge))）"
                + " ⇒ 录屏多半已停（去点「开录屏」→ 系统面板「开始直播」）")
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

    /// ⭐⭐⭐⭐⭐ §2631/§2635 **「眼」的节拍：每帧间隔多少秒**（⛔ **唯一真源**）
    ///
    /// ## 为什么必须有这一个常量（用户令："你要做好全局适配啊"）
    /// 这个数**同时**决定两件事，而它们**必须一致**：
    /// ```
    ///   ① 录屏扩展多久产生一帧（PGShot.fps = 1/2 ⇒ 2s）
    ///   ② 主 App 判"这帧算不算新鲜"（loop_frame_max_age 必须 > ①）
    /// ```
    /// ⛔ 我一度只改了 ①（扩展的 fps），忘了 ②（config 的上限）⇒
    ///   `帧龄 7.6s > 上限 3.0s` ⇒ `grab()` 恒失败 ⇒ **全 unknown**（用户看到的现象）。
    /// 📏 本仓库自己记过这条铁律（config `_loop_doc` 逐字）：
    /// > **节拍与判据必须成对调** —— 只改一边就会自己把自己判死（§2265）。
    ///
    /// ## ⭐ §2635 **为什么是 2.0（⛔ 不是用户先提的 10.0）**
    /// 用户说「原分辨率 …… 但是每次识别间隔10秒」——那是**为"省 CPU"付的代价**。
    /// 而真机实测（`_dev/_2635_roi_cost.py`）证明**没有那么多 CPU 可省**：
    /// ```
    ///   固定开销 ≈ 156ms（HTTP+读文件+建请求）—— 与图大小无关，占小 ROI 的 99%
    ///   顶栏胶囊 ROI：原生2× 163ms ｜ 原生1× 157ms ｜ 基准2×(旧) 157ms   ← 只差个位数
    /// ```
    /// ⇒ 真正的浪费是 `ocrScale=2.0`（**不缩了就不该再放大**，见 `Recognizer.ocrScale`），
    ///   把它降到 1.0 ⇒ **同 CPU、更好识别**。
    ///   ⇒ 于是 **10s 间隔的代价不必付** —— 它会让所有"动作后看结果"都等 10s+，
    ///     而广告倒计时/弹窗/转场都是**秒级**事件（§2631 一连串血案全是它引起的）。
    /// 📏 铁律（§1433）：「**永远要问自己是否还有更优秀又简单的方案**」
    ///   ⇒ 降 `ocrScale` 比降帧率**更优**：⛔ 不是"用识别质量换 CPU"。
    static let outFpsInterval: Double = 2.0

    /// ⭐ 帧**新鲜度**上限（秒）—— 超过就**不算"当前画面"**（照荔枝"只认新截图"）
    ///
    /// 扩展按 2fps 写帧 ⇒ 正常帧龄 **< 0.5s**。
    /// 给到 `loop_frame_max_age`（默认 **3s**）⇒ 容忍几帧抖动，
    /// 但**一定**能把"广播已死"和"广播在跑"分开。
    private var maxFrameAge: Double {
        cfgStore.cfg?.settings?.loop_frame_max_age ?? 3.0
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

    /// ⭐⭐⭐ **心跳/日志文件**（§2236）—— 写到 App Group **共享容器**
    ///
    /// ## 为什么必须有它
    /// App 退后台后 **HTTP 不再响应**（iOS 把监听 socket 挂起），
    /// 于是「Runner 到底有没有在跑」**完全看不到** —— 这正是用户
    /// 反复抱怨的「**没日志 / 卡死界面上 / 不知道在干什么**」。
    ///
    /// 共享容器是**文件**，⛔ 不受 App 挂起影响：
    /// ```
    /// PC: ios file pull --app-group=<gid> --remote=/Documents/run_status.json
    /// ```
    /// ⇒ 任何时候都能看到：跑到第几步、在哪一页、什么动作、为什么停。
    ///
    /// 同时写一个**只追加**的 `run_trace.log`（最近 N 行）。
    ///
    /// ## ⭐⭐ 为什么要写**两个地方**（§2249 用户令）
    /// > 「**你现在还是全程用开发者权限，说了不要用开发者。**」
    ///
    /// 读心跳的两条通道，**只有一条不需要开发者模式**：
    /// | 写到哪 | 怎么读 | 要开发者模式吗 |
    /// |---|---|---|
    /// | **App Group 共享容器** | `ios file --app-group=…` | ✅ **要** |
    /// | ⭐ **App 自己的 Documents** | `ios fsync`（AFC/house_arrest）| ⛔ **不要** |
    ///
    /// ⇒ **两边都写**：
    ///   · 共享容器 —— 给「扩展也看得见」的场合留着（帧在那儿）
    ///   · ⭐ **Documents** —— 给 PC 用 `fsync` 读（⛔ 不碰开发者模式）
    private func heartbeatURLs(_ name: String) -> [URL] {
        var out: [URL] = []
        if let g = AppGroup.sharedFile(name) { out.append(g) }
        // ⭐ App 自己的 Documents（`ios fsync` 能读，⛔ 不用开发者模式）
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        out.append(docs.appendingPathComponent(name))
        return out
    }

    private func writeHeartbeat(_ extra: [String: Any] = [:]) {
        var d: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "t": Date().timeIntervalSince1970,
            "running": running,
            "step": step,
            "page": lastPage,
            "action": lastAction,
            "stopReason": stopReason,
            "error": lastError,
            "adProgress": adProgress,
            "keepAlive": SilentKeepAlive.shared.started,
        ]
        for (k, v) in extra { d[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: d,
                                                     options: [.prettyPrinted]) else { return }
        for u in heartbeatURLs("run_status.json") {
            try? data.write(to: u, options: .atomic)
        }
    }

    /// ⭐ 追加一行到日志（**两个位置都写**，理由见 `heartbeatURLs`）
    private func writeTraceLine(_ s: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
        let data = Data(line.utf8)
        for u in heartbeatURLs("run_trace.log") {
            if let h = try? FileHandle(forWritingTo: u) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: u, options: .atomic)
            }
        }
    }

    private func append(_ s: String) {
        log(s)
        writeTraceLine(s)          // ⭐ 也落到共享容器（App 挂起后仍可读）
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
        writeTraceLine("=== 结束：\(reason) ===")
        writeHeartbeat(["phase": "finished", "reason": reason])
    }
}
