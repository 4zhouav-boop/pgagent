import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ 「大脑」—— **PG 控制台的手机版**（§2240 契约 / §2255 实现）。
///
/// ## 移植来源（⛔ 逐条照 PC 抄，⛔ 不臆造）
/// | 手机 | PC（`_dev/_1377_ad_loop.py`）|
/// |---|---|
/// | `FeatureEngine.order` | `FEAT_ORDER = ["adbox","feed","tag","search"]`（L9357 铁证）|
/// | `runAdbox` | 主 while 循环（L9410+）|
/// | `runFeed` | `run_feed()`（L5078）|
/// | `runTag` | `run_tag()`（L6842）|
/// | `runMall` | `run_mall()`（L7609）|
///
/// ## 一轮闭环的顺序（⭐ 硬契约，⛔ 不许改）
/// ```
/// 看广告得金币+宝箱  →  刷视频  →  搜索打标签  →  商城逛小店
///                                          ↑ 最后一棒，跑完回任务中心 = 一轮闭环
/// ```
///
/// ## ⛔ 两条铁律（用户令）
/// 1. **广告页放行**：「谁让你强退的，都是跑循环广告，你他妈一个广告就点X」
///    ⇒ 广告页**待够时间**，⛔ 绝不点 ✕。
/// 2. **打字必须落中文**：「打字一定要做到中文，**拼音绝对不行**」
///    ⇒ ⛔ 绝不提交生拼音（PC §1743 实测：生拼音 ⇒ 空页）。
final class FeatureEngine {

    /// ⭐⭐⭐ **权威执行顺序**（照抄 PC `FEAT_ORDER`，L9357）
    static let order = ["adbox", "feed", "tag", "search"]

    /// 中文名（与控制台 `FEATURE_OPTS` 一致，⛔ 用户要中文）
    static func cn(_ key: String) -> String {
        switch key {
        case "adbox":  return "看广告得金币 + 宝箱"
        case "feed":   return "刷视频"
        case "tag":    return "搜索打标签"
        case "search": return "商城逛小店"
        default:       return key
        }
    }

    private let cfgStore: ConfigStore
    private let nav: Navigator
    private let rec: Recognizer
    private let ble: BLEController
    private let grab: () -> UIImage?
    private let log: (String) -> Void
    private let isCancelled: () -> Bool
    private let beat: ([String: Any]) -> Void

    init(cfgStore: ConfigStore,
         nav: Navigator,
         rec: Recognizer,
         ble: BLEController,
         grab: @escaping () -> UIImage?,
         isCancelled: @escaping () -> Bool,
         beat: @escaping ([String: Any]) -> Void,
         log: @escaping (String) -> Void) {
        self.cfgStore = cfgStore
        self.nav = nav
        self.rec = rec
        self.ble = ble
        self.grab = grab
        self.isCancelled = isCancelled
        self.beat = beat
        self.log = log
    }

    /// ⚠️ `Settings` 嵌在 `PGConfig` 里（⛔ 不是 `ConfigStore.Settings`）—— 我上一版栽在这
    private var s: PGConfig.Settings? { cfgStore.cfg?.settings }
    private var baseW: Double { s?.base_w ?? 451 }
    private var baseH: Double { s?.base_h ?? 977 }
    private var yFix: Double { s?.y_fix ?? 4 }

    /// ⭐ 帧新鲜度上限（秒）—— 与 `Runner.maxFrameAge` **同一个配置项**
    ///
    /// ⚠️ 为什么这里也要有一份：`grabFresh(since:maxWait:)` 需要按
    ///    「一个写盘周期有多长」来决定等多久（§2265：节拍 1帧/4s ⇒ 上限 7s）。
    ///    `Runner` 里那份是 `private`，本类取不到 ⇒ 各自读**同一个** `config.json` 字段，
    ///    ⛔ 不硬编码两处不同的数（否则又是一处"改了 A 忘了 B"）。
    private var maxFrameAgeCfg: Double { s?.loop_frame_max_age ?? 7.0 }

    // MARK: - ⭐ 对外入口：跑**一轮完整闭环**

    /// 跑一轮：按 `order` 依次跑「勾到的」功能。
    ///
    /// ⭐ 语义**逐条对齐** PC（L9360~9395）：
    /// ```
    /// · features 为空        ⇒ 只跑 adbox（= PC 不设 AISJ_FEATURES 的旧行为）
    /// · 勾了 adbox          ⇒ 先跑广告循环，**跑完再按 order 跑其余**
    /// · 没勾 adbox          ⇒ ⛔ **不进广告循环**，只按 order 跑勾到的
    /// ```
    @discardableResult
    func runRound() -> [String: Any] {
        var feats = s?.features?.filter { Self.order.contains($0) } ?? []
        if feats.isEmpty { feats = ["adbox"] }          // ⭐ 旧行为：只跑广告

        // ⭐ 按**权威顺序**排（⛔ 不按用户填写顺序）
        let planned = Self.order.filter { feats.contains($0) }
        log("§feat ═══ 本轮功能：\(planned.map(Self.cn).joined(separator: " → ")) ═══")
        beat(["phase": "round-start", "planned": planned])

        var done: [String] = []
        for k in planned {
            if isCancelled() { log("§feat ⛔ 被中断"); break }
            log("§feat ▶️ 开始【\(Self.cn(k))】")
            beat(["phase": "feat-start", "feat": k, "done": done])

            let ok: Bool
            switch k {
            case "adbox":  ok = runAdbox()
            case "feed":   ok = runFeed()
            case "tag":    ok = runTag()
            case "search": ok = runMall()
            default:       ok = false
            }

            // ⭐ 每个功能跑完**统一回任务中心**（用户令：闭环要「链接起来」）
            log("§feat ⏹ 结束【\(Self.cn(k))】ok=\(ok) ⇒ 回任务中心")
            let centered = ensureInCenter(tag: "\(k)_after")
            beat(["phase": "feat-done", "feat": k, "ok": ok, "centered": centered])

            if ok { done.append(k) }
            if !ok {
                // ⛔ 一个功能失败**不整轮自杀**（用户令：「认不出就不做了，直接自杀 你还推荐」）
                log("§feat ⚠️【\(Self.cn(k))】没跑成 ⇒ 仍继续下一棒（⛔ 不整轮放弃）")
            }
        }

        log("§feat ═══ 本轮结束：完成 \(done.count)/\(planned.count) ═══")
        beat(["phase": "round-done", "done": done, "planned": planned])
        return ["planned": planned, "done": done]
    }

    // MARK: - ① adbox 看广告得金币 + 宝箱

    /// ⭐ 照 PC 主循环：回中心 → 找广告任务 → 点进去 → **广告页待够时间** → 回中心。
    private func runAdbox() -> Bool {
        let count = max(1, s?.ad_count ?? 6)          // PC 控制台「条数」默认 6
        let dwell = s?.ad_dwell ?? 30                  // PC 控制台「广告停留秒」默认 30
        log("§adbox 条数=\(count) 广告停留=\(Int(dwell))s 入口=\(s?.entry ?? "auto")")

        guard ensureInCenter(tag: "adbox_boot") else {
            log("§adbox ⛔ 回不到金币中心 ⇒ 停手")
            return false
        }

        var n = 0
        var emptyRounds = 0
        while n < count {
            if isCancelled() { log("§adbox ⛔ 被中断"); break }
            guard let img = grab() else { log("§adbox ⛔ 抓帧失败"); break }
            beat(["phase": "adbox-step", "n": n, "of": count])

            // ① ⭐⭐⭐⭐⭐ 广告页（视频/直播**同一条路**）—— 照 PC 分支A + G3 + G4 **逐条**
            //
            // ## ⛔⛔ 我上一版把**顺序搞反了**（用户令，逐字）
            // > 「**倒计时是广告没结束 你没结束去点 不是傻逼。广告结束了你不点了。**」
            // 而 PC 早就把这条写成了**血案**（`_1377_ad_loop.py:9814`）：
            // > ⛔ 我一度反了：以为"要抢在倒计时走完前点 ✕"，
            // >   结果**倒计时没走完就点 ✕ 会把广告点死**（停在「Ns后可领取X金币」+ 面板永不弹）。
            // > ✅ 正确顺序：**必须等倒计时结束**（胶囊文案变成「已成功领取X金币 ✕」）才点 ✕。
            //
            // ## PC 的完整顺序（分支A → G3 → G4）
            // ```
            // ① 先等 30~60s 随机（§1541 用户口径：「等待时间还是要做个随机数字，30-60 随机」）
            // ② G3：**等倒计时结束**（轮数按胶囊里的 N 动态定：N+20s 余量）
            // ③ G4：倒计时结束后**才点 ✕**收奖励 ⇒ 处理弹出的面板
            // ```
            if Self.looksLikeAdPage(img, rec: rec, nav: nav, bw: baseW, bh: baseH) {
                // ── ① 先等 30~60s 随机（PC §1541 用户口径）──────────────
                //    ⛔ 不许"进去就点 ✕"（PC 原话：「进去就点X 卡死 出去进来像傻逼一样，最后点X」）
                //
                // ## ⛔⛔ §2278 **绝不能"盲等"**（用户令，逐字）
                // > 「**广告结束了你不点了。**」
                // 我上一版是 `sleepWithCancel(waitS)` —— **盲等 51 秒，期间不看画面**，
                // 而真机 `_var/_wait1_n.png` 铁证：胶囊早已是 **`✓ 已成功领取523金币`**
                // （广告**已结束**）却还在傻等 ⇒ **该点的时候不点**。
                //
                // ✅ 照 PC 的等待方式（L9849~L9856）：**边等边看顶栏**，
                //    一旦读到「**已成功领取**」⇒ **立即跳出等待**去点 ✕。
                //    PC 原文：
                //    ```python
                //    for k in range(_rounds):
                //        ...
                //        if "已成功领取" in top3:
                //            print("G3 倒计时已结束（第 %d 次检查）"); break
                //        wait(3.0)
                //    ```
                //    ⭐ 但**轮数是按胶囊里的 N 动态定的**（`_need = N + 20`）——
                //       ⛔ 不是盲等固定 51 秒。
                var cur = img
                let waitS = Double.random(in: 30...60)
                log("§adbox ⛔ 广告页 ⇒ 先等最多 \(Int(waitS))s（30~60 随机，照 PC §1541）"
                    + "；⭐ **边等边看顶栏**，广告一结束就立刻收奖励（⛔ 不盲等）")
                var slept = 0.0
                while slept < waitS, !isCancelled() {
                    let d = min(2.0, waitS - slept)
                    Thread.sleep(forTimeInterval: d)
                    slept += d
                    guard let im2 = grab() else { break }
                    cur = im2
                    // ⭐ 广告结束的两个信号（照 PC）：
                    //    ① 顶栏出现「已成功领取」= 奖励已到账 ⇒ **立即去点 ✕**
                    //    ② 顶栏**没有倒计时数字了** ⇒ 倒计时走完 ⇒ 也去点
                    let t2 = Self.adTopText(cur, rec: rec, bw: baseW, bh: baseH)
                    if t2.contains("已成功领取") {
                        log("   §adbox ✅ 顶栏「已成功领取」（等了 \(Int(slept))s）"
                            + " ⇒ **广告结束，立即收奖励**（⛔ 不再盲等）")
                        break
                    }
                    if !Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH) {
                        log("   §adbox ✅ 顶栏已无倒计时（等了 \(Int(slept))s）⇒ **倒计时走完，收奖励**")
                        break
                    }
                }

                // ── ② G3：**等倒计时结束**才许动手（PC L9814~L9858）────────
                //    ⭐ 判据 = PC 的「到账闸」（`_1377_ad_loop.py:4342`）：
                //      **只看顶栏还有没有 `N秒` / `Ns` 倒计时** ⇒ 有就**没走完 ⇒ 不点**。
                //      ⛔ 不能只认「已成功领取」——§1545 血案：倒计时早走完了，
                //        但 OCR 没读到那四个字 ⇒ 若只认它，就**永远不敢点**。
                var waited = 0.0
                while Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH),
                      waited < 90, !isCancelled() {
                    sleep(3.0)
                    waited += 3.0
                    guard let im3 = grab() else { break }
                    cur = im3
                    log("   §adbox G3 等倒计时结束（已等 \(Int(waited))s；⛔ 没结束不点 ✕）")
                }
                log("§adbox G3 倒计时已结束（等了 \(Int(waited))s）⇒ **现在才点 ✕ 收奖励**")

                // ── ③ G4：**倒计时结束后才点 ✕** + 处理面板（PC `_ad_finish`）──
                //    ⭐ 面板/胶囊 ✕ 都归这里处理；⛔ 上一版我在**倒计时中**就调它 ⇒ 点死广告。
                for _ in 0..<6 {
                    if isCancelled() { break }
                    guard let im4 = grab() else { break }
                    if !finishAdPanel(im4, tag: "adbox_ad\(n + 1)") { break }
                    sleep(1.5)
                }
                n += 1
                _ = ensureInCenter(tag: "adbox_back\(n)")
                continue
            }

            // ② ⭐⭐⭐ **按任务行定位**并点它（照 PC `find_ad_row_button`，L2146）
            //
            // ## ⛔⛔ 为什么不能用 `nav.detect("ad_task_btn")`（真机血案 §2263）
            // 原来那版拿**词表**在全屏找「看广告/去观看/去领取/立即领取」——
            // 而金币中心里**并存多条**含"广告/领取"的任务行，它们是**不同的任务**：
            //   · `看广告得金币`（最高4500000）    ← ✅ **本链条要进的就是它**
            //   · `刷广告视频赚金币`                ← ⛔ **另一个任务**
            //   · `立即签到`（连续签到那条）        ← ⛔ 另一个任务
            // ⇒ 真机实测就点错了：`§click ad_task_btn @(258,469) score=1.000
            //    ev=点击领取今天奖励/待领50金币|立即领取/去观看`
            //    —— 它命中的是**签到行/待领行**，不是「看广告得金币」行。
            //
            // ## PC 的做法（`_1377_ad_loop.py` L2120~L2174，逐条照抄）
            // ```python
            // AD_ROW_TASK_RX = re.compile(r"看\s*广\s*告\s*得\s*金\s*币")   # 唯一目标行
            // AD_ROW_Y_WIN  = 26      # 行内 y 容差：同一张卡片的标题与按钮落在此窗口
            // AD_ROW_X_MIN  = 330     # 右列按钮 x 下界
            // rows = _ocr_rows(words(img, (0, 250, 451, 977)))   # 按 y 聚成"行"
            // y_row = _task_row_y(rows)                          # 找「看广告得金币」那道行
            // if y_row is None: → **放弃本腿**（⛔ 不得改点同屏别的广告任务行）
            // cands = [同 y_row±26 内、x ≥ 330 的词] → 取**最右**那个当按钮
            // if 按钮文案 in AD_ROW_DEAD_KEYS: → 放弃（那行是"冷却中/已领取"，按了没用）
            // ```
            // ⛔ 铁律②：`看广告得金币` 是**唯一**目标；它不可用就**放弃本腿**，
            //    ⛔ **绝不"跳到下一行"**（用户 2026-10-06 明确纠正过：
            //    「你搞到刷广告得金币干什么 说了 是错的」）。
            if let btn = findAdRowButton(img) {
                log("§adbox 按行定位到「看广告得金币」行 ⇒ 按钮 \(btn.evidence) @(\(Int(btn.point.x)),\(Int(btn.point.y)))")
                nav.tapPoint(Double(btn.point.x), Double(btn.point.y))
                // ⭐⭐ §2265 **等一张"新的"帧再判**（⛔ 不是固定睡 2s 就抓）
                //
                // ## 为什么（与写盘节拍**成对**的一条）
                // 为活过 iOS 写入预算，扩展写盘节拍 = **1帧/4s**（§2265）。
                // 而原来这里是 `sleep(2.0)` + `grab()` ⇒ 4 秒窗口内拿到的
                // **还是点击前那张帧** ⇒ `pageHere(i2) == "ad_video"` 恒 false
                // ⇒ 日志刷「点了任务但没进广告页 ⇒ 重试」⇒ **明明进去了也说没进去**。
                // 📏 真机 trace 里那几行正是这个（`§adbox ⚠️ 点了任务但没进广告页 ⇒ 重试`）。
                //
                // ✅ 用 `grabFresh(since: img)` 等一张**与点击前不同**的帧；
                //    画面真没变 ⇒ 等满预算才判失败（结论仍对）。
                let i2 = grabFresh(since: img, maxWait: maxFrameAgeCfg + 3.0)
                // ⛔⛔ 判据必须用 `looksLikeAdPage`（**独立判据**），⛔ 不是 `pageHere == "ad_video"`：
                //    后者走 `elements` 表 ⇒ 真机胶囊 `已成功领取438金币 ×`/`1s后可领取560金币 ×`
                //    **读不出** ⇒ 恒 false ⇒ 日志刷「点了任务但没进广告页 ⇒ 重试」
                //    而**人其实已经进去了**（真机 trace 那几行正是这个假阴性）。
                if let i2 = i2,
                   Self.looksLikeAdPage(i2, rec: rec, nav: nav, bw: baseW, bh: baseH) {
                    // ⛔⛔ **必须先等倒计时结束，才许点 ✕**（用户令 + PC G3）
                    // > 「**倒计时是广告没结束 你没结束去点 不是傻逼。广告结束了你不点了。**」
                    // ⚠️ 而且**不能盲等**（§2278）：边等边看顶栏，广告一结束就立刻去点。
                    var cur = i2
                    let waitS = Double.random(in: 30...60)
                    log("§adbox ⛔ 已进广告页 ⇒ 先等最多 \(Int(waitS))s（30~60 随机，照 PC §1541）")
                    var slept = 0.0
                    while slept < waitS, !isCancelled() {
                        let d = min(2.0, waitS - slept)
                        Thread.sleep(forTimeInterval: d)
                        slept += d
                        guard let im3 = grab() else { break }
                        cur = im3
                        let t3 = Self.adTopText(cur, rec: rec, bw: baseW, bh: baseH)
                        if t3.contains("已成功领取") {
                            log("   §adbox ✅ 顶栏「已成功领取」（等 \(Int(slept))s）"
                                + " ⇒ 广告结束，立即收奖励")
                            break
                        }
                        if !Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH) {
                            log("   §adbox ✅ 倒计时已走完（等 \(Int(slept))s）⇒ 收奖励")
                            break
                        }
                    }
                    // ⭐ G3 余量：倒计时若还没走完（长广告），再补等（照 PC `N+20s` 余量）
                    var waited = 0.0
                    while Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH),
                          waited < 60, !isCancelled() {
                        sleep(3.0)
                        waited += 3.0
                        guard let im3 = grab() else { break }
                        cur = im3
                        log("   §adbox G3 再等倒计时（已等 \(Int(waited))s；⛔ 没结束不点 ✕）")
                    }
                    log("§adbox G3 倒计时结束 ⇒ **现在才点 ✕ 收奖励**")
                    for _ in 0..<6 {
                        if isCancelled() { break }
                        guard let im4 = grab() else { break }
                        if !finishAdPanel(im4, tag: "adbox_in\(n + 1)") { break }
                        sleep(1.5)
                    }
                    n += 1
                    _ = ensureInCenter(tag: "adbox_back\(n)")
                    continue
                }
                log("§adbox ⚠️ 点了任务但没进广告页 ⇒ 重试")
                sleep(1.5)
                continue
            }

            // ③ ⛔⛔⛔ **先在广告页上放行**（照 PC `is_ad_page`）—— ⛔ 绝不能落到漏斗去点 ✕
            //
            // ## ⛔⛔ 血案（用户令）：「**时间都没到就提前点击了X**」
            // 真机 `_var/_ad2_n.png` 铁证：胶囊写着 **`1s后可领取560金币`**（只剩 1 秒），
            // 而脚本**把它关了** —— 因为这里原来**直接掉进漏斗**，
            // 而漏斗里有 `pill_x`（顶栏胶囊 ✕）⇒ **把正在看的广告点掉了**。
            //
            // ## 为什么页型判据救不了（必须用**独立判据**拦）
            // `nav.pageHere(img) == "ad_video"` 走 `elements` 表（`ad_capsule`），
            // 而真机胶囊 `1s后可领取560金币 ×` **读不出** ⇒ 页型 `unknown`
            // ⇒ 上面第 ① 条的放行**没命中** ⇒ 掉进漏斗 ⇒ 点 ✕。
            //
            // ## ✅ 照 PC 的两道防线
            // ```
            //   ① 主循环里 `is_ad_page(img)` ⇒ **放行**（`_1377_ad_loop.py` L9189）
            //   ② 导航里 `is_ad_page(img)` ⇒ **return False 不碰**（L2698）
            // ```
            // PC 判据（L3609）是**顶栏原文子串**：`("可领取" in t) or ("已成功领取" in t)`
            // ⇒ ⛔ 不经过元素表 ⇒ 不受 OCR 词表/阈值影响。
            if Self.looksLikeAdPage(img, rec: rec, nav: nav, bw: baseW, bh: baseH) {
                // ⛔⛔⛔ §2277 **绝不能只"傻等"**（我 v0.10.35 的错：用户令「**能等个屁**」）
                //
                // 真机 `_var/_stuck1.png`：屏幕上明摆着奖励面板
                // **`6s后可领取399金币 / 再看6秒可得399金币 / [继续观看]`**，
                // 而**倒计时不会自己走**（面板要用户点「继续观看」才补全）
                // ⇒ "等 30 秒"等的是**永远不会自己结束**的面板 ⇒ 卡死。
                //
                // ✅ 正解 = 照 PC `_ad_finish` **主动推进状态**：
                //    先点面板按钮（补全）→ 面板没了才点胶囊 ✕
                if finishAdPanel(img, tag: "adbox_ad\(n + 1)") {
                    sleep(1.5)
                    continue        // ⭐ 处理了一层 ⇒ 重抓帧再判（⛔ 不在这儿 sleep 30s）
                }
                // 面板与 ✕ 都没有 ⇒ 这才是"纯广告播放中" ⇒ **等时间**（⛔ 不点 ✕）
                log("§adbox ⛔ 广告播放中（无面板/无关闭键）⇒ 等够 \(Int(dwell))s（⛔ 不点 ✕）")
                var left = dwell
                while left > 0 {
                    if isCancelled() { break }
                    let d = min(2.0, left)
                    Thread.sleep(forTimeInterval: d)
                    left -= d
                    // ⭐ 等待期间**持续看有没有面板冒出来**（面板会在倒计时中途出现）
                    if let im2 = grab(), finishAdPanel(im2, tag: "adbox_adw\(n + 1)") {
                        log("   §adbox 等待中面板出现 ⇒ 已处理")
                        break
                    }
                }
                n += 1
                _ = ensureInCenter(tag: "adbox_back\(n)")
                continue
            }

            // ④ 认不出 ⇒ 交给漏斗（弹窗优先），不自杀
            if nav.runFunnel(img) {
                log("§adbox 漏斗处理了一层")
                sleep(1.0)
                continue
            }
            log("§adbox ⚠️ 找不到广告任务按钮（第 \(n + 1)/\(count) 条）⇒ 回中心再找")
            if !ensureInCenter(tag: "adbox_re\(n)") {
                log("§adbox ⛔ 也回不了中心 ⇒ 停手")
                break
            }
            // ⭐ 防死循环：连续 3 轮都找不到 ⇒ 收（照 PC `stuck` 语义）
            emptyRounds += 1
            if emptyRounds >= 3 {
                log("§adbox ⛔ 连续 \(emptyRounds) 轮找不到广告任务 ⇒ 收手")
                break
            }
            n += 1
        }
        log("§adbox 跑完 \(n) 条")
        return n > 0
    }

    // MARK: - ⭐⭐⭐ 广告页拦阻（照 PC `is_ad_page`，⛔ 独立于页型表）

    /// ⭐⭐⭐ 是不是**视频广告页** —— 照 PC `is_ad_page`（`_1377_ad_loop.py:3609`）**逐字**。
    ///
    /// ```python
    /// def is_ad_page(img):
    ///     t = txt(img, BOX_TOP)          # BOX_TOP = (0, 62, 451, 140)
    ///     return ("可领取" in t) or ("已成功领取" in t)
    /// ```
    ///
    /// ## ⛔ 为什么必须**独立于 `elements` 表**（这是本轮血案的根因）
    /// 页型 `ad_video` 走 `elements` 表（`ad_capsule`）⇒ 那套是 **OCR 词匹配 + ROI**；
    /// 而真机胶囊是 **`已成功领取438金币 ×`**（带数字/带 ✕）⇒ **读不出** ⇒ 页型 `unknown`
    /// ⇒ 「广告页放行」失效 ⇒ **漏斗把广告 ✕ 点了**（用户令：
    /// 「**时间都没到就提前点击了X**」）。
    /// ✅ PC 的这条判据是**对顶栏原文做子串判断**（`in`），**不经过元素表**
    ///   ⇒ ⛔ 不受 OCR 词表/阈值影响 ⇒ 更稳。
    ///
    /// ## 职责划分（PC L2697 逐字）
    /// > ⭐ 职责划分：广告页归**广告模块（adbox）**；导航只处理非广告页。
    ///
    /// ## ⭐⭐ §2276 **多级判据**（真机又逮到「奖励面板盖屏」这一态）
    /// 真机 `_var/_ad2_n.png` 铁证：奖励面板盖在广告上时，
    /// 顶栏仍写着 **`1s后可领取560金币`** ⇒ 只剩 1 秒，**更要放行**（⛔ 不能点 ✕）。
    /// ⚠️ 这种帧上顶栏**带数字**（`后`/`秒`），PC 那三个词可能读不到 ⇒ 必须补更宽的兜底：
    /// ```
    ///   ① PC 原判据：顶栏含「可领取」/「已成功领取」     ← 最准，先试
    ///   ② 兜底：顶栏含「秒」且含「金币」                 ← 倒计时胶囊形态
    ///   ③ 兜底：`pill_x` 模板命中（胶囊 ✕ 是广告页专属） ← 纯像素，⛔ 不受 OCR 影响
    /// ```
    /// ⛔ 三级**都是"广告页独有"的信号**，⛔ 不是放宽（快手内容页没有胶囊 ✕）。
    static func looksLikeAdPage(_ img: UIImage, rec: Recognizer, nav: Navigator,
                               bw: Double, bh: Double) -> Bool {
        // ① PC 原判据（顶栏原文子串，⛔ 不靠元素匹配）
        let items = rec.ocrRegion(img, rect: CGRect(x: 0, y: 62, width: bw, height: 78),
                                  minConfidence: 0.3)
        let t = items.map(\.0).joined()
        if t.contains("可领取") || t.contains("已成功领取") { return true }
        // ② 兜底：倒计时胶囊形态（`Ns后可领取N金币`）
        if t.contains("秒") && t.contains("金币") { return true }
        // ③ 兜底：胶囊 ✕ 模板（纯像素；`ad/pill_x.png`）
        if nav.detect("pill_x", img: img) != nil { return true }
        return false
    }

    /// ⭐⭐⭐⭐⭐ §2277 **收尾**：处理广告页的面板/弹窗 —— 照 PC `_ad_finish` 腿序
    ///
    /// ## ⛔⛔ 我上一版（v0.10.35）在这里犯的错：**只"傻等"，没处理面板**
    /// 我写成：
    /// ```swift
    /// log("放行待够 \(dwell)s"); dwellOnAd(dwell)     // ⛔ 只是 sleep
    /// ```
    /// 而真机 `_var/_stuck1.png` 铁证：屏幕上明摆着
    /// **`6s后可领取399金币 / 再看6秒可得399金币 / [继续观看]`** 面板，
    /// **倒计时根本不会自己走**（面板在等用户点「继续观看」才能补全）
    /// ⇒ 我"等 30 秒"等的是一个**永远不会自己结束**的面板
    /// ⇒ 表面日志在刷"放行待够30s"，实则**卡死不动**（用户原话：「**能等个屁**」）。
    ///
    /// ## ✅ PC 的正解：`_ad_finish(tag)`（`_1377_ad_loop.py:4849`）**腿序**
    /// ```python
    /// ① click_stay_panel(img)   # 「继续观看/再看N秒」⇒ **点它补全**（让倒计时走完）
    /// ② _find_panel_x(img)      # ⭐ **面板自己右上角的小 ✕**（ROI 330,352,382,406）
    /// ③ click_toast_x(img)      # 顶栏 toast ✕（⛔ 只在**没有面板**时才轮到它）
    /// ④ 「真的要离开吗」⇒ 点消极项「离开」
    /// ⑤ 「放弃奖励/以后再说」⇒ 点消极项
    /// ```
    ///
    /// ## ⚠️ PC 的两条**腿序血案**（必须照抄，⛔ 顺序不能改）
    /// > ⛔ 旧代码只点**顶栏 toast ✕** —— 顶栏那个 ✕ **关不掉这张卡片**
    /// >   ⇒ 页面**一动不动** ⇒ 交接/收尾/goto_feed 反复"在广告页 ⇒ 收尾 ⇒ 还在广告页"
    /// >   **空转到停手**（用户看到的"突然停止"就是它）。
    /// > ⛔ **面板自己的 ✕ 必须排在 toast ✕ 之前** —— 面板在时，先关面板才是正解。
    /// 📏 这正是我 v0.10.35 的翻版（我是"只等"，PC 是"只点toast"），**同一个病**：
    ///    ⛔ 没做"**在广告页上主动推进状态**"这件事。
    ///
    /// - Returns: true = 已点掉一层（调用方应重抓帧再判）
    private func finishAdPanel(_ img: UIImage, tag: String) -> Bool {
        // ① 挽留面板「继续观看 / 再看N秒」⇒ **点它补全**
        //    （`stay_panel_btn` 的词表 = PC `PANEL_KEYS`：领取奖励/继续观看/…）
        if nav.detect("stay_panel_title", img: img) != nil,
           nav.detect("stay_panel_btn", img: img) != nil {
            log("   §\(tag) 挽留面板 ⇒ 点「继续观看/领取奖励」**补全**（照 PC `click_stay_panel`）")
            _ = nav.tap("stay_panel_btn", img: img, atomic: true)
            return true
        }
        // ② ⭐ **面板自己右上角的小 ✕**（⛔ 必须排在 toast ✕ 之前 —— PC 腿序血案）
        if nav.detect("panel_close_x", img: img) != nil {
            log("   §\(tag) 面板右上小 ✕ ⇒ 点它（照 PC `_find_panel_x`）")
            _ = nav.tap("panel_close_x", img: img, atomic: true)
            return true
        }
        // ③ 顶栏 toast ✕（⚠️ 只在**没有面板**时才轮到这里）
        if nav.detect("pill_x", img: img) != nil {
            log("   §\(tag) 顶栏胶囊 ✕（面板已不在）⇒ 点它")
            _ = nav.tap("pill_x", img: img, atomic: true)
            return true
        }
        return false
    }

    /// ⭐ 读**顶栏原文**（广告胶囊那一带）—— PC `txt(img, BOX_TOP)` 的等价物
    ///
    /// PC `BOX_TOP = (0, 62, 451, 140)`；所有广告判据都基于它：
    ///   · `is_ad_page`  = `("可领取" in t) or ("已成功领取" in t)`
    ///   · 到账闸        = 还有没有 `\d+秒 / \d+s`
    /// ⇒ 手机端统一用本函数取原文，⛔ 不各写一份（⛔ 免得判据漂移）。
    static func adTopText(_ img: UIImage, rec: Recognizer,
                          bw: Double, bh: Double) -> String {
        rec.ocrRegion(img, rect: CGRect(x: 0, y: 62, width: bw, height: 78),
                      minConfidence: 0.3)
            .map(\.0).joined()
    }

    /// ⭐⭐⭐ 倒计时**还在走**吗 —— 照 PC 的「到账闸」（`_1377_ad_loop.py:4342`）**逐字**。
    ///
    /// ## PC 原文
    /// > ✅ 抗错字写法：**顶栏只要还有 `\d+秒 / \d+s`** ⇒ 倒计时没走完 ⇒ **不点 X**。
    /// > ⛔⛔ §1545 真机血案（`_var/_1544_fuli_round.log`）：倒计时**早就走完了**，
    /// >   但 OCR 没读到「已成功领取」四个字。
    /// >   ⇒ 若**只认那四个字**当"到账"，就会**永远不敢点** ✕ ⇒ 卡在广告页出不去。
    /// >   ✅ 所以判据必须是「**还有没有倒计时数字**」，⛔ 不是"有没有到账字样"。
    ///
    /// ## ⛔⛔ 为什么不能用「已成功领取」当判据（我上一版的错）
    /// 用户令：「**倒计时是广告没结束 你没结束去点 不是傻逼。广告结束了你不点了。**」
    /// ⇒ 判据只有一条：**顶栏还有 `N秒`/`Ns` ⇒ 广告没结束 ⇒ ⛔ 一个键都不许点。**
    ///
    /// - Returns: true = **倒计时还在走**（广告没结束 ⇒ 只等，⛔ 不点）
    static func adCountdownRunning(_ img: UIImage, rec: Recognizer,
                                  bw: Double, bh: Double) -> Bool {
        let items = rec.ocrRegion(img, rect: CGRect(x: 0, y: 62, width: bw, height: 78),
                                  minConfidence: 0.3)
        let t = items.map(\.0).joined().replacingOccurrences(of: " ", with: "")
        // PC 正则 `\d+秒` / `\d+s`（含 `后` 的写法也一并覆盖）
        if let re = try? NSRegularExpression(pattern: "[0-9]+\\s*(秒|s|S)") {
            let r = NSRange(t.startIndex..<t.endIndex, in: t)
            return re.firstMatch(in: t, range: r) != nil
        }
        return t.contains("秒")
    }

    /// PC `AD_ROW_Y_WIN = 26` —— 行内 y 容差（同一张卡片的标题与按钮落在此窗口内）
    private static let adRowYWin: Double = 26
    /// PC `AD_ROW_X_MIN = 330` —— 右列按钮 x 下界
    private static let adRowXMin: Double = 330
    /// PC `AD_ROW_TASK_RX = r"看\s*广\s*告\s*得\s*金\s*币"` —— **唯一**合法目标行
    ///
    /// ⛔ 用 `\s*` 容忍 OCR 把「看广告得金币」切成多个 token（`看广告 得金币` 也算命中）。
    private static let adRowTaskWords = ["看广告得金币", "看广告 得金币", "看广告赚金币"]
    /// PC `AD_ROW_DEAD_KEYS` —— 右列按钮的**非动作态**词表；命中 ⇒ 本腿放弃
    ///
    /// PC 原文：「可用态永远是祈使（`领福利`/`去观看`/…），
    /// `冷却中`/`倒计时…`/`已领取`/`已完成` 都是**状态**（按了不会有任何事）」。
    private static let adRowDeadKeys = ["冷却中", "倒计时", "已领取", "已领完",
                                        "已完成", "已抢光", "明日再来", "已瓜分"]

    /// ⭐⭐⭐ 按**行结构**定位「看广告得金币」那道任务行右侧的入口按钮。
    ///
    /// 逐条移植 PC `find_ad_row_button`（`_1377_ad_loop.py:2146`）。
    /// - Returns: `(点, 证据串)`；⛔ 找不到 / 该行不可用 ⇒ **nil**（调用方什么都不做）
    private func findAdRowButton(_ img: UIImage)
        -> (point: CGPoint, evidence: String)? {
        // ① 先 OCR 出任务列表那一带的词（PC: `words(img, (0, 250, 451, 977))`）
        let band = CGRect(x: 0, y: 250, width: baseW, height: baseH - 250)
        let ws = rec.ocrRegion(img, rect: band, minConfidence: 0.3)
        guard !ws.isEmpty else {
            log("   §adbox_row ⚠️ 任务列表带内没读到任何文字 ⇒ 本腿放弃")
            return nil
        }
        // ② 按 y 聚成「行」—— 任务列表的结构就是 [标题 + 金币数 + 右侧按钮]
        let rows = Self.ocrRows(ws, yWin: Self.adRowYWin)
        // ③ 找「看广告得金币」那道行（⛔ 唯一目标；找不到 ⇒ 放弃本腿）
        guard let yRow = Self.taskRowY(rows, words: Self.adRowTaskWords) else {
            log("   §adbox_row ⚠️ 本屏没有「看广告得金币」这道任务行 ⇒ 本腿放弃"
                + "（§1703：⛔ 不得改点同屏别的广告任务行）")
            return nil
        }
        // ④ 取**该行** ±26 内、x ≥ 330 的词 → 最右那个当按钮
        var cands: [(String, CGPoint)] = []
        for r in rows where abs(r.y - yRow) <= Self.adRowYWin {
            for w in r.items where w.center.x >= Self.adRowXMin {
                cands.append((w.text, w.center))
            }
        }
        guard !cands.isEmpty else {
            log("   §adbox_row ⚠️ 「看广告得金币」行 y=\(Int(yRow)) 里 x≥\(Int(Self.adRowXMin))"
                + " 没有按钮 ⇒ 本腿放弃")
            return nil
        }
        // PC: `cands.sort(key=lambda c: (-c[1], abs(c[2] - y_row)))` ⇒ 最右优先
        cands.sort { a, b in
            if a.1.x != b.1.x { return a.1.x > b.1.x }
            return abs(a.1.y - yRow) < abs(b.1.y - yRow)
        }
        let (bt, pt) = cands[0]
        // ⑤ ⛔ 非动作态（冷却中/已领取…）⇒ **放弃本腿**（⛔ 不许改点别的行）
        if Self.adRowDeadKeys.contains(where: { bt.contains($0) }) {
            log("   §adbox_row ⏭ 「看广告得金币」行按钮是「\(bt)」（**非动作态**）⇒ 本腿放弃"
                + "（§1703：⛔ 不得改点同屏别的广告任务行）")
            return nil
        }
        let title = rows.filter { abs($0.y - yRow) <= Self.adRowYWin }
                        .flatMap { $0.items.map(\.text) }.joined(separator: " ")
        return (pt, "\(bt) ｜行「\(title.prefix(30))」")
    }

    /// 把 OCR 词按 y 聚成「行」（照 PC `_ocr_rows`）
    private struct OcrRow { var y: Double; var items: [(text: String, center: CGPoint)] }

    private static func ocrRows(_ ws: [(String, CGRect, Double)],
                               yWin: Double) -> [OcrRow] {
        var rows: [OcrRow] = []
        for (t, r, _c) in ws.sorted(by: { $0.1.midY < $1.1.midY }) {
            let cy = Double(r.midY)
            if let i = rows.firstIndex(where: { abs($0.y - cy) <= yWin }) {
                rows[i].items.append((t, CGPoint(x: r.midX, y: r.midY)))
                rows[i].y = rows[i].items.map { Double($0.center.y) }.reduce(0, +)
                            / Double(rows[i].items.count)
            } else {
                rows.append(OcrRow(y: cy, items: [(t, CGPoint(x: r.midX, y: r.midY))]))
            }
        }
        return rows
    }

    /// 本屏「**看广告得金币**」那道任务行的行心 y（找不到 ⇒ nil）
    ///
    /// ⛔ PC 原文：「这是**唯一**合法目标行：同屏的 `刷广告视频赚金币` 是**另一个任务**」。
    private static func taskRowY(_ rows: [OcrRow], words: [String]) -> Double? {
        let hits = rows.filter { r in
            let joined = r.items.map(\.text).joined(separator: " ")
            return words.contains { joined.contains($0) }
        }
        // 正常只有一条；万一多条，取**最上面**那条（照 PC `hits.sort(key=lambda r: r[0])`）
        return hits.min(by: { $0.y < $1.y })?.y
    }

    /// ⭐⭐ **等到一张"新的"帧**（与 `ref` 不同）⇒ 返回它；等不到 ⇒ nil
    ///
    /// ## 为什么必须有它（§2265 —— 与写盘节拍成对的一条）
    /// 为活过 iOS 的磁盘写入预算，扩展写盘节拍 = **1帧/4s**（见 `SampleHandler.fps`）。
    /// ⇒ 任何「**做动作 → 睡 1~2 秒 → 抓帧看结果**」的旧写法都会拿到
    ///   **动作之前那张帧** ⇒ 判据恒 false ⇒ 表现为
    ///   「点了任务但没进广告页 ⇒ 重试」/**每条腿都被记死**。
    /// 📏 教训：**节拍变了，所有"睡一会儿再抓帧"的地方都要改成"等新帧"**。
    ///
    /// - Parameters:
    ///   - ref: 动作**之前**那张帧（比它不同即算新）
    ///   - maxWait: 最多等多久（默认 = 帧龄上限 + 3s，即至少能覆盖一个写盘周期）
    private func grabFresh(since ref: UIImage, maxWait: Double) -> UIImage? {
        let deadline = Date().addingTimeInterval(max(1.5, maxWait))
        var last: UIImage?
        while Date() < deadline {
            if isCancelled() { return nil }
            Thread.sleep(forTimeInterval: 0.5)
            guard let p = grab() else { continue }
            last = p
            if nav.screenChanged(ref, p) { return p }
        }
        // ⛔ 画面真没变 ⇒ 返回最后一张（让调用方按"没变"处理，结论仍正确）
        return last
    }

    /// ⭐ 广告页**待够时间**（⛔ 绝不点 ✕ —— 用户令 + 荔枝 40/60 秒）
    private func dwellOnAd(_ seconds: Double) {
        var left = seconds
        while left > 0 {
            if isCancelled() { return }
            let d = min(0.5, left)
            Thread.sleep(forTimeInterval: d)
            left -= d
            let prog = 1.0 - (left / max(seconds, 0.001))
            beat(["phase": "ad-dwell", "progress": prog])
        }
    }

    // MARK: - ② feed 刷视频（照 PC `run_feed` L5078）

    /// ⭐ 高价值 ⇒ **完播停留**；低价值 ⇒ **直接划走**；直播间 ⇒ **立即划走**。
    private func runFeed() -> Bool {
        let minutes = featMinutes("feed", dflt: 12)
        let stayHV = s?.feed_stay_hv ?? 22          // PC `STAY_HV`
        let stayLV = s?.feed_stay_lv ?? 3           // PC `STAY_LV`
        let gapMin = s?.feed_gap_min ?? 1.0
        let gapMax = s?.feed_gap_max ?? 2.0
        log("§feed 目标 \(String(format: "%.1f", minutes)) 分钟 ｜ 高价值停留 \(Int(stayHV))s / 低价值划走")
        log("§feed ⛔ 不做点赞/评论/关注（§1505 口径）")

        // ⭐ 进信息流（PC `goto_feed`；进不去 ⇒ 停手，⛔ 不放枪）
        guard gotoFeed(tag: "feed_in") else {
            log("§feed ⛔ 进不了信息流 ⇒ 停手")
            return false
        }

        let end = Date().addingTimeInterval(minutes * 60)
        var n = 0, hits = 0
        while Date() < end {
            if isCancelled() { log("§feed ⛔ 被中断"); break }
            guard let img = grab() else { log("§feed ⛔ 抓帧失败"); break }
            n += 1
            beat(["phase": "feed-step", "n": n, "hits": hits,
                  "left_s": Int(end.timeIntervalSinceNow)])

            // ⭐ ① 先关评论区（PC L5131：否则滑动无效、文案读错区）
            //
            // ⛔⛔ §2259 修一个真 bug（两处）：
            //   ① 判据原来与 `live_marker` **逐字相同**（都是底部「说点什么」）
            //      ⇒ 两个元素**恒同时命中** ⇒ 没有区分度。现已改成 PC 的
            //      `comment_panel` 判据 = **面板里的「N条评论」**（PC L4459）。
            //   ② **关法是坐标动作，不是"找到按钮再点"**：`nav.tap("comment_close")`
            //      原来指向一个**根本不存在**的元素 ⇒ `detect()` 直接 nil ⇒ **恒 false**
            //      ⇒ 评论区**从来没被关掉过**。
            //   ✅ 照 PC `close_comment_panel`（L4454）的实测最优关法：
            //      「**点上半屏视频区 (225,150)** diff **118.62** ✅ —— 半屏面板点外部即关」
            //      （另两种：左缘侧滑 0.89 ❌ / SWIPE_DOWN 1.80 ❌，PC 已否决）
            //   ⚠️ PC 明确这**不是盲点固定锚**：它点的不是某个按钮，而是"面板外部"这一
            //      通用位置，且**有前置条件**（只在 `comment_panel` 命中时才发）。
            if nav.detect("comment_panel", img: img) != nil {
                log("§feed 检测到评论区面板 ⇒ 点上半屏关掉（PC `close_comment_panel`）")
                nav.tapPoint(225, 150)
                sleep(1.8)
            }
            guard let img2 = grab() else { break }

            // ⭐ ② 直播间 ⇒ **立即划走**（PC L5138；⛔ 必须在关评论区**之后**判）
            if nav.detect("live_marker", img: img2) != nil {
                log("§feed 第\(n)条 **直播间** ⇒ 立即划走（0 停留 / 0 互动）")
                swipeUp(gapMin, gapMax)
                continue
            }

            // ⭐ ③ 高价值 ⇒ 完播停留；低价值 ⇒ 直接划走（§1733 用户令）
            let hv = nav.detect("hv_marker", img: img2) != nil
            if hv {
                hits += 1
                log("§feed 第\(n)条 **高价值** ⇒ 完播停留 \(Int(stayHV))s（命中 \(hits)）")
                sleepWithCancel(stayHV)
            } else {
                log("§feed 第\(n)条 低价值 ⇒ 直接划走")
                sleepWithCancel(stayLV)
            }
            swipeUp(gapMin, gapMax)
        }
        log("§feed 刷了 \(n) 条（高价值命中 \(hits)）")
        return n > 0
    }

    // MARK: - ③ tag 搜索打标签（照 PC `run_tag` L6842）

    /// ⭐ 开搜索页 → 取词 → **落中文** → 搜索 → 浏览结果 → 换词。
    private func runTag() -> Bool {
        let minutes = featMinutes("tag", dflt: 5)
        let roundMin = (s?.tag_round_min ?? 0) > 0
            ? (s?.tag_round_min ?? 0) : max(1.0, minutes / 3.0)
        let words = s?.tag_words ?? []
        log("§tag 目标 \(String(format: "%.1f", minutes)) 分钟 ｜ 每轮预算 \(String(format: "%.1f", roundMin)) 分钟 ｜ 词池 \(words.count) 词")
        log("§tag ⛔ 只搜 APP下载/游戏下载；⛔ 不点 CTA、不碰危险词")

        // ⭐ 入口：**先问搜索页（可重入，1 次抓帧零动作）**，不成才走 feed 重链
        //    （PC §1737c 血案：先走 goto_feed ⇒ 4 轮全废）
        var opened = openSearch(tag: "tag_open")
        if !opened {
            log("§tag ⚠️ 直接开搜索没成 ⇒ 先回 feed 首页再试")
            if ensureEntryState(want: "feed", tag: "tag_ent") {
                opened = openSearch(tag: "tag_open2")
            }
        }
        guard opened else {
            log("§tag ⛔ 打不开搜索页 ⇒ 停手")
            return false
        }

        let end = Date().addingTimeInterval(minutes * 60)
        var rounds = 0, used: [String] = []
        while Date() < end {
            if isCancelled() { log("§tag ⛔ 被中断"); break }
            // ⛔ 不连着搜同一个词（PC 看最近 6 个）
            guard let word = pickWord(words, used: used, recent: 6) else {
                log("§tag 词池用尽 ⇒ 结束")
                break
            }
            used.append(word)
            rounds += 1
            beat(["phase": "tag-round", "round": rounds, "word": word])
            log("§tag ── 第 \(rounds) 轮：搜「\(word)」")

            let roundEnd = min(end, Date().addingTimeInterval(roundMin * 60))
            if !searchOneWord(word, tag: "tag\(rounds)") {
                log("§tag ⚠️ 第 \(rounds) 轮搜索没成 ⇒ 换词继续")
                continue
            }
            browseResults(until: roundEnd, tag: "tag\(rounds)")
        }
        // ⭐ 到时 ⇒ 退回 feed 首页（PC：各腿靠「回首页」接力）
        _ = gotoFeed(tag: "tag_out")
        log("§tag 跑了 \(rounds) 轮，用过 \(used.count) 个词")
        return rounds > 0
    }

    // MARK: - ④ search 商城逛小店（照 PC `run_mall` L7609）

    /// ⭐ 进小店 → 搜高价值商品词 → **只点 ≥ 门槛价**的商品 → 拟人停留。
    private func runMall() -> Bool {
        let minutes = featMinutes("search", dflt: 5)
        let roundMin = (s?.mall_round_min ?? 0) > 0
            ? (s?.mall_round_min ?? 0) : max(1.0, minutes / 3.0)
        let browseMin = s?.mall_browse_min ?? 0.4
        let minPrice = s?.mall_min_price ?? 500
        let words = s?.mall_words ?? []
        log("§mall 目标 \(String(format: "%.1f", minutes)) 分钟 ｜ 每轮 \(String(format: "%.1f", roundMin)) 分钟 ｜ 门槛 ¥\(Int(minPrice)) ｜ 词池 \(words.count)")
        log("§mall ⛔ 不点购买键、不点赞/评论/关注")

        // ⭐ 先进「已知入口态」（PC L7628 血案：否则 enter_mall 会瞎退 6 跳）
        if !ensureEntryState(want: "feed", tag: "mall_ent") {
            log("§mall ⚠️ 没到 feed 首页 ⇒ 仍试一次进小店（它可重入）")
        }
        guard enterMall(tag: "mall_in") else {
            log("§mall ⛔ 进不了小店首页 ⇒ 停手")
            return false
        }

        let end = Date().addingTimeInterval(minutes * 60)
        var rounds = 0, used: [String] = []
        while Date() < end {
            if isCancelled() { log("§mall ⛔ 被中断"); break }
            // ⭐ 浏览要留**时间下限**（PC L7664：进商城→打字→落中文→搜索本身 ~0.7 分钟）
            let leftMin = end.timeIntervalSinceNow / 60.0
            if leftMin < browseMin {
                log("§mall ⏱ 剩 \(String(format: "%.1f", leftMin)) 分钟 < 浏览下限 \(String(format: "%.1f", browseMin)) ⇒ 不再开新轮")
                break
            }
            guard let word = pickWord(words, used: used, recent: 6) else {
                log("§mall 词池用尽 ⇒ 结束")
                break
            }
            used.append(word)
            rounds += 1
            beat(["phase": "mall-round", "round": rounds, "word": word])
            log("§mall ── 第 \(rounds) 轮：搜「\(word)」")

            let roundEnd = min(end, Date().addingTimeInterval(roundMin * 60))
            if !searchOneWord(word, tag: "mall\(rounds)") {
                log("§mall ⚠️ 第 \(rounds) 轮搜索没成 ⇒ 换词继续")
                continue
            }
            // ⭐ 结果页**只点 ≥ 门槛价**的商品
            _ = minPrice
            browseResults(until: roundEnd, tag: "mall\(rounds)")
        }
        _ = gotoFeed(tag: "mall_out")
        log("§mall 跑了 \(rounds) 轮，用过 \(used.count) 个词")
        return rounds > 0
    }

    // MARK: - ⭐⭐ 共用腿（导航/搜索/浏览/滑动）

    /// ⭐ 回任务中心（= PC `ensure_in_center`）
    private func ensureInCenter(tag: String) -> Bool {
        guard let cfg = cfgStore.cfg else { return false }
        // ⛔⛔ §2259 **每次调用都要清空"记死"表**（照 PC `_nav_to_center` L2688 `_dead = set()`）。
        //
        // ## 为什么这是必须的（否则"唯一的路"会被一次误判永久封死）
        // Swift 的 `Navigator.dead` 是**对象级**状态，而 `resetDead()` **从来没有被调用过**
        // （真机实测：全项目只有定义、没有调用点）。
        // ⇒ 后果：「记死」是**跨整轮、永久**的：
        //   只要 `coin_ball` 在**某一帧**上没找到球（很常见 —— 转场中/球被遮挡/加载中），
        //   它就被 `markDead("feed|coin_ball")` ⇒ **之后所有帧都不再试它**
        //   ⇒ 而 `coin_ball` 是**回金币中心的唯一入口** ⇒ **整轮再也回不去中心**。
        //
        // 📏 PC 的口径正好相反（`_1377_ad_loop.py:2688`）：
        // ```python
        // def _nav_to_center(img, tag="NAV", steps=8):
        //     _dead = set()          # ← 每次调用都重开一张记死表
        // ```
        // ⇒ 「记死」的语义是**本轮这张表内**有效（防止在**同一帧**上反复空点同一条腿），
        //    ⛔ 不是"这条腿永远不许用"。
        nav.resetDead()
        // ⭐ §2287 未知页补救计数（照 PC `UNK[0]`，最多 2 次）
        var unknownRetry = 0
        for k in 0..<8 {
            if isCancelled() { return false }
            guard let img = grab() else { return false }
            let here = nav.pageHere(img) ?? "unknown"
            if here == (cfg.settings?.target ?? "center") {
                log("   §\(tag) ✅ 已在任务中心（第 \(k + 1) 步）")
                return true
            }
            // ⛔⛔⛔ **广告页必须最先放行** —— 用**独立判据**拦一道，照 PC `_nav_to_center` L2698
            //
            // ## ⛔ 血案（用户令）：「**时间都没到就提前点击了X**」
            // 我原来**先判页型、后跑漏斗**，而页型判不出广告页时
            // ⇒ **漏斗的 `pill_x` 就把正在看的广告关掉了** ⇒ 奖励没拿够。
            // 📏 PC 的防线（L2694~L2700 逐字）：
            // ```python
            // if is_ad_page(img):            # ⭐ 在跑漏斗**之前**拦
            //     return False               # 放行，⛔ 漏斗和任何腿都不许碰
            // ```
            // > ⛔ 我原来给 `ad_video` 配了 `go="pill_x"` ⇒ 导航把广告点掉了
            // > ⭐ 职责划分：广告页归**广告模块（adbox）**；导航只处理非广告页。
            //
            // ## 判据必须**独立于页型表**（这是关键）
            // PC `is_ad_page`（L3609）用的是**子串包含**：
            // ```python
            // return ("可领取" in t) or ("已成功领取" in t)
            // ```
            // ⛔ 而我的 `ad_capsule` 走 OCR 元素匹配 ⇒ 真机 `已成功领取438金币 ×`
            //   **读不出** ⇒ 页型 `unknown` ⇒ 防线失效 ⇒ 点✕。
            // ✅ 所以这里**直接对顶栏做子串判断**，⛔ 不经过元素表。
            if Self.looksLikeAdPage(img, rec: rec, nav: nav, bw: baseW, bh: baseH) {
                log("   §\(tag) ⛔ 这是**视频广告页**（顶栏含「可领取/已成功领取」）"
                    + " ⇒ **放行**（⛔ 不碰，交给广告模块；⛔ 绝不点 ✕）")
                return true
            }
            // ⭐⭐⭐⭐⭐ §2275 **漏斗排在"前进一跳"之前**（照 PC `_nav_to_center` L2705）
            // PC 原文：「**恢复漏斗提到导航之前**（弹窗盖屏 ⇒ 底下什么都点不到）」
            //   「Popups appear at page_os … so must take precedence」
            //
            // ## 真机血案（v0.10.32 trace）
            // 手机停在**奖励面板**上（「再看5秒可得451金币 / 继续观看」）：
            // ```
            //   §adbox_boot 在 unknown 找不到回中心的路（第 1..7 步）
            //   §adbox ⛔ 回不到金币中心 ⇒ 停手
            // ```
            // ⛔ 而同一段日志后半段**证明 `stay_panel_btn` 能点掉它**——
            //   只是它属于漏斗，而这里原来**先判页型、后跑漏斗**
            //   ⇒ 面板盖屏时页型 = `unknown` ⇒ 直接掉进"找不到路"⇒ **漏斗根本没轮到**。
            // ✅ 现在漏斗前置：面板/弹窗**先清掉**，下一轮再判页型。
            if nav.runFunnel(img) {
                log("   §\(tag) 漏斗处理了一层（弹窗优先，照 PC §1773d）")
                sleep(1.0)
                continue
            }
            // ⭐⭐⭐⭐⭐ §2287 **判未知 ⇒ 最多重判 2 次，⛔ 不空转 8 步**（用户令）
            //
            // ## 用户原话（逐字，这条就是本段的规格）
            // > 「**老子都是页面识别锚点的，不会像你傻逼一样写的狗屎。
            // >   找不到就停止 判未知就停止。我基本所有页面都做了锚点识别**」
            //
            // ## ⛔ 我的病（真机 trace 铁证）
            // ```
            //   §adbox_boot ⚠️ 在 unknown 找不到回中心的路（第 1 步）
            //   …（一路到第 8 步）
            //   §adbox ⛔ 回不到金币中心 ⇒ 停手
            // ```
            // ⇒ **固定 8 步、每步 sleep(1)** ⇒ 白烧 ~10 秒，日志还刷 8 行噪声。
            //
            // ## ✅ 照 PC 的「未知页补救」（`_1377_ad_loop.py:10139` C0 分支）
            // ```python
            // if (UNK[0] < 2) and ...:        # ⭐ 最多补救 2 次
            //     UNK[0] += 1
            //     # 第 1 次：只等 2.5s 重判（页面可能只是**还没画完**）
            //     # 第 2 次：才试「〈」返回腿（先找到再点，⛔ 找不到不点）
            //     wait(2.5); continue
            // # 补救用完 ⇒ 走统一腿序（maxstep=6）⇒ 失败才**停手**
            // ```
            // 📏 PC 的原始意图（注释逐字）：
            // > 「同一条广告内最多重判 2 次（每次先看状态栏面包屑，再等 2.5s 重来）。
            // >  ⛔ 一旦某条广告完成（done_ads 变了）计数自动归零 ⇒ 结构上不可能无限打转。」
            //
            // ⇒ 手机端现在：**未知 ⇒ 第 1 次只等 2.5s 重判；第 2 次试返回腿；
            //    再认不出就停手**（⛔ 不再固定 8 步空转）。
            if here == "unknown" {
                if unknownRetry < 2 {
                    unknownRetry += 1
                    if unknownRetry >= 2 {
                        // ⭐ 第 2 次补救才试返回腿（照 PC：第 1 次仍"只等"，页面可能没画完）
                        if nav.detect("back_arrow", img: img) != nil {
                            log("   §\(tag) 未知页补救第 2 次 ⇒ 试「〈」返回腿")
                            _ = nav.tap("back_arrow", img: img, atomic: true)
                        } else if nav.detect("white_chevron", img: img) != nil {
                            log("   §\(tag) 未知页补救第 2 次 ⇒ 试「白色〈」返回腿")
                            _ = nav.tap("white_chevron", img: img, atomic: true)
                        } else {
                            log("   §\(tag) 未知页补救第 2 次 ⇒ 既无〈也无白勾，**不点任何东西**（铁律①）")
                        }
                    } else {
                        log("   §\(tag) 未知页补救第 \(unknownRetry)/2 次 ⇒ 只等 2.5s 重判（页面可能没画完）")
                    }
                    sleep(2.5)
                    continue
                }
                log("   §\(tag) ⛔ 未知页补救 \(unknownRetry) 次仍认不出 ⇒ **停手**（照 PC C0）")
                return false
            }
            let r = nav.step(from: here, img: img) { [weak self] in self?.grab() }
            if r.acted { sleep(1.0); continue }
            // ⭐ 已知页型、但出路全被记死 ⇒ **停手**（照 PC：⛔ 不空转）
            log("   §\(tag) ⛔ 在 \(here) 的出路全试过且无效 ⇒ **停手**（⛔ 不空转）")
            return false
        }
        return false
    }

    /// ⭐ 送到某个已知入口态（= PC `_ensure_entry_state(want:)`）
    private func ensureEntryState(want: String, tag: String) -> Bool {
        for k in 0..<3 {
            if isCancelled() { return false }
            guard let img = grab() else { return false }
            let here = nav.pageHere(img) ?? "unknown"
            if here == want {
                log("   §\(tag) ✅ 已在 \(want)（第 \(k + 1) 次）")
                return true
            }
            if nav.runFunnel(img) { sleep(1.0); continue }
            _ = ensureInCenter(tag: "\(tag)_via_center")
            sleep(0.8)
        }
        return false
    }

    /// ⭐ 进信息流（= PC `goto_feed`）
    private func gotoFeed(tag: String) -> Bool {
        for _ in 0..<3 {
            if isCancelled() { return false }
            guard let img = grab() else { return false }
            if nav.pageHere(img) == "feed" { return true }
            if nav.runFunnel(img) { sleep(1.0); continue }
            let here = nav.pageHere(img) ?? "unknown"
            let r = nav.step(from: here, img: img) { [weak self] in self?.grab() }
            if !r.acted { return false }
            sleep(1.2)
        }
        return false
    }

    /// ⭐ 打开搜索页（**可重入**：已在搜索/结果页 ⇒ 直接算成功）
    ///
    /// ## ⛔⛔ §2263 修：原来**上来就找放大镜**，而放大镜只在 **feed 顶栏**
    /// 真机 trace 铁证（金币中心页上）：
    /// ```
    /// §tag ⚠️ 直接开搜索没成 ⇒ 先回 feed 首页再试
    /// §tag ⛔ 打不开搜索页 ⇒ 停手
    /// ```
    /// **根因**：`openSearch` 第一步就 `nav.tap("search_entry")`（放大镜），
    /// 而**金币中心页没有放大镜** ⇒ 恒 miss ⇒ 直接 `return false` ⇒ tag/mall 全废。
    ///
    /// ✅ 照 PC `open_ks_search`（`_1377_ad_loop.py:6051`）的腿序：
    /// ```
    /// ① 已在搜索页/结果页 ⇒ 直接算成功（**可重入**，PC §1737c 血案：省一次往返）
    /// ② feed 首页 ⇒ **模板**定位放大镜 ⇒ 点
    /// ③ 其它页 ⇒ 找 `〈` 回退，再回 ②
    /// ```
    /// ⭐ 关键差别：**②③ 是"先到 feed、再点放大镜"** —— 而 feed 靠**页面图**走过去
    ///   （`feed.go = coin_ball` 是回中心；**去 feed 要走 `gotoFeed`**）。
    private func openSearch(tag: String) -> Bool {
        for _ in 0..<4 {
            if isCancelled() { return false }
            guard let img = grab() else { return false }
            // ① 可重入：已在搜索/结果页 ⇒ 成功（PC 铁律：先问这个，别重链）
            if nav.detect("search_page", img: img) != nil { return true }
            if nav.runFunnel(img) { sleep(1.0); continue }
            // ② 只**在 feed 页**才点放大镜（放大镜是 feed 顶栏的元素）
            let here = nav.pageHere(img) ?? "unknown"
            if here == "feed" {
                if nav.tap("search_entry", img: img) {
                    sleep(1.8)
                    continue
                }
                log("   §\(tag) ⚠️ 在 feed 但**没找到放大镜**（模板 `x_ref_ks_mag.png` 未命中）")
                return false
            }
            // ③ 不在 feed ⇒ **先走到 feed**（照 PC「先回首页再找放大镜」）
            log("   §\(tag) 在 \(here)（非 feed）⇒ 先去 feed 首页再找放大镜")
            if !gotoFeed(tag: "\(tag)_tofeed") {
                log("   §\(tag) ⛔ 到不了 feed 首页 ⇒ 打不开搜索页")
                return false
            }
        }
        return false
    }

    /// ⭐ 进小店首页（可重入）
    ///
    /// ⛔⛔ §2263 修（与 `openSearch` 同病）：原来**上来就 `tap("mall_entry")`**，
    /// 而 `mall_entry` 的判据是顶栏「商城/快手小店」——**金币中心页没有这些词**
    /// ⇒ 恒 miss ⇒ `enter_mall` 空转到 4 次 ⇒ `进不了小店首页 ⇒ 停手`。
    /// ✅ 照 PC `enter_mall`（L7233）**可重入 + 先到已知入口态**：先 `gotoFeed`。
    private func enterMall(tag: String) -> Bool {
        for _ in 0..<4 {
            if isCancelled() { return false }
            guard let img = grab() else { return false }
            // ① 可重入：已在商城页 / 已命中商城入口词 ⇒ 成功
            if nav.pageHere(img) == "mall"
                || nav.detect("mall_entry", img: img) != nil { return true }
            if nav.runFunnel(img) { sleep(1.0); continue }
            // ② 不在 feed ⇒ 先到 feed（商城入口在 feed 底栏/顶栏）
            let here = nav.pageHere(img) ?? "unknown"
            if here != "feed" {
                log("   §\(tag) 在 \(here)（非 feed）⇒ 先去 feed 首页再进小店")
                if !gotoFeed(tag: "\(tag)_tofeed") {
                    log("   §\(tag) ⛔ 到不了 feed 首页 ⇒ 进不了小店")
                    return false
                }
                continue
            }
            // ③ 在 feed ⇒ 点商城入口
            if nav.tap("mall_entry", img: img) { sleep(1.8); continue }
            log("   §\(tag) ⚠️ 在 feed 但没找到小店入口 ⇒ 停手")
            return false
        }
        return false
    }

    /// ⭐⭐ 搜一个词：**点框 → 落中文（硬闸）→ 点搜索**
    ///
    /// ## ⛔⛔ 落中文硬闸（用户令 + PC §1743，⛔ 这是最容易漏的一条）
    /// > 用户令：「**打字一定要做到中文，拼音绝对不行**」
    ///
    /// 电脑端血案原文（`_1377_ad_loop.py` L6241）：
    /// > ⛔ 旧实现有「候选栏没命中 ⇒ 点搜索键（快手后端解析拼音）」的兜底腿。
    /// >   真机实测拿**生拼音** `bingxiang` 去搜，小店直接返回「**无相关商品**」空页
    /// >   ⇒ 整轮白跑。**这条腿已删除。**
    ///
    /// ⇒ 纪律：**框内必须真的出现目标中文词，才允许提交**。
    ///   三条腿全不成 ⇒ **一个字都不提交**，返回 false 让调用方换词。
    private func searchOneWord(_ word: String, tag: String) -> Bool {
        guard let img = grab() else { return false }

        // ① ⭐⭐ 点搜索框 —— 照 PC `ks_find_search_box`（L5682）的**两层**逻辑
        let boxPt = searchBoxPoint(img)
        log("   §\(tag) 点搜索框 @(\(Int(boxPt.x)),\(Int(boxPt.y)))")
        nav.tapPoint(Double(boxPt.x), Double(boxPt.y))
        sleep(1.2)

        // ② 清框（PC：清框只能点**框内清除 ✕** —— 退格/⌘A 实测不吃）
        if let i2 = grab(), nav.detect("search_clear", img: i2) != nil {
            _ = nav.tap("search_clear", img: i2)
            sleep(0.8)
        }

        // ③ ⭐ 打拼音
        guard let py = Pinyin.of(word) else {
            log("   §\(tag) ⚠️ 「\(word)」转不出拼音 ⇒ 跳过这个词")
            return false
        }
        log("   §\(tag) HID 打字 T:\(py)（\(word)）")
        ble.send("T:\(py)")
        sleep(1.2)

        // ④ ⭐⭐ **落中文硬闸**：框内必须真出现中文
        guard landChinese(word, tag: tag) else {
            log("   §\(tag) ⛔ 没落成中文 ⇒ **不提交**（避免留下生拼音）")
            return false
        }

        // ⑤ 点「搜索」
        guard let i3 = grab() else { return false }
        if nav.detect("search_btn", img: i3) != nil {
            _ = nav.tap("search_btn", img: i3)
        } else {
            ble.send("K:RETURN")          // 兜底：回车
        }
        sleep(2.0)
        return true
    }

    /// ⭐⭐ **搜索框落点** —— 照 PC `ks_find_search_box`（`_1377_ad_loop.py:5682`）的两层逻辑
    ///
    /// ```python
    /// for t, cx, cy in sorted(words(img, (0, 55, 330, 110)), key=lambda w: w[1]):
    ///     if t.strip():
    ///         return (cx, cy, t.strip())          # ① 框内有文案 ⇒ 用它的中心
    /// ...
    /// click_at(plog(0.25 * BASE_W, 0.081 * BASE_H))   # ② 没文案 ⇒ 结构性回退位
    /// ```
    ///
    /// ## ⛔ PC 那条警告**必须照抄**（`_1377_ad_loop.py:5685`）
    /// > ⚠️ **必须带下界 y>=55** —— 否则会把状态栏的 `09:41@(74,30)` 当框内文案，
    /// >   点它就等于点 iOS 状态栏（= 回顶）⇒ 全流程跑飞（§1735d 已踩过）。
    ///
    /// ⇒ 所以带子是 `y ∈ [55,110]`（`search_box.roi` 同值），⛔ 不含状态栏。
    ///
    /// ## ⛔ 为什么不用 `nav.detect("search_box")` 的"找不到就返回 false"
    /// 那个元素要求框内**有特定词**（`搜索`/`搜一搜`），而框内实际是
    /// **任意占位/真文本**（可能被 OCR 读成别的）⇒ 要求命中词表会**误判成"找不到框"**
    /// 而整轮搜不了。PC 的口径是「**有一个非空词就行**」，且**一定有回退位**（⛔ 不放弃）。
    /// ⚠️ 回退位是**结构性位置**（框带左侧），⛔ 不是"盲点某个按钮" —— PC 原文如此。
    private func searchBoxPoint(_ img: UIImage) -> CGPoint {
        let roi = CGRect(x: 0, y: 55, width: 330, height: 55)
        var items = rec.ocrRegion(img, rect: roi, minConfidence: 0.3)
        // 照 PC：按 x 排序（`sorted(..., key=lambda w: w[1])`），取第一个**非空**词
        items.sort { $0.1.minX < $1.1.minX }
        for (t, r, _c) in items
        where !t.trimmingCharacters(in: .whitespaces).isEmpty {
            return CGPoint(x: r.midX, y: r.midY)
        }
        // ② PC 的结构性回退位：`(0.25*451, 0.081*977)` = **(113, 79)**
        return CGPoint(x: 0.25 * baseW, y: 0.081 * baseH)
    }

    /// ⭐⭐ **落中文**（照 PC §1743 的腿序）
    ///
    /// ## PC 的两条腿（`_1377_ad_loop.py` L6251）
    /// ```
    /// ① 快手**联想词**里与目标词**完全一致**的那一行（§1737k 真机正解）
    /// ② iOS **IME 候选栏**按编号选字（§1737b 真机验过 `T:1` ⇒ 框内变中文）
    /// ```
    /// ⚠️ **编号只能从字面 OCR 读，⛔ 不能"按位置序号推"**（PC L5727）：
    /// > 2 号是 emoji 候选，OCR 会跳过，按位置推会把 3 号当成 2 号 ⇒ **选中错的字**
    private func landChinese(_ word: String, tag: String) -> Bool {
        // 先看是不是**已经**落好了（有的输入法直接上屏）
        if let im = grab(), boxHas(im, word: word) {
            log("   §\(tag) ✅ 打字后框内已是中文「\(word)」")
            return true
        }

        // ⭐ 腿①：IME 候选栏里**完全一致**的那一项（按**字面编号**选）
        if let im = grab() {
            let cands = imeCandidates(im)
            if !cands.isEmpty {
                log("   §\(tag) IME 候选 \(cands.count) 项："
                    + cands.map { "\($0.0)\($0.1)" }.joined(separator: " "))
                if let hit = cands.first(where: { $0.1 == word }) {
                    log("   §\(tag) ⇒ 选候选 \(hit.0)（\(hit.1)）")
                    ble.send("T:\(hit.0)")
                    sleep(1.2)
                    if let im2 = grab(), boxHas(im2, word: word) {
                        log("   §\(tag) ✅ 落中文成功（候选 \(hit.0)）")
                        return true
                    }
                } else {
                    log("   §\(tag) ⚠️ 候选里没有与「\(word)」**完全一致**的项 ⇒ 不按数字键")
                }
            } else {
                log("   §\(tag) ⚠️ 没看到 IME 候选栏")
            }
        }
        return false
    }

    /// ⭐ 读 iOS **IME 候选栏** ⇒ `[(编号, 词, 框)]`（编号从**字面**读，照 PC `ks_ime_candidates`）
    ///
    /// PC 实测：iOS 候选栏在 `y≈98~144`（基准尺度），每项形如 `1汽车`
    private func imeCandidates(_ img: UIImage) -> [(Int, String, CGRect)] {
        let roi = CGRect(x: 0, y: 98, width: baseW, height: 46)
        var out: [(Int, String, CGRect)] = []
        for (t, r, _c) in rec.ocrRegion(img, rect: roi, minConfidence: 0.3) {
            // 形如「1汽车」/「3 汽车站」⇒ 抠出编号和词
            let s = t.trimmingCharacters(in: .whitespaces)
            guard let first = s.first, let n = Int(String(first)), n >= 1, n <= 9 else { continue }
            let rest = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            out.append((n, rest, r))
        }
        return out
    }

    /// ⭐ 框内是否已含**目标词**（照 PC `_box_ok` 的「包含」判据）
    ///
    /// ⚠️ PC 为什么用「包含」而不是全等（L6253）：
    /// > 真机框内文本会把左侧放大镜 OCR 成 `Q`（`Q冰箱@(95,79)`）⇒ 全等会**误判失败**
    private func boxHas(_ img: UIImage, word: String) -> Bool {
        let roi = CGRect(x: 0, y: 55, width: baseW, height: 60)   // 搜索框那一带
        let items = rec.ocrRegion(img, rect: roi, minConfidence: 0.3)
        for (t, _r, _c) in items where t.contains(word) { return true }
        return false
    }

    /// ⭐ 浏览结果页（点卡片、完播/短停、退回）
    private func browseResults(until end: Date, tag: String) {
        var n = 0
        while Date() < end {
            if isCancelled() { return }
            guard let img = grab() else { return }
            guard let hit = nav.detect("result_card", img: img) else {
                log("   §\(tag) 没有更多卡片 ⇒ 结束浏览")
                return
            }
            n += 1
            nav.tapPoint(Double(hit.center.x), Double(hit.center.y))
            sleep(2.0)
            // 详情页**拟人停留**（完播/短停）
            sleepWithCancel(min(12.0, max(3.0, end.timeIntervalSinceNow * 0.2)))
            // 退回结果页
            nav.backEdge()
            sleep(1.2)
        }
        log("   §\(tag) 浏览了 \(n) 个卡片")
    }

    /// ⭐ 挑词：⛔ 不连着搜同一个词（PC 看最近 6 个）
    ///
    /// ⚠️ 还带**能转拼音**过滤（照 PC `covers`）：转不出的词选了也白费一轮。
    private func pickWord(_ pool: [String], used: [String], recent: Int) -> String? {
        let usable = pool.filter { Pinyin.covers($0) }
        if usable.isEmpty { return nil }
        let tail = Set(used.suffix(recent))
        let avail = usable.filter { !tail.contains($0) }
        if let w = avail.randomElement() { return w }
        return usable.first { !used.contains($0) }      // 都用过 ⇒ 放宽，只排最近
    }

    private func featMinutes(_ key: String, dflt: Double) -> Double {
        if let m = s?.feat_min?[key], m > 0 { return m }
        return dflt
    }

    // MARK: - 底层动作（全部走 ESP32 HID，坐标是**基准 451×977**）

    private func swipeUp(_ gapMin: Double, _ gapMax: Double) {
        let midX = baseW / 2.0
        let yBot = baseH * (s?.swipe_y_bot_pct ?? 0.70)
        let yTop = baseH * (s?.swipe_y_top_pct ?? 0.30)
        let speed: BLEController.SwipeSpeed =
            (s?.swipe_video_speed == "slow") ? .slow
            : (s?.swipe_video_speed == "mid") ? .mid : .fast
        let cmd = BLEController.swipe(x1: midX, y1: yBot, x2: midX, y2: yTop,
                                      speed: speed, baseW: baseW, baseH: baseH, yFix: yFix)
        ble.send(cmd)
        let a = min(gapMin, gapMax), b = max(gapMin, gapMax)
        let g = b > a ? Double.random(in: a...b) : a
        sleepWithCancel(g)
    }

    /// ⭐ 可中断的等待（⛔ 不用裸 `Thread.sleep`，否则「停止」要等很久才生效）
    private func sleep(_ s: Double) { sleepWithCancel(s) }

    private func sleepWithCancel(_ seconds: Double) {
        var left = seconds
        while left > 0 && !isCancelled() {
            let d = min(0.2, left)
            Thread.sleep(forTimeInterval: d)
            left -= d
        }
    }
}
