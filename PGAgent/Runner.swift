import Foundation
import UIKit

/// ⭐⭐⭐⭐ 「大脑」—— **自主循环**（App 自己在手机上跑，⛔ 不需要 PC）。
///
/// ## 为什么需要它
/// 之前的分工是「PC 抓帧 → PC 识别 → PC 发指令」，手机只是个执行器。
/// 用户令：「**以后是全部交到手机上的，调试可以取画面，APP那边得自己取画面。**」
/// ⇒ 这个类把 PC 侧的循环**整体搬进 App**：
///
/// ```
/// ① 抓帧（ScreenGrabber 触发快捷指令截图）
/// ② 判页（Navigator.pageHere）
/// ③ 到目的地了吗？ → 到了就停
/// ④ 广告页？ → ⛔ 放行（用户令：「都是跑循环广告」）
/// ⑤ 恢复漏斗（弹窗盖屏优先）
/// ⑥ 页面图上前进一跳
/// ⑦ 卡死检测（画面没变 / 原地打转）→ 停手并报告
/// ```
///
/// ## 铁律
/// · ⛔ **先找到再点**（坐标来自识别结果，绝不盲点）
/// · ⛔ **广告页放行**（不点广告的 ✕）
/// · ⛔ **认不出就停**（不猜、不硬闯）
///
/// ## 设计
/// 全部参数来自 `config.json`（`settings.loop_*`），⛔ 改行为不用重装。
final class Runner: ObservableObject {

    // MARK: - 状态（HTTP 可查）

    @Published private(set) var running = false
    @Published private(set) var step = 0
    @Published private(set) var lastPage = "-"
    @Published private(set) var lastAction = "-"
    @Published private(set) var lastError = ""
    @Published private(set) var stopReason = "-"
    @Published private(set) var trace: [String] = []

    private let cfgStore: ConfigStore
    private let grabber: ScreenGrabber
    private let ble: BLEController
    private let log: (String) -> Void

    /// 循环跑在自己的串行队列上（⛔ 不阻塞 HTTP 线程）
    private let q = DispatchQueue(label: "pgagent.runner", qos: .userInitiated)
    private var cancelFlag = false

    init(cfgStore: ConfigStore, grabber: ScreenGrabber, ble: BLEController,
         log: @escaping (String) -> Void) {
        self.cfgStore = cfgStore
        self.grabber = grabber
        self.ble = ble
        self.log = log
    }

    // MARK: - 参数（全部来自配置）

    private var maxSteps: Int { cfgStore.cfg?.settings?.loop_max_steps ?? 40 }
    private var stepWait: Double { cfgStore.cfg?.settings?.loop_step_wait ?? 1.5 }
    private var grabTimeout: Double { cfgStore.cfg?.settings?.loop_grab_timeout ?? 10.0 }
    private var stallLimit: Int { cfgStore.cfg?.settings?.loop_stall_limit ?? 3 }

    // MARK: - 控制

    func start(dest: String?) {
        guard !running else {
            log("§run ⚠️ 已在跑，忽略")
            return
        }
        cancelFlag = false
        running = true
        step = 0
        trace.removeAll()
        lastError = ""
        stopReason = "-"
        q.async { [weak self] in self?.loop(dest: dest) }
    }

    func stop() {
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
            "trace": Array(trace.suffix(40)),
        ]
    }

    // MARK: - 主循环

    private func loop(dest: String?) {
        defer {
            DispatchQueue.main.async { self.running = false }
            log("§run === 结束：\(stopReason) ===")
        }

        guard let cfg = cfgStore.cfg else {
            finish("配置未加载")
            return
        }

        let rec = Recognizer(templatesDir: ConfigStore.templatesDir())
        let nav = Navigator(cfg: cfg, rec: rec, ble: ble) { [weak self] s in
            self?.append(s)
        }

        // 目标页：默认 config 里的 `target`，可被请求覆盖
        let target = dest ?? cfg.settings?.target ?? "center"
        log("§run ▶️ 开始 目标=\(target) 最大步数=\(maxSteps)")

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

            // ④ ⛔ 广告页放行（用户令：「都是跑循环广告，你他妈一个广告就点X」）
            if page == "ad_video" {
                log("§run ⛔ 广告页 ⇒ 放行（不碰）")
                DispatchQueue.main.async { self.lastAction = "ad-pass" }
                sleep(stepWait)
                continue
            }

            // ⑤ 卡死检测（画面签名连续不变 ⇒ 停手）
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

            // ⑥ 恢复漏斗（弹窗盖屏优先 —— 盖屏时底下什么都点不到）
            if nav.runFunnel(img) {
                DispatchQueue.main.async { self.lastAction = "funnel" }
                sleep(stepWait)
                continue
            }

            // ⑦ 页面图上前进一跳
            if let p = cfg.pages[page], let go = p.go, go != "stop" {
                if nav.tap(go, img: img) {
                    DispatchQueue.main.async { self.lastAction = "tap:\(go)" }
                    sleep(stepWait)
                    continue
                }
                log("§run ⚠️ 在 \(page) 想点 \(go) 但没找到")
            }

            // ⑧ ⛔ 认不出出路 ⇒ 停手（⛔ 不盲点）
            finish("⛔ 在 \(page) 认不出出路 ⇒ 停手")
            return
        }

        finish("达到最大步数 \(maxSteps)")
    }

    // MARK: - 工具

    /// 同步抓一帧（循环在自己的队列上，可以阻塞）
    private func grabSync() -> UIImage? {
        let sem = DispatchSemaphore(value: 0)
        var url: URL?
        grabber.grab(timeout: grabTimeout) { u, _ in
            url = u
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + grabTimeout + 4)
        guard let u = url else { return nil }
        return UIImage(contentsOfFile: u.path)
    }

    /// 画面签名：用极小的灰度缩略图做指纹（⛔ 不用全图，太快）
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
        // 量化成 4 档，减少噪声影响
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
        // 分片睡，保证能及时响应停止
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
