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

    // ══════════════════════════════════════════════════════════════════
    // ⭐⭐⭐⭐⭐ §2645 **本次新增的 6 组「硬编码 → 配置」读取点**
    //
    // 用户令（逐字，这就是本组读取点的由来）：
    // > 「**你直接在软件留可以更改的容量不行么，每次更改都要签名。太浪费时间了**」
    // > 「**你不是留了通道么，直接用通道调试 最快**」
    //
    // ⇒ 推送 `POST /write?name=pgconfig/config.json` + `POST /reload` = **秒级生效**，
    //   ⛔ 不再需要「改代码 → 编译 → 签名 → 安装」（一次 ≈ 3 分钟）。
    //
    // ⛔⛔ **兼容性硬要求**：每个读取点**都必须**带 `?? 默认值`，且默认值与
    //   改动前的硬编码**逐字一致** ⇒ 老配置（新键全不写）走**完全一样**的行为。
    // ══════════════════════════════════════════════════════════════════

    /// ⭐⭐⭐⭐⭐ §2645 **广告顶栏 ROI 的默认值** `[x, y, w, h]`。
    ///
    /// ⛔ 逐字等于改动前两处共用的硬编码 `CGRect(x: 0, y: 62, width: bw, height: 78)`
    ///   （`bw` 默认 = `base_w` = 451 ⇒ 即 `[0, 62, 451, 78]`）。
    static let adTopRoiDefault: [Double] = [0, 62, 451, 78]

    /// ⭐⭐⭐⭐⭐ §2645 **广告顶栏 ROI 的「唯一」读取函数**（⛔ 不许各写一份）
    ///
    /// 下面**所有**要读广告顶栏的地方（`looksLikeAdPage` / `adTopText` ⇒ 进而
    /// `adCountdownRunning` / `adCountdownSeconds` / `finishAdPanel`）**一律**走这里 ——
    /// 这正是「§2265 改了一处忘了另一处」那类血案的**结构性**防法。
    ///
    /// - Parameter cfgRoi: `settings.ad_top_roi`（⛔ nil = 用现在的硬编码默认值）
    /// - Returns: **基准坐标**（451×977）下的 ROI；
    ///   配置缺失 / 不足 4 个数 / `w`或`h` ≤ 0（会被下游 OCR 拒绝）⇒ 一律回默认值
    static func adTopROI(_ cfgRoi: [Double]?, bw: Double, bh: Double) -> CGRect {
        let d = adTopRoiDefault
        guard let r = cfgRoi, r.count >= 4, r[2] > 0, r[3] > 0 else {
            // ⛔ 逐字等于改动前的硬编码：`CGRect(x: 0, y: 62, width: bw, height: 78)`
            // ⚠️ 宽度用 `bw`（⛔ 不是 `d[2]`）—— 改动前写的就是 `width: bw`，
            //    所以 `base_w` 被配成非 451 时也**逐字一致**。
            return CGRect(x: d[0], y: d[1], width: bw, height: d[3])
        }
        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }

    /// ⭐⭐⭐⭐⭐ §2645 **广告页停留秒** —— 优先级的**唯一**读取点（⛔ 不许各写一份）
    ///
    /// ## ⛔⛔ 为什么优先级必须这么排（向后兼容的命门）
    /// ```
    /// ① `settings.ad_dwell`          —— 有 ⇒ **逐字用现在的值**（config.json 里 = 30）
    /// ② `settings.ad_stay_min/max`   —— ⭐ 没有 `ad_dwell` 时才用区间随机（照荔枝 40/60）
    /// ③ 30                            —— 都没有 ⇒ 改动前的硬编码默认值
    /// ```
    /// ⚠️ `config.json` 里 `ad_dwell = 30` **一直存在** ⇒ 真机行为**一个字都不变**；
    ///   而 `ad_stay_min/ad_stay_max`（40/60）从此**真的被用上**了
    ///   （改动前它们在 `FeatureEngine` 里**完全没被读过** —— 只在 `Runner` 里被读）。
    /// 📏 用户口径：把停留调到几秒就能**验证**「等满 ⇒ CTA 消失」这个判断，⛔ 不用重编译。
    private var adDwellSeconds: Double {
        if let d = s?.ad_dwell { return d }
        if let lo = s?.ad_stay_min, let hi = s?.ad_stay_max {
            // ⚠️ `min...max` 里 upper < lower 会**崩**（Swift 运行时陷阱）⇒ 先排序
            return Double.random(in: min(lo, hi)...max(lo, hi))
        }
        if let lo = s?.ad_stay_min { return lo }
        return 30
    }

    /// ⭐⭐⭐ §2645 **CTA 文案兜底词表** —— 配置优先，⛔ 缺省 = 现在的硬编码 12 条
    private var ctaKeysCfg: [String] { s?.cta_keys ?? Self.ctaKeys }

    /// ⛔⛔⛔ §2645 **禁点词（支付红线）** —— 配置优先，⛔ 缺省 = 现在的硬编码 25 条
    ///
    /// ⚠️ 配置化**受** `ConfigStore.validate()` 的**加法校验**保护：
    ///   只许在基线之上追加，⛔ 删减任何一条 ⇒ `/reload` **拒绝加载**并报 `configErrors`。
    private var forbidKeysCfg: [String] { s?.forbid_keys ?? Self.forbidKeys }

    /// ⭐⭐⭐⭐⭐ §2645 **回广告页的腿序轮数** —— 默认 **9**（照 PC `for k in range(9)`）
    private var returnToAdRounds: Int { max(1, s?.return_to_ad_rounds ?? 9) }

    /// ⭐⭐⭐ §2645 **回广告页每轮之间的等待（秒）** —— 默认 **3.2**（照 PC `wait(3.2)`）
    private var returnToAdWait: Double { s?.return_to_ad_wait ?? 3.2 }

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
        // ⭐⭐⭐⭐⭐ §2645 **广告页停留时长改走 `adDwellSeconds`（唯一读取点）**
        //
        // ## 改动前后的**逐字等价**证明
        // 改动前：`let dwell = s?.ad_dwell ?? 30`
        // 改动后：`s?.ad_dwell` **有值** ⇒ `adDwellSeconds` 第一分支 `return d` ⇒ **一模一样**；
        //        `s?.ad_dwell` 为 nil ⇒ 落到第三分支 `return 30` ⇒ **仍然是 30**。
        // ⇒ 老配置（含现在这份 `ad_dwell = 30`）**行为一个字都不变**。
        //
        // ## 为什么这件事**价值最大**（用户令 + 真机 trace 铁证）
        // trace 证明「**等满 51s 才去点 CTA**」⇒ 广告已结束 ⇒ **CTA 消失** ⇒ 转化恒失败。
        // 配置化后可以直接把停留调到**几秒**来验证这个判断，⛔ 不用重编译（省 3 分钟/次）。
        // ⚠️ 优先级：`ad_dwell` > `ad_stay_min/max`（后者改动前在本文件里**根本没被读过**）。
        let dwell = adDwellSeconds
        log("§adbox 条数=\(count) 广告停留=\(Int(dwell))s 入口=\(s?.entry ?? "auto")")

        guard ensureInCenter(tag: "adbox_boot") else {
            log("§adbox ⛔ 回不到金币中心 ⇒ 停手")
            return false
        }

        var n = 0
        var emptyRounds = 0
        var scrollTries = 0          // ⭐ §2309 任务列表翻页次数
        var adEntryToggle = 0        // ⭐ §2315 入口轮换计数（宝箱 ↔ 看广告得金币）
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
            // ## PC 的完整顺序（分支A → 转化 → G3 → G4，`_1377_ad_loop.py:9560` 逐字）
            // ```
            // ① 先等 30~60s 随机（§1541：「等待时间还是要做个随机数字，30-60 随机」）
            // ② **做转化**（CTA → 浏览）        ← ⭐ 广告还在 ⇒ CTA 才在（§2632）
            // ③ G3：**等倒计时结束**（轮数按胶囊里的 N 动态定：N+20s 余量）
            // ④ G4：倒计时结束后**才点 ✕**收奖励 ⇒ 处理弹出的面板
            // ```
            // ⛔⛔ §2632 **② 必须在 ③ 之前**（我上一版把转化排在 G3 之后 ⇒ CTA 已消失）。
            if Self.looksLikeAdPage(img, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                       roi: s?.ad_top_roi) {
                // ⭐⭐⭐⭐⭐ §2641 **转化必须在最前**（照 PC `_1377_ad_loop.py:9560`）
                // ⛔ 等 30~60s 再转化 = 本机广告只有约 25s ⇒ 等满时 **CTA 必然消失**
                // 真机 trace：`[72s] 顶栏已成功领取` → `[90s] 没找到可点的 CTA`
                var cur = img

                // ── ② ⭐⭐⭐ 转化：点 CTA → 浏览落地页（**必须在 G3 之前**，§2632）──
                if !isCancelled(), let cur4 = grab() {
                    if let how = clickCTA(cur4, tag: "adbox_cta\(n + 1)") {
                        log("§adbox CTA 已点（\(how)）⇒ 等落地页")
                        sleep(3.2)
                        if let land = grab(),
                           !Self.looksLikeAdPage(land, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                                 roi: s?.ad_top_roi) {
                            log("§adbox ✅ 已进落地页（顶栏「\(Self.adTopText(land, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi).prefix(18))」）⇒ 浏览")
                            clickInstall(land, tag: "adbox_inst\(n + 1)")   // 先点安装（照 PC 顺序）
                            browseLanding(tag: "adbox_browse\(n + 1)")      // 再浏览
                        } else {
                            log("§adbox ⚠️ CTA 没点进落地页 ⇒ **不浏览**（照 PC：都没进去，滑什么）")
                        }
                    } else {
                        log("§adbox ⚠️ 没找到可点的 CTA（过闸后）⇒ 本条不做转化，直接收奖励")
                    }
                }

                // ── ②b ⭐⭐⭐⭐⭐ §2640 **回广告页**（PC L9769~L9801，⛔ 我原来整段漏了）──
                //
                // ## ⛔⛔ 用户令（逐字，本轮）
                // > 「**这个未点X就切下一个了**」
                //
                // ## 血案（真机 trace + 用户截图）
                // 用户截图停在**天猫落地页**（「商品正在加速赶来中」）—— 说明 **CTA 点成功了**，
                // 但代码**在落地页上直接跑 G3/G4 去找广告胶囊 ✕** ⇒ 当然找不到
                // ⇒ `finishAdPanel` 返回 false ⇒ **本条就这样"结束"**，去切下一个广告。
                // ⇒ 现象 = 「**未点 X 就切下一个**」。
                //
                // ## PC 的做法（`_1377_ad_loop.py:9769-9801`，逐字）
                // ```python
                // # ③ 回广告页：可能要 2 步（先关被拒 WebView，再点面包屑）
                // #    ⇒ 循环到顶栏重新读到胶囊为止（★§1633 轮数 6 → 9）
                // for k in range(9):
                //     img_r = grab(...)
                //     if on_center(img_r): at_center = True; break          # 直接落回金币中心 ⇒ 也算成功
                //     _pk_r, _ptop_r, _pev_r = page_kind(img_r, top=txt(img_r, BOX_TOP))
                //     if _pk_r in ("ad_video", "ad_live"): break            # ⭐ 已回广告页
                //     if _pk_r == "unknown" and ("可领取" in top_r): break   # 兼容
                //     return_to_ad(img_r, k)                                # ⛔ 否则**主动返回**
                //     wait(3.2)
                // ```
                // 📏 关键：**"返回"是一个要反复尝试的动作**（最多 9 次），
                //   ⛔ 不是"我以为已经回来了"。这正是我漏掉的那一步。
                log("§adbox ↩ 转化完 ⇒ **回广告页**（照 PC `for k in range(9)` 返回腿，轮数可配）")
                var backHome = false
                for k in 0..<returnToAdRounds {
                    if isCancelled() { break }
                    guard let imr = grab() else { break }
                    // ① ⭐⭐⭐⭐⭐ **已回广告页** ⇒ 继续走 G3/G4
                    //    ⛔⛔ **必须在"中心判据"之前**（§2644 真机血案，子智能体核对逮到）
                    if Self.looksLikeAdPage(imr, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                            roi: s?.ad_top_roi) {
                        log("   §adbox ✅ 已回广告页（第 \(k + 1) 次检查）⇒ 继续等倒计时")
                        cur = imr
                        break
                    }
                    // ② 落回金币中心 ⇒ 本条已完成（照 PC `on_center`）
                    //
                    // ⛔⛔⛔ §2644 **绝不能在这里用 `ensureInCenter`**（血案）
                    // `ensureInCenter` 第 1328 行有一条**广告页放行短路**：
                    // ```swift
                    // if Self.looksLikeAdPage(img, ...) { return true }   // ← 广告页也返回 true
                    // ```
                    // ⇒ 若拿它当"到中心了吗"的判据：**人还在广告页**时它会返回 true
                    //   ⇒ 打印"已落回金币中心 ⇒ 本条算完成" ⇒ `n += 1` 切下一条
                    //   ⇒ **不进 G3/G4、不点 ✕、不收奖励** = 用户令「**这个未点X就切下一个了**」。
                    // ✅ 改用**纯元素判据**（config 的 `center_marker`）—— 与 PC `on_center` 同语义：
                    //    它只看"中心页的特征词在不在"，⛔ 不会因为"是广告页"就放行。
                    if nav.detect("center_marker", img: imr) != nil {
                        log("   §adbox ✅ 已落回金币中心（第 \(k + 1) 次检查）⇒ 本条算完成")
                        backHome = true
                        break
                    }
                    // ③ 还在落地页 ⇒ **主动返回**（照 PC `return_to_ad`）
                    log("   §adbox ↩ 还在落地页（第 \(k + 1)/\(returnToAdRounds) 次）⇒ 执行返回")
                    returnToAd(imr, tag: "adbox_ret\(n + 1)_\(k)", k: k)
                    sleep(returnToAdWait)
                }
                if backHome {
                    n += 1
                    scrollTries = 0
                    continue
                }

                // ── ③ G3：**等倒计时结束**才许动手（PC L9814~L9858）────────
                //    ⭐ 判据 = PC 的**两条**（见 `adCountdownRunning` 的 docstring）：
                //      ① `\d+[sS秒]?后`（抗错字 —— `19后` 也算，真机 f031/f033 铁证）
                //      ② 「后可领取」句式还在 ⇒ 保守算"在走"
                //    ⛔ 绝不能用旧式 `\d+秒` 单条：真机 OCR 常把 `19s` 读成 `19`
                //      ⇒ 判据恒 false ⇒ 误判"走完" ⇒ **提前点 ✕ 把广告点死**（§2628 血案）。
                //
                // ⭐ §2628 **等待轮数按胶囊里的 N 动态定**（照 PC L9821~L9825）：
                //   `_need = N + 20` ⇒ 多长的广告都等得起（⛔ 不是固定 90s）
                var waited = 0.0
                let needS: Double = {
                    if let n0 = Self.adCountdownSeconds(cur, rec: rec,
                                                        bw: baseW, bh: baseH,
                                                        roi: s?.ad_top_roi,
                                                        secondsPatterns: s?.countdown_seconds_regex) {
                        return Double(n0) + 20.0
                    }
                    return 45.0          // 读不到 N ⇒ PC 的默认（`_need … else 45`）
                }()
                log("   §adbox G3 胶囊倒计时 N ⇒ 最多等 \(Int(needS))s（N+20 余量，照 PC）")
                while Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex),
                      waited < needS, !isCancelled() {
                    sleep(3.0)
                    waited += 3.0
                    guard let im3 = grab() else { break }
                    cur = im3
                    log("   §adbox G3 等倒计时结束（已等 \(Int(waited))s / \(Int(needS))s"
                        + "；⛔ 没结束不点 ✕）")
                }
                // ⭐ §2628 **到账闸**（照 PC `click_toast_x` L4342，⛔ 点 ✕ 前最后确认一次）
                //   「顶栏只要还有倒计时 ⇒ 倒计时没走完 ⇒ 不点 X」。
                //   ⚠️ 这里再等一轮（预算是上面那个 `needS` 的余量），因为
                //      G3 可能在**读不到 N** 时用了默认 45s 而广告实际更长。
                if Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex) {
                    log("   §adbox ⛔ 顶栏**还有倒计时** ⇒ **这次不点 ✕**（照 PC 到账闸）⇒ 继续等")
                    var extra = 0.0
                    // 补等预算：再来一个 N+20（照 PC 的余量思想），上限 180s 防死等
                    let extraNeed = min(180.0, needS)
                    while Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex),
                          extra < extraNeed, !isCancelled() {
                        sleep(3.0)
                        extra += 3.0
                        guard let im4 = grab() else { break }
                        cur = im4
                        log("   §adbox G3 到账闸再等（已补等 \(Int(extra))s）；⛔ 不点 ✕）")
                    }
                    log("   §adbox ✅ 到账闸放行（补等 \(Int(extra))s）⇒ 现在才点 ✕")
                }
                if Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex) {
                    log("   §adbox ⛔⛔ 等满预算**倒计时仍未走完** ⇒ **本条不点 ✕**"
                        + "（照 PC「不硬撑」）；交给下一轮重判")
                    continue
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
                scrollTries = 0          // ⭐ §2309 每成功拿下一条，重置翻页预算
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
            // ⭐⭐⭐⭐⭐ §2315 **宝箱入口与“看广告得金币”逐条轮换（用户令）**
            //
            // ## 用户原话（逐字，本段就是规格）
            // > 「**说了要宝箱和他轮换呢**」
            //
            // ## ⛔ 本轮审计发现：iOS 读了 `settings.entry` 但**从来没用过**
            // `FeatureEngine` 打印了 `入口=\(s?.entry ?? "auto")`，然后就**直接走按行腿**
            // ⇒ `entry` 设置（auto/fuli/chest）形同虚设，宝箱轮换**根本没实现**。
            // 📏 PC 的 `AISJ_ENTRY=auto` 是「宝箱 ↔ 看广告得金币 逐条轮换」（不是分两轮跑）。
            //
            // 出路共用：点宝箱浮件 ⇒ 出面板 ⇒ 点 CTA「去看广告」⇒ 进广告链。
            // ⛔ 铁律②：任一步没定位到锚 ⇒ **什么都不做**，落回按行腿。
            let entryMode = (s?.entry ?? "auto")
            let wantChest: Bool = {
                if entryMode == "chest" { return true }
                if entryMode == "fuli" { return false }
                // auto ⇒ 逐条轮换（照 PC `_ENTRY_TOGGLE[0] % 2 == 0`）
                adEntryToggle += 1
                return adEntryToggle % 2 == 0
            }()
            if wantChest, let c = nav.detect("chest_float", img: img)?.center {
                log("§adbox 【入口=auto 轮换】本条走**宝箱**入口 ⇒ 浮件 @(\(Int(c.x)),\(Int(c.y)))")
                nav.tapPoint(Double(c.x), Double(c.y))
                // 等一张新帧（面板出来了才能找 CTA）
                if let ip = grabFresh(since: img, maxWait: maxFrameAgeCfg + 3.0),
                   let cta = nav.detect("chest_cta", img: ip)?.center {
                    log("§adbox 宝箱面板 CTA @(\(Int(cta.x)),\(Int(cta.y))) ⇒ 进广告链")
                    nav.tapPoint(Double(cta.x), Double(cta.y))
                    // 进了广告链 ⇒ 交给下一轮循环的“广告页”分支处理
                    if let i3 = grabFresh(since: ip, maxWait: maxFrameAgeCfg + 3.0),
                       Self.looksLikeAdPage(i3, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                            roi: s?.ad_top_roi) {
                        for _ in 0..<6 {
                            if isCancelled() { break }
                            guard let im4 = grab() else { break }
                            if !finishAdPanel(im4, tag: "adbox_chest\(n + 1)") { break }
                            sleep(1.5)
                        }
                        n += 1
                        scrollTries = 0
                        emptyRounds = 0
                        _ = ensureInCenter(tag: "adbox_chestback\(n)")
                        continue
                    }
                    log("§adbox 点了宝箱 CTA 但没进广告页 ⇒ 落回按行腿")
                } else {
                    log("§adbox 宝箱面板上没找到 CTA ⇒ 不放枪，落回按行腿")
                }
            }

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
                   Self.looksLikeAdPage(i2, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                        roi: s?.ad_top_roi) {
                    // ⛔⛔ **必须先等倒计时结束，才许点 ✕**（用户令 + PC G3）
                    // > 「**倒计时是广告没结束 你没结束去点 不是傻逼。广告结束了你不点了。**」
                    // ⚠️ 而且**不能盲等**（§2278）：边等边看顶栏，广告一结束就立刻去点。
                    // ⛔⛔ 用户令 + PC **顺序**（`_1377_ad_loop.py:9560`，逐字）
                    // > 「**倒计时是广告没结束 你没结束去点 不是傻逼。广告结束了你不点了。**」
                    //
                    // # ⛔⛔⛔ §2632 **我把顺序搞错了：转化必须在"等倒计时结束"之前**
                    //
                    // ## 血案（用户令，本轮）
                    // > 「**你把转化又删掉了？**」
                    //
                    // 真机 trace 逐字（`run_trace.log`）：
                    // ```
                    // 14:35:54  §adbox ✅ 顶栏「已成功领取」（等 28s）⇒ 广告结束，立即收奖励
                    // 14:35:54  §adbox_cta1 ⛔ 没找到可点的 CTA（过闸后）⇒ 停手，⛔ 不盲点
                    // 14:35:54  §adbox ⚠️ 没找到可点的 CTA（过闸后）⇒ 本条不做转化，直接收奖励
                    // ```
                    // ⇒ 我等到**广告播完**（顶栏「已成功领取」）**才去找 CTA**
                    //   ⇒ 那时广告页已换成**奖励面板** ⇒ **CTA 早没了** ⇒ 转化整条丢失。
                    //
                    // ## ✅ PC 的权威顺序（`_1377_ad_loop.py:9560-9565` + `:9654`）
                    // ```python
                    // # ① 分支A：进广告页先等 30~60s 随机（§1541 用户口径）
                    // if "已成功领取" not in top:
                    //     _dwell = random.uniform(30.0, 60.0)
                    //     wait(_dwell)                 # ⭐ **固定随机等**，⛔ 不是"等倒计时结束"
                    // # ② 做转化（CTA → 互动 → 浏览）    ⭐ **此时广告还在 ⇒ CTA 才在**
                    // CONV[0] = convert_and_browse(...)
                    // # ③ G3：等倒计时结束再动手
                    // for k in range(_rounds):
                    //     if "已成功领取" in top3: break
                    //     wait(3.0)
                    // # ④ G4：倒计时结束后**才点 ✕** ⇒ 处理面板
                    // ```
                    // 📏 关键：**① 的等待是"固定随机 30~60s"，⛔ 不是"一直等到广告结束"**。
                    //   我改成"等倒计时结束"⇒ **结构上必然错过 CTA 窗口**
                    //   （上一轮"能点到 CTA"是**歪打正着**：当时判据读不到倒计时 ⇒ 2 秒就跳出
                    //     ⇒ 碰巧广告还在 ⇒ 点到 CTA）。
                    //
                    // ## ✅ §2641 **正确顺序 = ① 转化 → ② 回广告页 → ③ 等倒计时 → ④ 点 ✕**
                    // ⛔ 我连错三次（等倒计时→转化 / 先等30~60s→转化 / 被 reset 冲掉两次），
                    //   共同点都是**把转化放在了某个等待之后** ⇒ 而本机广告只有约 25s。
                    var cur = i2
                    // ── ① ⭐⭐⭐ 转化：**立刻**点 CTA → 进落地页 → 浏览（§2641）──
                    //
                    // ## ⛔ 手机端原来**完全没有这一步**（`_dev/_2440_port_diff.py` 对照出来的差集）
                    // 它从"倒计时结束"**直接跳到收奖励** ⇒ 就是用户骂的那句：
                    // > 「**广告完全不转化，全是看完就X。全是低价值**」（§1526）
                    // > 「**他是一直滑动 但是没有点击CTA**」「**都没点进去 跳什么啊？**」（§1560）
                    //
                    // ## PC 的顺序（`_1377_ad_loop.py:8783 convert_and_browse`，⛔ 不许改）
                    // ```
                    //   ① click_cta      点底部 CTA（形状优先 → 文案兜底）
                    //   ② wait(3.2)
                    //   ③ 判 is_ad_page  ⛔ 没点进落地页 ⇒ **一律不滑**（用户令：都没点进去，滑什么）
                    //   ④ browse_landing 上滑 4~8 次、每次隔 3~6s
                    // ```
                    // ⛔ 红线只有一条：**不支付/不购买**（由 `forbidden()` 黑名单硬闸守）
                    if !isCancelled(), let cur4 = grab() {
                        if let how = clickCTA(cur4, tag: "adbox_cta\(n + 1)") {
                            log("§adbox CTA 已点（\(how)）⇒ 等落地页")
                            sleep(3.2)
                            if let land = grab(),
                               !Self.looksLikeAdPage(land, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                                 roi: s?.ad_top_roi) {
                                log("§adbox ✅ 已进落地页（顶栏「\(Self.adTopText(land, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi).prefix(18))」）⇒ 浏览")
                                clickInstall(land, tag: "adbox_inst\(n + 1)")   // ④a 先点安装（照 PC 顺序）
                                browseLanding(tag: "adbox_browse\(n + 1)")      // ④b 再浏览
                            } else {
                                log("§adbox ⚠️ CTA 没点进落地页 ⇒ **不浏览**（照 PC：都没进去，滑什么）")
                            }
                        } else {
                            log("§adbox ⚠️ 没找到可点的 CTA（过闸后）⇒ 本条不做转化，直接收奖励")
                        }
                    }
                    // ── ①b ⭐⭐⭐⭐⭐ §2640 **回广告页**（PC L9769~L9801，⛔ 我原来整段漏了）──
                    //
                    // ## ⛔⛔ 用户令（逐字）
                    // > 「**这个未点X就切下一个了**」
                    //
                    // ## 血案（用户截图 + trace）
                    // 截图停在**天猫落地页**（「商品正在加速赶来中」）⇒ CTA **点成功了**，
                    // 但代码**在落地页上直接跑 G3/G4 找广告胶囊 ✕** ⇒ 找不到
                    // ⇒ `finishAdPanel` 返回 false ⇒ 本条"结束" ⇒ **去切下一个广告**。
                    //
                    // ## PC 的做法（`_1377_ad_loop.py:9769-9801`）
                    // ```python
                    // for k in range(9):                    # ⭐ 最多 9 轮
                    //     if on_center(img_r): at_center=True; break   # 落回金币中心 ⇒ 也算完成
                    //     if page_kind(img_r) in ("ad_video","ad_live"): break   # 已回广告页
                    //     return_to_ad(img_r, k)            # ⛔ 否则**主动返回**
                    //     wait(3.2)
                    // ```
                    log("§adbox ↩ 转化完 ⇒ **回广告页**（照 PC `for k in range(9)` 返回腿，轮数可配）")
                    var backHome = false
                    for k in 0..<returnToAdRounds {
                        if isCancelled() { break }
                        guard let imr = grab() else { break }
                        // ⭐ §2644 **"已回广告页"必须排在"中心判据"之前**（血案见分支① 注释）
                        if Self.looksLikeAdPage(imr, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                            roi: s?.ad_top_roi) {
                            log("   §adbox ✅ 已回广告页（第 \(k + 1) 次检查）⇒ 继续等倒计时")
                            cur = imr
                            break
                        }
                        // ⛔ §2644 **不能用 `ensureInCenter`**（它对广告页 `return true` ⇒
                        //   会误判"已回中心"⇒ 不点 ✕ 就切下一条）。改用纯元素判据 `center_marker`。
                        if nav.detect("center_marker", img: imr) != nil {
                            log("   §adbox ✅ 已落回金币中心（第 \(k + 1) 次检查）⇒ 本条算完成")
                            backHome = true
                            break
                        }
                        log("   §adbox ↩ 还在落地页（第 \(k + 1)/\(returnToAdRounds) 次）⇒ 执行返回")
                        returnToAd(imr, tag: "adbox_ret\(n + 1)_\(k)", k: k)
                        sleep(returnToAdWait)
                    }
                    if backHome {
                        n += 1
                        scrollTries = 0
                        continue
                    }

                    // ── ③ G3：**等倒计时结束**才许动手（PC L9814~L9858）────────
                    //    ⭐ 判据 = PC 的**两条**（见 `adCountdownRunning` 的 docstring）：
                    //      ① `\d+[sS秒]?后`（抗错字 —— `19后` 也算，真机 f031/f033 铁证）
                    //      ② 「后可领取」句式还在 ⇒ 保守算"在走"
                    //    ⛔ 绝不能用旧式 `\d+秒` 单条：真机 OCR 常把 `19s` 读成 `19`
                    //      ⇒ 判据恒 false ⇒ 误判"走完" ⇒ **提前点 ✕ 把广告点死**（§2628 血案）。
                    //
                    // ⭐ §2628 **等待轮数按胶囊里的 N 动态定**（照 PC L9821~L9825）：
                    //   `_need = N + 20` ⇒ 多长的广告都等得起（⛔ 不是固定 90s）
                    var waited = 0.0
                    let needS: Double = {
                        if let n0 = Self.adCountdownSeconds(cur, rec: rec,
                                                            bw: baseW, bh: baseH,
                                                            roi: s?.ad_top_roi,
                                                            secondsPatterns: s?.countdown_seconds_regex) {
                            return Double(n0) + 20.0
                        }
                        return 45.0          // 读不到 N ⇒ PC 的默认（`_need … else 45`）
                    }()
                    log("   §adbox G3 胶囊倒计时 N ⇒ 最多等 \(Int(needS))s（N+20 余量，照 PC）")
                    while Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex),
                          waited < needS, !isCancelled() {
                        sleep(3.0)
                        waited += 3.0
                        guard let im3 = grab() else { break }
                        cur = im3
                        log("   §adbox G3 等倒计时结束（已等 \(Int(waited))s / \(Int(needS))s"
                            + "；⛔ 没结束不点 ✕）")
                    }
                    // ⭐ §2628 **到账闸**（照 PC `click_toast_x` L4342，⛔ 点 ✕ 前最后确认一次）
                    //   「顶栏只要还有倒计时 ⇒ 倒计时没走完 ⇒ 不点 X」。
                    //   ⚠️ 这里再等一轮（预算是上面那个 `needS` 的余量），因为
                    //      G3 可能在**读不到 N** 时用了默认 45s 而广告实际更长。
                    if Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex) {
                        log("   §adbox ⛔ 顶栏**还有倒计时** ⇒ **这次不点 ✕**（照 PC 到账闸）⇒ 继续等")
                        var extra = 0.0
                        // 补等预算：再来一个 N+20（照 PC 的余量思想），上限 180s 防死等
                        let extraNeed = min(180.0, needS)
                        while Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex),
                              extra < extraNeed, !isCancelled() {
                            sleep(3.0)
                            extra += 3.0
                            guard let im4 = grab() else { break }
                            cur = im4
                            log("   §adbox G3 到账闸再等（已补等 \(Int(extra))s）；⛔ 不点 ✕）")
                        }
                        log("   §adbox ✅ 到账闸放行（补等 \(Int(extra))s）⇒ 现在才点 ✕")
                    }
                    if Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex) {
                        log("   §adbox ⛔⛔ 等满预算**倒计时仍未走完** ⇒ **本条不点 ✕**"
                            + "（照 PC「不硬撑」）；交给下一轮重判")
                        continue
                    }
                    log("§adbox G3 倒计时已结束（等了 \(Int(waited))s）⇒ **现在才点 ✕ 收奖励**")
                    // ── ④ G4：**倒计时结束后才点 ✕** + 处理面板（PC `_ad_finish`）──
                    for _ in 0..<6 {
                        if isCancelled() { break }
                        guard let im4 = grab() else { break }
                        if !finishAdPanel(im4, tag: "adbox_in\(n + 1)") { break }
                        sleep(1.5)
                    }
                    n += 1
                    scrollTries = 0          // ⭐ §2309 重置翻页预算
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
            if Self.looksLikeAdPage(img, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                       roi: s?.ad_top_roi) {
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
            // ⭐⭐⭐⭐⭐ §2309 **任务列表要能"往下翻"（⛔ 上一版直接放弃了）**
            //
            // ## 真机血案（03:0x 真机 trace + 同帧 `/ocr`）
            // 手机明明在**金币中心**（`center_marker` 命中、`adbox_boot` 第 1 步就到），
            // 而 `findAdRowButton` 报「本屏没有「看广告得金币」这道任务行」
            // ⇒ 连续 3 轮 ⇒ 收手 ⇒ **整个 adbox 跑了 2 条就结束**。
            // 同帧 `/ocr` 铁证：任务列表里只有 分享作品/送朋友/看短剧/金币大挑战…
            // ⇒ **目标行还在屏幕下方（没滚出来）**，而我们**没有一条腿会去滚**。
            //
            // ✅ 正解：在放弃之前，**先下滑让任务列表往上走**（方向真机实测过，见 `swipeDownList` 注释），再找一次。
            //    ⛔ 但仍守铁律②：只认「看广告得金币」那一行，换行一律不点。
            //    滚动也不是盲动：它是"把已知列表继续翻页"，不是"点某个固定坐标"。
            var found = false
            // ⭐ 预算 6 次：真机实测目标行在列表靠上位置，需 3~4 次下滑才露出来
            if scrollTries < 6 {
                scrollTries += 1
                log("§adbox ⬇ 本屏没有目标行 ⇒ 下滑任务列表再找（第 \(scrollTries)/6 次）")
                swipeDownList(baseW: baseW, baseH: baseH)
                if let img2 = grabFresh(since: img, maxWait: maxFrameAgeCfg + 3.0) {
                    if let btn2 = findAdRowButton(img2) {
                        log("§adbox ⬇ 翻到了目标行 ⇒ 按钮 \(btn2.evidence) @(\(Int(btn2.point.x)),\(Int(btn2.point.y)))")
                        nav.tapPoint(Double(btn2.point.x), Double(btn2.point.y))
                        if let i3 = grabFresh(since: img2, maxWait: maxFrameAgeCfg + 3.0),
                           Self.looksLikeAdPage(i3, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                            roi: s?.ad_top_roi) {
                            for _ in 0..<6 {
                                if isCancelled() { break }
                                guard let im4 = grab() else { break }
                                if !finishAdPanel(im4, tag: "adbox_scroll\(n + 1)") { break }
                                sleep(1.5)
                            }
                            n += 1
                            emptyRounds = 0
                            _ = ensureInCenter(tag: "adbox_scrollback\(n)")
                        }
                        found = true
                    }
                }
                // 找到了 ⇒ 回到循环头（拍完广告后 n 已加）；
                // 没找到 ⇒ 也回到循环头继续翻（⛔ 不累计 emptyRounds，否则三次翻页就会被当成“找不到”而收手）
                _ = found
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
                               bw: Double, bh: Double, roi: [Double]? = nil) -> Bool {
        // ① PC 原判据（顶栏原文子串，⛔ 不靠元素匹配）
        //
        // ⭐⭐⭐⭐⭐ §2645 **ROI 改走 `adTopROI(...)`（唯一读取点）**
        //   改动前这里硬编码 `CGRect(x: 0, y: 62, width: bw, height: 78)`；
        //   `roi == nil`（老配置 / 调用方没传）⇒ `adTopROI` 返回的**逐字就是它**。
        let items = rec.ocrRegion(img, rect: adTopROI(roi, bw: bw, bh: bh),
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
        //
        // ⛔⛔⛔ §2628 **到账闸：顶栏还有 `\d+秒/Ns` ⇒ 倒计时没走完 ⇒ 绝不点 ✕**
        //
        // ## 用户令（逐字，本轮）
        // > 「**看广告倒计时未结束会提前点击X**」
        //
        // ## PC 的原文（`_1377_ad_loop.py:4342 click_toast_x`，逐字）
        // > ② 到账闸：**只看「还有没有 N秒/Ns 倒计时」**
        // >   ✅ 抗错字写法：**顶栏只要还有 `\d+秒 / \d+s`** ⇒ 倒计时没走完 ⇒ **不点 X**。
        // >   ⛔⛔ §1545 血案：倒计时**早就走完了**，但 OCR 把「已成功领取」读成「善厨领取」
        // >     ⇒ 用 `"已成功领取" not in top` 当闸 ⇒ 永远不成立 ⇒ X 永远不点。
        // >   ⇒ 所以判据是「**还有没有倒计时数字**」，⛔ 不是"有没有到账字样"。
        //
        // 📏 真机证据（本轮 trace，`run_trace.log`）：
        // ```
        // 13:23:27 §adbox_ad2 顶栏胶囊 ✕（面板已不在）⇒ 点它
        // 13:23:28 §click pill_x ATOMIC Q @(214,89)      ← ⛔ 没确认倒计时就点了
        // ```
        // ⇒ 这一脚**把广告点死**（PC 原话：「倒计时没走完就点 ✕ 会把广告点死」）
        //   ⇒ 循环断在这里（用户看到"每次就看一个就强行退出"）。
        if nav.detect("pill_x", img: img) != nil {
            // ⭐ 到账闸：只在**没有倒计时数字**时才允许点这个 ✕
            if Self.adCountdownRunning(img, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex) {
                log("   §\(tag) ⛔ 顶栏**还有倒计时** ⇒ **不点胶囊 ✕**（照 PC 到账闸）"
                    + "⇒ 本层不处理，交回主循环继续等")
                return false
            }
            log("   §\(tag) 顶栏胶囊 ✕（面板已不在、且已无倒计时）⇒ 点它")
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
                          bw: Double, bh: Double, roi: [Double]? = nil) -> String {
        // ⭐⭐⭐⭐⭐ §2645 **与 `looksLikeAdPage` 走同一个 `adTopROI(...)`**
        //   （⛔ 不许各写一份 —— 否则"改了 ROI 只改了一处"⇒ 判据互相打架）
        rec.ocrRegion(img, rect: adTopROI(roi, bw: bw, bh: bh),
                      minConfidence: 0.3)
            .map(\.0).joined()
    }

    /// ⭐⭐⭐⭐⭐ §2628 倒计时**还在走**吗 —— 照 PC 的**两条**判据（`_1377_ad_loop.py:4342` + `:9723`）
    ///
    /// # ⛔⛔⛔ 血案：用户两次点破，我两次猜错方向
    /// > 「**看广告倒计时未结束会提前点击X**」
    /// > 「**有倒计时 他还是强行点击了3次**」
    /// > 「**你仔细看日志 这个行为持续了几次 所以不是没加载的问题**」
    ///
    /// ## 真机帧铁证（`_dev/_2629` 抓的 70 帧，广告页那 5 帧）
    /// ```
    ///   f029  '21s后可领取968金币×'   → 我的旧正则命中 '21s' ✅
    ///   f030  '20s后可领取968金币×'   → 命中 '20s' ✅
    ///   f031  '19后可领取968金币×'    → ⛔ **None**（「s」被 OCR 吃掉）
    ///   f032  '19后可领取968金币×'    → ⛔ None
    ///   f033  '美18后可领取968金币×'   → ⛔ None
    ///   f034  '美团精选婚纱摄影服务'    → 已跳到落地页（广告**被我点死了**）
    /// ```
    /// ⇒ 倒计时**从 21s 一直走到 18s**，而我的代码**在第 2 秒就判"倒计时已走完"**
    ///   ⇒ 提前点 ✕ ⇒ **把广告点死**（trace：`§adbox ✅ 倒计时已走完（等 2s）`）。
    ///
    /// ## ⛔ 我的旧判据错在哪
    /// 旧写法只搜 `[0-9]+\s*(秒|s|S)` —— **要求"数字后面必须跟 秒/s"**。
    /// 而真机 OCR **经常把 `19s` 读成 `19`**（单位丢了）⇒ 判据恒 false
    /// ⇒ 于是"没有倒计时" ⇒ 误判"走完" ⇒ 点 ✕ 点死广告。
    ///
    /// ## ✅ PC 的两条权威判据（⛔ 都不是"数字+秒"）
    /// PC **从不用 `\d+秒` 单独当"还有倒计时"**，它用**胶囊的固定句式**：
    /// ```python
    /// # ① `_1377_ad_loop.py:14`（G1 判"在广告页"）
    /// G1 顶部胶囊含「后可领取」或「已成功领取」⇒ 确认在视频广告页
    /// # ② `_1377_ad_loop.py:9723`（判"倒计时还剩几秒"）
    /// _CD_RX = re.search(r"(\d+)\s*s\s*后", top2) or re.search(r"(\d+)\s*秒后", top2)
    /// ```
    /// ⇒ 关键在 **`后`** 这个字：`Ns后可领取…` / `N秒后可领取…`
    ///   即使 `s`/`秒` 被吃掉，**`后可领取` 这三个字一定还在**（它是广告胶囊的固定句式）。
    ///
    /// ⇒ 所以本函数现在按**优先级**判（照 PC）：
    /// ```
    /// ① 「已成功领取」                ⇒ 明确到账 ⇒ ⛔ 不再算"倒计时在走"（放行去收奖励）
    /// ② `\d+\s*[sS秒]?\s*后`（后可领取/N秒后）⇒ **还有倒计时** ⇒ 走
    /// ③ `\d+\s*[sS秒]`（旧的严格式）   ⇒ 兜底，仍算"在走"
    /// ④ 「后可领取」但没数字            ⇒ 也算"在走"（胶囊形态在 ⇒ 保守不放行）
    /// ```
    /// ⚠️ ④ 是**保守**的一步：宁可多等，也绝不在倒计时没走完时点 ✕
    ///   （用户明令：「**倒计时是广告没结束 你没结束去点 不是傻逼**」）。
    ///
    /// - Returns: true = **倒计时还在走**（广告没结束 ⇒ 只等，⛔ 不点）
    ///
    /// ⭐⭐⭐⭐ §2645 **正则表现在可配**（`settings.countdown_running_regex`）。
    ///   ⛔ 缺省 = `runningPatternsDefault`，**逐字照抄**改动前那两条（⛔ 语义不许改）。
    static func adCountdownRunning(_ img: UIImage, rec: Recognizer,
                                  bw: Double, bh: Double,
                                  roi: [Double]? = nil,
                                  runningPatterns: [String]? = nil) -> Bool {
        let t = adTopText(img, rec: rec, bw: bw, bh: bh, roi: roi)
            .replacingOccurrences(of: " ", with: "")
        // ① 明确到账 ⇒ 倒计时已结束（放行）
        if t.contains("已成功领取") { return false }
        // ② ⭐ PC 主力判据：`\d+[sS秒]?后`（= `19s后` / `19秒后` / **`19后`**）
        //    ⛔ 这才是抗错字的写法 —— `s`/`秒` 丢了也能命中（因为靠 `后` 定位）
        // ③ 兜底：旧的严格式（`\d+秒` / `\d+s`）—— 有的版式没有「后」
        //
        // ⭐ §2645 两条**合并成一张可配的表**（`runningPatternsDefault` 就是它们**逐字**）。
        //    ⚠️ 合并不改语义：原来 ②/③ **都 return true** ⇒ 谁先命中结果一样。
        for pat in (runningPatterns ?? Self.runningPatternsDefault) {
            if let re = try? NSRegularExpression(pattern: pat) {
                let r = NSRange(t.startIndex..<t.endIndex, in: t)
                if re.firstMatch(in: t, range: r) != nil { return true }
            }
        }
        // ④ ⭐ 保守兜底：胶囊句式「后可领取」在、且**没有**「已成功领取」
        //    ⇒ 说明**倒计时还没走完**（只是数字没读出来）⇒ 也算"在走"
        //    ⛔ 宁可多等，绝不在没走完时点 ✕（用户令）
        if t.contains("后可领取") || t.contains("可领取") { return true }
        return false
    }

    /// ⭐⭐⭐⭐ §2645 **「倒计时还在走」的默认正则表** —— 逐字照抄改动前的两条。
    ///
    /// ⚠️ Swift 源码里的 `\\s` 是**转义写法**，运行时 pattern 是 `\s`；
    ///   配置里写 JSON 时用 `\\s`（JSON 转义）才等价。默认值**语义逐字**不变。
    static let runningPatternsDefault: [String] = [
        "[0-9]+\\s*[sS秒]?\\s*后",
        "[0-9]+\\s*(?:秒|[sS])",
    ]

    /// ⭐⭐ 从顶栏读出**倒计时还剩几秒**（照 PC `_1377_ad_loop.py:9723`）
    ///
    /// ```python
    /// _CD_RX = re.search(r"(\d+)\s*s\s*后", top2) or re.search(r"(\d+)\s*秒后", top2)
    /// ```
    /// ⚠️ 读不到 ⇒ nil（调用方**不放枪**，照铁律②）。
    /// ⭐ 用途：PC 用 `N + 20s` 定**等多久**（`_need = int(_m.group(1)) + 20`），
    ///    ⛔ 不是固定 45s —— 多长的广告都等得起。
    static func adCountdownSeconds(_ img: UIImage, rec: Recognizer,
                                   bw: Double, bh: Double,
                                   roi: [Double]? = nil,
                                   secondsPatterns: [String]? = nil,
                                   fallbackPatterns: [String]? = nil) -> Int? {
        let t = adTopText(img, rec: rec, bw: bw, bh: bh, roi: roi)
            .replacingOccurrences(of: " ", with: "")
        // 顺序照 PC：先 `s后`，再 `秒后`；再看**宽松形**（`19后`）
        //
        // ⭐⭐⭐⭐ §2645 **两张表现在都可配**（`secondsPatterns` / `fallbackPatterns`）：
        //   · `secondsPatterns`  缺省 = `secondsPatternsDefault`（**逐字**照抄原来那 3 条）
        //   · `fallbackPatterns` 缺省 = `secondsFallbackDefault`（**逐字**照抄原来最后那 1 条）
        for pat in (secondsPatterns ?? Self.secondsPatternsDefault) {
            if let re = try? NSRegularExpression(pattern: pat),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)),
               m.numberOfRanges > 1,
               let rr = Range(m.range(at: 1), in: t),
               let n = Int(t[rr]) {
                return n
            }
        }
        // 最后兜底：任意 `\d+秒/s`
        for pat in (fallbackPatterns ?? Self.secondsFallbackDefault) {
            if let re = try? NSRegularExpression(pattern: pat),
               let m = re.firstMatch(in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)),
               m.numberOfRanges > 1,
               let rr = Range(m.range(at: 1), in: t),
               let n = Int(t[rr]) {
                return n
            }
        }
        return nil
    }

    /// ⭐⭐⭐⭐ §2645 **「倒计时还剩几秒」的主正则表** —— 逐字照抄改动前的 3 条。
    static let secondsPatternsDefault: [String] = [
        "([0-9]+)[sS]后",
        "([0-9]+)秒后",
        "([0-9]+)后",
    ]

    /// ⭐⭐⭐ §2645 **「倒计时还剩几秒」的最后兜底正则** —— 逐字照抄改动前那 1 条。
    static let secondsFallbackDefault: [String] = [
        "([0-9]+)\\s*(?:秒|[sS])",
    ]

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
            if Self.looksLikeAdPage(img, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                       roi: s?.ad_top_roi) {
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

    /// ⭐ 送到某个已知入口态（= PC `_ensure_entry_state(want:)`，`_1377_ad_loop.py:6753`）
    ///
    /// ## ⛔⛔⛔ §2612 修：**`want == "feed"` 原来走的是"回中心"，等于原地转圈**
    ///
    /// ### 真机血案（手机 `run_trace.log` 逐字）
    /// ```
    ///   §mall_ent_via_center ✅ 已在任务中心（第 1 步）
    ///   §mall_ent_via_center ✅ 已在任务中心（第 1 步）      ← 又一轮，还是原地
    ///   §mall_ent_via_center ✅ 已在任务中心（第 1 步）
    ///   §mall ⚠️ 没到 feed 首页 ⇒ 仍试一次进小店（它可重入）
    /// ```
    /// ### 根因
    /// 我原来**不管 `want` 是什么**，都调 `ensureInCenter(...)`。
    /// 而手机当时**已经在任务中心** ⇒ `ensureInCenter` 第 ① 步就
    /// `✅ 已在任务中心` **直接 return true** ⇒ **零动作** ⇒ 3 轮全废。
    /// 📏 于是 `enterMall` / `openSearch` 拿到"没到 feed"，接着在**任务中心**上
    ///    点"搜索框"（其实是标题行）⇒ 打字进空气 ⇒ 模块 D/E 全废。
    ///
    /// ### ✅ PC 的语义（`_1377_ad_loop.py:6786-6827`）
    /// ```python
    /// if want == "feed":
    ///     if feed_judge(img): return img, True          # 可重入
    ///     ...
    ///     _im, _ok = goto_feed("...")                   # ⭐ 要去 feed ⇒ **调 goto_feed**
    /// else:
    ///     if on_center(img): return img, True
    ///     ... ensure_in_center()  ...
    /// ```
    /// ⇒ **两个方向是两条不同的腿**：`want=="feed"` 走 `gotoFeed`（它含
    ///   §2611 的"金币中心入口行 ⇒ 去观看"那条腿），`want=="center"` 才走回中心。
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
            // ⭐ 照 PC：按 `want` 分腿（⛔ 不再统一"回中心" ⇒ 那在中心上等于零动作）
            if want == "feed" {
                log("   §\(tag) 在 \(here) ≠ feed ⇒ 走 `gotoFeed`（第 \(k + 1)/3 轮）")
                if gotoFeed(tag: "\(tag)_gf\(k)") {
                    log("   §\(tag) ✅ `gotoFeed` 成功")
                    // ⭐ 复判（照 PC：goto_feed 返回 ok 后再确认一次目标态）
                    if let i2 = grab(), nav.pageHere(i2) == "feed" { return true }
                    return true
                }
            } else {
                _ = ensureInCenter(tag: "\(tag)_via_center")
            }
            sleep(0.8)
        }
        return false
    }

    /// ⭐ 进信息流（= PC `goto_feed`，`_1377_ad_loop.py:4903`）
    ///
    /// # ⛔⛔⛔ §2611 **手机端缺了 PC 的"金币中心入口腿"** —— 这是 feed/tag/mall 三个模块全废的根因
    ///
    /// ## 真机血案（本轮 v0.10.63 日志，逐字）
    /// ```
    ///   §feat ▶️ 开始【刷视频】              18:48:36.165
    ///   §feed ⛔ 进不了信息流 ⇒ 停手         18:48:36.654   ← **0.5 秒就退出**
    ///   §tag_open ⛔ 到不了 feed 首页 ⇒ 打不开搜索页
    ///   §mall_ent_via_center ✅ 已在任务中心（原地转圈）
    /// ```
    /// ⇒ 三个模块**都靠 `gotoFeed`**，而它从金币中心**一次都没成功过**。
    ///
    /// ## 根因
    /// 我原来只做 `nav.step(from: "center")` —— 走**页面图**。
    /// 但看 config：`pages.center.go = null`（金币中心是"所有导航的终点"，没有 go 边）
    /// ⇒ `step` 没有出路可走 ⇒ `return false` ⇒ 立刻停手。
    ///
    /// ## ✅ PC 的做法（`_1377_ad_loop.py:4938-4959`，**逐字**）
    /// ```python
    /// if on_center(img):
    ///     # 真机 dump：'看视频赚金币'@(123,352) ｜ '去观看'@(393.8,364.0)
    ///     row_y = None
    ///     for t, cx, cy in words(img, (0, 300, 200, 977)):
    ///         if ("看视频" in t) and (("金币" in t) or ("赚" in t) or ("观看" in t)):
    ///             row_y = cy; break
    ///     if row_y is not None:
    ///         cands = [c for c in words(img, (300, row_y-45, 451, row_y+45))
    ///                  if ("观看" in c[0]) or c[0].strip().startswith("去")]
    ///         if cands:
    ///             cxm = max(c[1] for c in cands)
    ///             t2, cx2, cy2 = [c for c in cands if cxm - c[1] <= 30][0]
    ///             click_at(plog(cx2, cy2))        # ⭐ 点「去观看」
    ///             wait(5.0); continue
    /// ```
    /// 📏 关键（照 PC 的口径）：
    ///   · **同行合取**：标题行（左侧 `看视频`+`金币/赚/观看`）与右侧按钮（`去观看`/`去X`）
    ///     靠 **y ±45px** 绑定 ⇒ 换版式不用改代码
    ///   · ⛔ **绝不写死坐标**（任务行位置会变）
    ///   · ⛔ 找不到 ⇒ **不放枪**（继续走后面的腿）
    private func gotoFeed(tag: String) -> Bool {
        for _ in 0..<3 {
            if isCancelled() { return false }
            guard let img = grab() else { return false }
            if nav.pageHere(img) == "feed" { return true }
            if nav.runFunnel(img) { sleep(1.0); continue }
            let here = nav.pageHere(img) ?? "unknown"

            // ⭐⭐⭐ §2611 **金币中心 ⇒ 点「看视频赚金币」那一行的「去观看」**
            //    照 PC `goto_feed` L4938-4959（同行合取，⛔ 不写死坐标）
            if here == "center" {
                let ws = rec.ocrRegion(img, rect: CGRect(x: 0, y: 300, width: baseW, height: baseH - 300),
                                       minConfidence: 0.3)
                // ① 找"入口行"：左侧标题含 看视频 + (金币|赚|观看)
                var rowY: Double? = nil
                for (t, r, _c) in ws where r.minX <= 200 {
                    let s = t
                    if s.contains("看视频"),
                       (s.contains("金币") || s.contains("赚") || s.contains("观看")) {
                        rowY = Double(r.midY)
                        log("   §\(tag) 金币中心入口行「\(s)」@y=\(Int(rowY!))")
                        break
                    }
                }
                if let ry = rowY {
                    // ② 该行 ±45 内、x ≥ 300 的按钮，取最右（照 PC `max(c[1])`）
                    var cands: [(String, CGPoint)] = []
                    for (t, r, _c) in ws where r.midX >= 300 && abs(Double(r.midY) - ry) <= 45 {
                        let s = t
                        if s.contains("观看") || s.hasPrefix("去") {
                            cands.append((s, CGPoint(x: r.midX, y: r.midY)))
                        }
                    }
                    if let pick = cands.max(by: { $0.1.x < $1.1.x }) {
                        log("   §\(tag) 金币中心 ⇒ 点「\(pick.0)」@(\(Int(pick.1.x)),\(Int(pick.1.y)))（照 PC goto_feed）")
                        nav.tapPoint(Double(pick.1.x), Double(pick.1.y))
                        sleep(5.0)
                        continue
                    }
                    log("   §\(tag) 入口行右侧没扫到「去观看」⇒ 不放枪")
                } else {
                    log("   §\(tag) 金币中心没找到「看视频赚金币」入口行 ⇒ 试下面的腿")
                }
            }

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
    ///
    /// ## ⛔⛔ §2613 修第二处：`search_page` 元素**认不出"空的搜索页"**
    /// 真机决定性实验（`_dev/_2613_type_probe.py`）走了这条**完全正确**的链：
    /// ```
    ///   ① 任务中心 → ② 点「去观看」 → ③ 页型 = feed ✅
    ///   ④ 点放大镜 @(417,79) → ⑤ 页型 = search_page ✅（框内 '剑来'，有「历史搜索」）
    /// ```
    /// ⇒ 但 `search_page` 的判据是 `历史搜索/猜你想搜/搜索历史`，
    ///   而**刚点开、还没有任何历史时这三个词一个都没有** ⇒ `detect` 恒 nil
    ///   ⇒ `openSearch` 会**再点一次放大镜**（把已打开的搜索页当成 feed 继续点）。
    /// ✅ 补一条**结构性判据**：搜索页**恒有右上角的「搜索」按钮**（模板
    ///   `x_ref_ks_searchbtn.png`，PC 实测正样本 9/9 帧 0.995~1.000）
    ///   —— 这一条与"有没有历史"无关，所以空的搜索页也认得出。
    private func openSearch(tag: String) -> Bool {
        for _ in 0..<4 {
            if isCancelled() { return false }
            guard let img = grab() else { return false }
            // ① 可重入：已在搜索/结果页 ⇒ 成功（PC 铁律：先问这个，别重链）
            if nav.detect("search_page", img: img) != nil { return true }
            // ⭐ §2613 空的搜索页也认得出（判据与"有没有历史"无关）
            //
            // ⛔⛔ 为什么**不能**用 `nav.detect("search_btn")`（我第一版就写错了，已实测否掉）：
            //   `search_btn` 是**模板**元素（`x_ref_ks_searchbtn.png`，阈值 0.8），
            //   而本机真机帧上它的 NCC 只有 **0.168 / 0.275**（§2613 离线复算）⇒ **恒 miss**。
            //   ⇒ 用它当判据等于**没加**。
            // ✅ 改用 **PC `ks_find_search_key` 的 OCR 腿**（`_1377_ad_loop.py:5704` 逐字）：
            //   ```python
            //   cands = [(cx, cy) for t, cx, cy in words(img, (340, 55, 451, 115))
            //            if t.strip() == "搜索"]
            //   ```
            //   本机真机帧实测（§2613，四帧对照，**零误报**）：
            //     · 搜索页（空历史）  `_2613_s5_search.jpg`    ⇒ `搜索`@(411.5, 81.3) ✅ 命中
            //     · 搜索页（打字后）  `_2613_s6a_raw.jpg`      ⇒ `搜索`@(411.5, 81.3) ✅ 命中
            //     · feed             `_2613_s3_feed.jpg`      ⇒ **无** ✅ 不误报
            //     · 任务中心         `_2613_s1_now.jpg`       ⇒ **无** ✅ 不误报
            if searchKeyPoint(img) != nil {
                log("   §\(tag) ✅ 已在搜索页（右上角读到「搜索」按钮 ⇒ 结构性判据，照 PC `ks_find_search_key`）")
                return true
            }
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
    ///
    /// ## ⛔⛔⛔ §2612 修：**可重入判据曾在「任务中心」误命中 ⇒ 整个模块 E 空转**
    ///
    /// ### 真机血案（手机 `run_trace.log`，252 轮全是这个）
    /// ```
    ///   §mall_ent_via_center ✅ 已在任务中心（第 1 步）
    ///   §mall ⚠️ 没到 feed 首页 ⇒ 仍试一次进小店（它可重入）
    ///   §mall ── 第 1 轮：搜「吸尘器」
    ///      §mall1 点搜索框 @(69,81)      ← ⛔ 这是**任务中心的标题行**，不是搜索框
    ///      §mall1 HID 打字 T:xichenqi
    ///      §mall1 ⚠️ 没看到 IME 候选栏      ← 打字进了空气
    /// ```
    /// ### 根因（两条叠加）
    /// ① **配置层**：`mall_entry` 的 ROI `(0,60,451,160)` 在任务中心页上命中的是
    ///    顶栏「**金币商城**」（含子串「商城」）⇒ `min_hits=1` 命中
    ///    ⇒ 第 ① 步 `return true` ⇒ **一步都不走**。
    ///    ✅ 已在 `config.json` 给该元素加 `not_words:["金币"]`（照 PC「排除含金币的 token」）。
    /// ② **代码层**：`enterMall` 用 `mall_entry` 当作"**已在小店首页**"的判据 ——
    ///    而它其实只是"**页面上有个商城入口**"。（PC 用的是**两个不同**判据：
    ///    `ks_on_mall_home` = 小店首页专属词 **≥3 个**；`mall_entry` 只是要点的 tab。）
    ///    ⇒ 现在**分开**：`pageHere == "mall"`（= `mall_marker`，`min_hits=2`，
    ///      语义就是"我的订单/购物车/充值中心/低价特卖/赚金币"这类**小店首页专属词**）
    ///      ⛔ 不再拿入口词当"已经进店了"。
    private func enterMall(tag: String) -> Bool {
        for _ in 0..<4 {
            if isCancelled() { return false }
            guard let img = grab() else { return false }
            // ① 可重入：真在小店页 ⇒ 成功
            //    ⛔ §2612：**只看页型**，不再拿 `mall_entry`（入口词）冒充"已在店里"
            if nav.pageHere(img) == "mall" { return true }
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

        // ③ ⭐ 打拼音 —— ⚠️ 必须**分段**发（§1748：一次性发会掉键 ⇒ 候选栏拼不出词）
        guard let py = Pinyin.of(word) else {
            log("   §\(tag) ⚠️ 「\(word)」转不出拼音 ⇒ 跳过这个词")
            return false
        }
        log("   §\(tag) HID 打字 T:\(py)（\(word)）")
        typePinyin(py, tag: tag)

        // ④ ⭐⭐ **落中文硬闸**：框内必须真出现中文
        guard landChinese(word, tag: tag) else {
            return false
        }

        // ⑤ 点「搜索」—— ⭐ 照 PC `ks_find_search_key`（L5694）的**腿序**：OCR 首选 → 模板兜底
        //
        // ⛔ §2613 实测：本机真机帧上 `search_btn` 的**模板** NCC 只有 0.168（阈值 0.8）
        //    ⇒ `nav.detect("search_btn")` **恒 miss** ⇒ 我原来每次都掉进 `K:RETURN` 兜底。
        // ✅ PC 的 OCR 腿在本机**稳**（四帧对照零误报：搜索页命中 @(411.5,81.3)、
        //    feed/任务中心无）⇒ 首选 OCR，模板退为兜底（照 PC 的腿序，⛔ 不删任何一条）。
        guard let i3 = grab() else { return false }
        if let sk = searchKeyPoint(i3) {
            log("   §\(tag) 点「搜索」@(\(Int(sk.x)),\(Int(sk.y)))（OCR 腿，照 PC）")
            nav.tapPoint(Double(sk.x), Double(sk.y))
        } else if nav.detect("search_btn", img: i3) != nil {
            log("   §\(tag) OCR 没读到「搜索」⇒ **模板腿**兜底")
            _ = nav.tap("search_btn", img: i3)
        } else {
            log("   §\(tag) ⚠️ 两条腿都没命中「搜索」按钮 ⇒ 用回车兜底")
            ble.send("K:RETURN")
        }
        sleep(2.0)
        return true
    }

    /// ⭐ 右上**「搜索」按钮**的**OCR 腿** —— 照 PC `ks_find_search_key`（`_1377_ad_loop.py:5704`）
    ///
    /// ```python
    /// cands = [(cx, cy) for t, cx, cy in words(img, (340, 55, 451, 115)) if t.strip() == "搜索"]
    /// if cands:
    ///     return max(cands, key=lambda c: c[0])      # ⭐ 取**最右**那个
    /// ```
    /// ⚠️ 为什么取最右：**结果页/视频页也有「搜索」字样**，取最右才落在真正的按钮上。
    ///
    /// 📏 本机真机帧实测（§2613，四帧对照，**零误报**）：
    /// ```
    ///   搜索页（空历史）  _2613_s5_search.jpg   ⇒ 搜索 @(411.5,81.3) ✅
    ///   搜索页（打字后）  _2613_s6a_raw.jpg     ⇒ 搜索 @(411.5,81.3) ✅
    ///   feed             _2613_s3_feed.jpg     ⇒ 无 ✅
    ///   任务中心         _2613_s1_now.jpg       ⇒ 无 ✅
    /// ```
    private func searchKeyPoint(_ img: UIImage) -> CGPoint? {
        let roi = CGRect(x: 340, y: 55, width: 111, height: 60)
        let items = rec.ocrRegion(img, rect: roi, minConfidence: 0.3)
        let hits = items.filter { $0.0.trimmingCharacters(in: .whitespaces) == "搜索" }
        guard let best = hits.max(by: { $0.1.midX < $1.1.midX }) else { return nil }
        return CGPoint(x: best.1.midX, y: best.1.midY)
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

    // MARK: - ⭐⭐⭐⭐⭐ §2612 **落中文**（照 PC `_box_ok` + 腿序逐条移植）

    /// PC `KS_BAND_SUGG`（`_1377_ad_loop.py:5845`）—— 快手搜索**联想词列表**带。
    ///
    /// ⚠️ 必须**避开 IME 候选条**（`bandCand` = y98~144），否则会把 `1 防止游戏`
    /// 那种同音错字当成联想词读进来。
    private static let bandSugg = CGRect(x: 0, y: 150, width: 451, height: 690)

    /// PC `KS_BAND_CAND`（`_1377_ad_loop.py:5731`）—— iOS **IME 候选栏**带（真机候选行 y≈116）
    private static let bandCand = CGRect(x: 0, y: 98, width: 451, height: 46)

    /// PC `FUZZY_BAD_KEYS`（`_1377_ad_loop.py:5747`）—— **逐字**，⛔ 不许删减
    ///
    /// PC 原文：负面/灰产/求助类的联想词会把画像打歪（`小红被永久封禁了怎么解除`
    /// 是"账号被封"语境，不是"小红书这个产品"），甚至引向灰产（`小红代发一单一结的`）。
    static let fuzzyBadKeys: [String] = [
        "封禁", "解封", "破解", "免费领", "领取", "代发", "刷单", "兼职",
        "一单一结", "投诉", "退款", "解除", "怎么解除", "注销", "申诉",
        "外挂", "脚本", "辅助", "破解版", "无限", "私服", "租号", "卖号",
        "客服电话", "人工客服", "被骗", "骗局", "套路", "翻车", "塌房",
    ]

    /// ⭐⭐⭐⭐⭐ §2612 **本函数是「落中文」全程失败（251/251）的根治点**
    ///
    /// # ⛔⛔ 病：我漏掉了 PC 的**整条联想词腿**（两条腿里的第一条）
    ///
    /// ## 真机铁证（§2612 从手机自己的 `run_trace.log` 数出来）
    /// ```
    ///   HID 打字           252 次
    ///   没看到 IME 候选栏   251 次   ← 一次候选栏都没见过
    ///   落中文成功            0 次
    ///   §tag 轮次             0 次   ← 模块 D 一整轮都没跑起来
    /// ```
    ///
    /// ## ⛔ 我原来的错（两层）
    /// ① `landChinese` **只做了 PC 的腿②**（IME 候选栏），**腿①（联想词）根本没有**；
    /// ② `boxHas` 只看**框内文本** —— 而真机框内是**灰色 marked text**，
    ///
    ///    **OCR 读不到**（§2412/§2613 实测：框内 OCR 出 `''`，而联想列表全是中文）。
    /// ⇒ 判据恒 false ⇒ `没落成中文 ⇒ 不提交` ⇒ **47 轮全部白跑**。
    ///
    /// ## ✅ 本机真机帧实测（`_var/_2613_s6a_raw.jpg`，§2613 决定性实验）
    /// 只发一次 `T:xiyiji`（一个字都没多打）之后：
    /// ```
    ///   框内 OCR        = ''                    ← 灰色 marked text，读不到
    ///   IME 候选栏      = 0 项                  ← 真机确实没有带编号的候选条
    ///   联想词列表：
    ///     洗衣机 @(88.5,190.8)   ← ⭐ **完全一致**的那一行
    ///     洗衣机哪个牌子好用又耐用 / 洗衣机清洗剂 / 洗衣机工厂直发 / …
    ///     ⇒ 以「洗衣机」开头的行 = **9 行**（≥2）
    /// ```
    /// ⇒ **PC 的 `_box_ok` 第二判据当场成立** ⇒ 应该判"已落中文"并点联想词。
    ///
    /// ## ✅ PC `_box_ok`（`_1377_ad_loop.py:6255`）—— **逐字照抄**
    /// ```python
    /// _g = ks_box_text(im)
    /// if word and word in _g:                       return True,  "框内 %r" % _g
    /// _cand = ks_ime_candidates(im)
    /// if _cand:                                     return False, "IME 候选栏还在（marked text 未提交）"
    /// _sugg = [s for s in words(im, KS_BAND_SUGG)]
    /// _pfx  = [s for s in _sugg if s.startswith(word)]
    /// if len(_pfx) >= 2:                            return True,  "候选栏已消失 + 联想列表 N 行以词开头"
    /// return False, "框内 %r ｜ 候选栏空 ｜ 联想仅 N 行"
    /// ```
    /// ⚠️ 为什么要三条**合取**（PC 的注释就是血案）：
    ///   · 只看框内 ⇒ 灰色 marked text 读不到 ⇒ 把**成功**判成失败；
    ///   · 只看联想列表 ⇒ 生拼音态**照样**有一堆以目标词开头的行 ⇒ 把**生拼音**判成成功。
    ///   ⇒ 正解 = 「框内含词」**或**「候选栏已消失（marked text 已提交）**且**联想 ≥2 行以词开头」。
    private func boxOk(_ img: UIImage, word: String) -> (Bool, String) {
        let inBox = boxText(img)
        // ① 框内已含目标词（PC 用**包含**，不是全等 —— 左侧放大镜会被读成 `Q`）
        if !word.isEmpty, inBox.contains(word) {
            return (true, "框内 \(inBox)")
        }
        // ② IME 候选栏还在 ⇒ marked text **未提交** ⇒ 一定没落好
        let cand = imeCandidates(img)
        if !cand.isEmpty {
            return (false, "框内 \(inBox) ｜ IME 候选栏还在（\(cand.count) 项，marked text 未提交）")
        }
        // ③ 候选栏已消失 **且** 联想列表 ≥2 行以目标词开头
        let sugg = suggRows(img).map(\.0)
        let pfx = word.isEmpty ? [] : sugg.filter { $0.hasPrefix(word) }
        if pfx.count >= 2 {
            return (true, "候选栏已消失 + 联想列表 \(pfx.count) 行以「\(word)」开头（\(pfx[0].prefix(10))…）")
        }
        return (false, "框内 \(inBox) ｜ 候选栏空 ｜ 联想仅 \(pfx.count) 行以「\(word)」开头")
    }

    /// ⭐⭐ **落中文**（照 PC `ks_type_word` 的**完整腿序**，`_1377_ad_loop.py:6277`）
    ///
    /// ## PC 的腿序（⚠️ 我原来只有②，缺①/①b/②b —— 见 `boxOk` 注释）
    /// ```
    /// ⓪ _box_ok          （框内 / 候选栏 / 联想词 三合取）
    /// ① 联想词**完全一致**（§1737k 真机正解 —— 点它常**直出结果页**）
    /// ①b 联想词**挑匹配的**（§1749 fuzzy，⛔ 过负面词/同音错字闸）
    /// ② IME 候选栏**精确**命中 ⇒ 发数字键
    /// ②b IME 候选栏**挑匹配的**（§1749 fuzzy）
    /// ⇒ 全不成 ⇒ **绝不出手**（⛔ 绝不提交拼音，用户令）
    /// ```
    /// ⚠️ **编号只能从字面 OCR 读，⛔ 不能"按位置序号推"**（PC L5727）：
    /// > 2 号是 emoji 候选，OCR 会跳过，按位置推会把 3 号当成 2 号 ⇒ **选中错的字**
    ///
    /// ⭐ 返回值语义（照 PC）：`true` = **框内真的出现了目标中文词**，调用方**才可以**提交。
    @discardableResult
    private func landChinese(_ word: String, tag: String) -> Bool {
        guard var im = grab() else { return false }

        // ⓠ ⓪ 先自证（有的输入法直接上屏 / 已经是中文）
        var (ok, ev) = boxOk(im, word: word)
        if ok {
            log("   §\(tag) ✅ 打字后已是中文：\(ev)")
            return true
        }
        log("   §\(tag) 未落中文（\(ev)）⇒ 走落中文腿序")

        // ⭐ ① 联想词**完全一致**（§1737k 真机正解）
        if let hit = findSuggWord(im, word: word, fuzzy: false) {
            log("   §\(tag) ① 联想词完全一致「\(hit.0)」⇒ 点它 @(\(Int(hit.1.x)),\(Int(hit.1.y)))")
            nav.tapPoint(Double(hit.1.x), Double(hit.1.y))
            sleep(2.0)
            if let i2 = grab() {
                im = i2
                (ok, ev) = boxOk(im, word: word)
                if ok {
                    log("   §\(tag) ✅ 落中文成功（联想词）：\(ev)")
                    return true
                }
                log("   §\(tag) ⚠️ 点了联想词但仍未落好（\(ev)）⇒ 换下一条腿")
            }
        } else {
            log("   §\(tag) ① 联想词里没有与「\(word)」**完全一致**的行")
        }

        // ⭐ ①b 联想词**挑匹配的**（§1749：拓展标签随机性，更像真人）
        if let hit = findSuggWord(im, word: word, fuzzy: true) {
            log("   §\(tag) ①b 联想词挑匹配的「\(hit.0)」⇒ 点它 @(\(Int(hit.1.x)),\(Int(hit.1.y)))（§1749）")
            nav.tapPoint(Double(hit.1.x), Double(hit.1.y))
            sleep(2.0)
            if let i2 = grab() {
                im = i2
                (ok, ev) = boxOk(im, word: word)
                if ok {
                    log("   §\(tag) ✅ 落中文成功（联想词·挑匹配）：\(ev)")
                    return true
                }
                log("   §\(tag) ⚠️ 点了联想词但仍未落好（\(ev)）⇒ 换下一条腿")
            }
        }

        // ⭐ ② IME 候选栏**精确**命中 ⇒ 发数字键（§1737b 真机验过 `T:1`）
        let cands = imeCandidates(im)
        if !cands.isEmpty {
            log("   §\(tag) IME 候选 \(cands.count) 项："
                + cands.map { "\($0.0)\($0.1)" }.joined(separator: " "))
            if let hit = cands.first(where: { $0.1 == word }) {
                log("   §\(tag) ② 选候选 \(hit.0)（\(hit.1)）")
                ble.send("T:\(hit.0)")
                sleep(1.2)
                if let i2 = grab() {
                    im = i2
                    (ok, ev) = boxOk(im, word: word)
                    if ok {
                        log("   §\(tag) ✅ 落中文成功（候选 \(hit.0)）：\(ev)")
                        return true
                    }
                }
            } else {
                log("   §\(tag) ② 候选里没有与「\(word)」**完全一致**的项 ⇒ 不按数字键")
            }
            // ⭐ ②b 候选栏挑匹配的（§1749）
            if let n2 = pickImeCandidate(im, word: word) {
                log("   §\(tag) ②b IME 候选挑匹配的 ⇒ 发数字键 \(n2)（§1749）")
                ble.send("T:\(n2)")
                sleep(1.2)
                if let i2 = grab() {
                    im = i2
                    (ok, ev) = boxOk(im, word: word)
                    if ok {
                        log("   §\(tag) ✅ 落中文成功（候选·挑匹配 \(n2)）：\(ev)")
                        return true
                    }
                }
            }
        } else {
            log("   §\(tag) ② 没看到 IME 候选栏（真机常有 —— 此时靠①/①b 的联想词腿）")
        }

        log("   §\(tag) ⛔ 两条腿都没把「\(word)」落成中文（\(ev)）⇒ **不提交**（用户令：拼音绝对不行）")
        return false
    }

    /// ⭐ 读 iOS **IME 候选栏** ⇒ `[(编号, 词, 框)]`（编号从**字面**读，照 PC `ks_ime_candidates`）
    ///
    /// PC 实测：iOS 候选栏在 `y≈98~144`（基准尺度），每项形如 `1汽车`
    private func imeCandidates(_ img: UIImage) -> [(Int, String, CGRect)] {
        var out: [(Int, String, CGRect)] = []
        for (t, r, _c) in rec.ocrRegion(img, rect: Self.bandCand, minConfidence: 0.3) {
            // 形如「1汽车」/「3 汽车站」⇒ 抠出编号和词
            let s = t.trimmingCharacters(in: .whitespaces)
            guard let first = s.first, let n = Int(String(first)), n >= 1, n <= 9 else { continue }
            let rest = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { continue }
            out.append((n, rest, r))
        }
        return out
    }

    /// ⭐⭐ 读**快手搜索联想词列表** ⇒ `[(词, 中心点)]`（照 PC `words(img, KS_BAND_SUGG)`）
    ///
    /// PC 在比对前会把空格去掉（`t.strip().replace(" ", "")`）—— 照抄。
    private func suggRows(_ img: UIImage) -> [(String, CGPoint)] {
        rec.ocrRegion(img, rect: Self.bandSugg, minConfidence: 0.3).compactMap { (t, r, _c) in
            let s = t.replacingOccurrences(of: " ", with: "")
            guard !s.isEmpty else { return nil }
            return (s, CGPoint(x: r.midX, y: r.midY))
        }
    }

    /// ⭐⭐⭐ 在**联想词**里找与目标词匹配的那一行（照 PC `ks_find_sugg_word`，L5948）
    ///
    /// ⛔ 默认**只认完全一致**：联想列表里满是"目标词 + 后缀"的行（`洗衣机清洗剂`）
    ///    —— 那些是**另一个查询**，会把搜索词带偏（打标签要的是**这个词本身**）。
    /// ⭐ `fuzzy: true` = §1749「挑匹配的」：同音相关（包含 / 首字相同）+ 纯汉字 + **随机**挑，
    ///    且**必须**过 `fuzzyBadKeys` 负面词闸与同音错字闸（照 PC L5980-5989）。
    private func findSuggWord(_ img: UIImage, word: String, fuzzy: Bool)
        -> (String, CGPoint)? {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return nil }
        let rows = suggRows(img)
        // ① 完全一致优先（能精确就精确 —— 目标词就是我们要的标签）
        for (t, p) in rows where t == w { return (t, p) }
        guard fuzzy else { return nil }
        // ② §1749 模糊挑：同音相关 + 纯汉字 ⇒ 随机
        var pool: [(String, CGPoint)] = []
        for (t, p) in rows {
            if t == w { continue }
            // ⛔ 必须纯汉字（不是拼音串）
            guard t.allSatisfy({ $0 >= "\u{4e00}" && $0 <= "\u{9fff}" }) else { continue }
            // ③ 同音相关：包含关系 或 首字相同（保证"音对"）
            guard t.contains(w) || w.contains(t) || t.first == w.first else { continue }
            // ④ ⛔ 负面/灰产/求助类（打歪画像）
            if Self.fuzzyBadKeys.contains(where: { t.contains($0) }) { continue }
            // ⑤ ⛔ 同音错字闸：同长且只差一字 ⇒ 那个字是错别字（`小红鼠`/`小红水`）
            if t.count == w.count, zip(t, w).filter({ $0 != $1 }).count == 1 { continue }
            pool.append((t, p))
        }
        return pool.randomElement()
    }

    /// ⭐ §1749 IME 候选栏「挑匹配的」（照 PC `ks_pick_ime_candidate(fuzzy=True)`，L5800）
    private func pickImeCandidate(_ img: UIImage, word: String) -> Int? {
        let w = word.trimmingCharacters(in: .whitespaces)
        var pool: [(Int, String)] = []
        for (n, t, _r) in imeCandidates(img) {
            if t == w { continue }
            guard t.allSatisfy({ $0 >= "\u{4e00}" && $0 <= "\u{9fff}" }) else { continue }
            guard t.contains(w) || w.contains(t) || t.first == w.first else { continue }
            if Self.fuzzyBadKeys.contains(where: { t.contains($0) }) { continue }
            if t.count == w.count, zip(t, w).filter({ $0 != $1 }).count == 1 { continue }
            pool.append((n, t))
        }
        return pool.randomElement()?.0
    }

    /// ⭐ 搜索框内当前文本（照 PC `ks_box_text` 的带 `(0, 55, 340, 100)`）
    private func boxText(_ img: UIImage) -> String {
        rec.ocrRegion(img, rect: CGRect(x: 0, y: 55, width: 340, height: 45),
                      minConfidence: 0.3).map(\.0).joined()
    }

    /// ⭐⭐ **分段打拼音**（照 PC `_type_pinyin_chunked`，`_1377_ad_loop.py:6136`）
    ///
    /// ## ⛔ PC 的血案（真机 `_var/_1747_tag_live4.log` + 固件源码 L96-97）
    /// 固件 `if (t == 'T') { Keyboard.print(a); }` —— **一次性**把整串塞进 BLE HID，
    /// **零逐字延时**。而 BLE HID 在快速连发时会**丢键**：
    /// ```
    ///   发 zhangjianchuanshuo（18 字母）⇒ 框里只到了 zhangijian chuan sh（尾巴全丢）
    /// ```
    /// ⇒ 输入法候选栏**拼不出目标词** ⇒ 落中文硬闸**正确地拒绝提交** ⇒ 该词一轮白跑。
    /// ⚠️ 短词不丢 ⇒ 所以这个 bug **只在大词上暴露**，一直没被发现。
    ///
    /// ## ✅ PC 的修法（⛔ 不改固件、⛔ 不改 `T:` 协议）
    /// **在上位机把拼音切成小段**，逐段发 `T:`，段间 `sleep` 让 BLE 栈喘口气：
    ///   · 段长 **6 个字母**（实测安全；`zhihu`/`dewu` 这类短词就一段，行为不变）
    ///   · 段间 **0.35s**
    private func typePinyin(_ py: String, tag: String) {
        let chunk = 6
        guard py.count > chunk else {
            ble.send("T:\(py)")                   // 短词：**一字不改**（旧行为）
            sleep(1.2)
            return
        }
        let parts = stride(from: 0, to: py.count, by: chunk).map { i -> String in
            let s = py.index(py.startIndex, offsetBy: i)
            let e = py.index(s, offsetBy: chunk, limitedBy: py.endIndex) ?? py.endIndex
            return String(py[s..<e])
        }
        log("   §\(tag) §1748 拼音 \(py.count) 字母 ⇒ **分 \(parts.count) 段**发"
            + "（每段 ≤\(chunk)，段间 0.35s；防 BLE 掉键）")
        for (i, p) in parts.enumerated() {
            ble.send("T:\(p)")
            if i < parts.count - 1 { sleep(0.35) }
        }
        sleep(1.2)
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

    // MARK: - ⛔⛔⛔ 用户红线：禁点词硬闸（照 PC `forbidden()` 逐字移植）

    /// PC `FORBID_KEYS`（`_1377_ad_loop.py:448`）—— **逐字**，⛔ 不许删减
    ///
    /// ## PC 原文（事故经过，必须记住）
    /// > 货速发那条广告底部的「**立即秒杀**」是红色药丸，`pink_bands` 按**形状**直接命中并点下去
    /// > ⇒ 打开了快手小店收银台「待支付 ¥9.9」，屏幕上出现「确认支付 / 继续支付」，
    /// >   用户看见以为在买东西。
    /// > 用户口径：**可以浏览，绝不做支付/购买**。
    /// > ⇒ 用户口径 > 形状判据，形状优先从此**必须让位于这张黑名单**。
    ///
    /// ⛔⛔ 手机端**原来一条都没有**（`_dev/_2440_port_diff.py` 粗筛 + 全量搜 Swift 均 0 命中）
    /// ⇒ 这是**移植差集里最要命的一条**：踩下去就是"在帮用户买东西"。
    static let forbidKeys: [String] = [
        "支付", "付款", "结算", "收银", "购买", "下单", "确认订单", "立即买", "去支付",
        "继续支付", "确认支付", "秒杀", "抢购", "立即抢", "加购", "购物车", "进店",
        "开通", "续费", "充值", "免密", "刷脸", "人脸", "花呗", "白条",
    ]

    /// PC `REJECT_CLICK_KEYS`（`_1377_ad_loop.py:471`）—— 照抄雷神的"拒绝点击"词表
    ///
    /// PC 原文：「雷神踩过的坑：**屏底那几条广告条/版本号**长得像按钮，点了会乱跑 ⇒ 一律拉黑。」
    /// ⛔ 唯一**故意没抄**的两条：裸 `功能` 与裸 `|`（会误伤正常文案）。
    static let rejectClickKeys: [String] = [
        "88元", "大额福利", "去星图", "版本号", "每日听歌赚钱", "每日领现金",
    ]

    /// ⛔ 点击前**统一过闸**：文案含黑名单任一词 ⇒ 拒绝点击。返回命中的词（便于日志），否则 nil。
    ///
    /// 移植自 PC `forbidden()`（`_1377_ad_loop.py:474`）——**语义逐字一致**。
    /// ⚠️ 用法契约（照 PC）：**调用方拿到非 nil 就必须放弃这次点击**，
    ///    ⛔ 不是"换个坐标再试"、⛔ 不是"只记日志"。
    ///
    /// ⭐⭐⭐⭐⭐ §2645 **配置化**（`settings.forbid_keys`，缺省 = 上面那 25 条硬编码）。
    ///
    /// ## ⛔⛔ 为什么配置化**必须**配自检（用户红线：支付）
    /// 这张表是「**可以浏览，绝不做支付/购买**」的唯一执行点。
    /// 放进文件后，一个手滑就能把「确认支付」删掉 ⇒ 真去帮用户买东西。
    /// ⇒ `ConfigStore.validate()` 做**加法校验**：只许加、⛔ 不许减；
    ///   删了任何一条基线 ⇒ `/reload` **拒绝加载**并把错误塞进 `configErrors`。
    static func forbidden(_ text: String?, extraKeys: [String]? = nil) -> String? {
        let t = text ?? ""
        // ⭐ 读调用方传进来的**配置表**；⛔ 不传（nil）⇒ 逐字走原来的硬编码 25 条
        for k in (extraKeys ?? forbidKeys) where t.contains(k) { return k }
        for k in rejectClickKeys where t.contains(k) { return k }
        return nil
    }

    /// PC `BOX_SHOPBAR` / `SHOP_AD_KEYS`（`_1377_ad_loop.py:455`）—— 购物/电商型广告判据带
    ///
    /// 判据带 = 快手小店商品页底部那条固定工具条（进店/客服/购物车）+
    /// 「秒杀价/已抢/已售/限时秒杀」那排促销信息。
    static let boxShopBar = CGRect(x: 0, y: 875, width: 451, height: 102)
    static let shopAdKeys: [String] = [
        "秒杀", "购物车", "进店", "客服", "立即购买", "加购", "去购买",
        "领券购买", "已抢", "已售", "限时秒杀", "找同款",
    ]

    /// 照 PC `is_shop_ad`：底部工具条里是否出现购物/电商型关键词。返回 (是否, 命中词)。
    private func isShopAd(_ img: UIImage) -> (Bool, [String]) {
        let ws = rec.ocrRegion(img, rect: Self.boxShopBar, minConfidence: 0.3)
        let hit = ws.map(\.0).filter { t in Self.shopAdKeys.contains { t.contains($0) } }
        return (!hit.isEmpty, hit)
    }

    // MARK: - ⭐⭐⭐ 转化：点 CTA（照 PC `click_cta`，⛔ 形状优先但必须让位于黑名单）

    /// PC `BOX_BOT` / `CTA_KEYS`（`_1377_ad_loop.py`）—— 底部 CTA 带与文案兜底词表
    static let boxCta = CGRect(x: 0, y: 760, width: 451, height: 217)
    static let ctaKeys: [String] = [
        "了解详情", "查看详情", "立即下载", "免费预约", "去看看", "去了解",
        "立即查看", "点击查看", "去逛逛", "立即参与", "去体验", "去咨询",
    ]

    /// ⭐⭐⭐ §2645 **CTA 药丸颜色判据的默认值** —— 改动前的硬编码 `r>200 && g<120 && b<150`。
    ///
    /// ⚠️ 真机实测：底部按钮是 **RGB(240,72,0)**（**橙色**）—— 恰好也满足粉色判据，
    ///   所以形状腿**其实能命中**（离线 18/18 帧命中且居中）。
    ///   ⇒ 配置化**不改行为**（默认值逐字相同），只是让"换版式换颜色"不必重编译。
    static let ctaColorDefault = (rMin: 200.0, gMax: 120.0, bMax: 150.0)

    /// ⭐ 点广告页底部的 CTA —— 逐条移植 PC `click_cta`（`_1377_ad_loop.py:1044`）。
    ///
    /// ## PC 的三步（⛔ 顺序不能变）
    /// ```
    /// ① 硬闸：is_shop_ad → 直接拒绝（购物广告不转化，用户口径）
    /// ② 形状优先：底部**最宽**粉色药丸，且**必须居中**（|cx-225| ≤ 10）
    ///    ⛔ §1522 真机：不居中就点到 scr(88,886) 的创意红条 ⇒ "转化"名存实亡
    ///    命中后**再 OCR 复核文案**，含 FORBID_KEYS ⇒ 拒绝
    /// ③ 文案兜底：CTA_KEYS 命中 + 粉色质心；再不行用偏心粉带当"一次广告点击"
    /// ```
    /// - Returns: 点到了哪条腿（供日志）；nil = 没点（⛔ 不放枪）
    private func clickCTA(_ img: UIImage, tag: String) -> String? {
        // ① 硬闸：购物/电商型广告
        let (shop, shopHit) = isShopAd(img)
        if shop {
            log("   §\(tag) ⛔ 购物/电商型广告（底栏命中 \(shopHit.prefix(3))）⇒ **拒绝点 CTA**")
            return nil
        }
        // ② 形状优先：底部最宽粉色药丸（纯像素，⛔ 不过 OCR）
        //
        // ⛔⛔ §2631 **居中判据必须按"基准宽度"比**（全局适配）
        // `widestPinkBand` 已**先归一到基准**（451×977）⇒ 它返回的 `cx` 是**基准坐标**；
        // 而这里原来拿 `img.size.width`（**原始帧宽**，888）来比 ⇒ 基准坐标 vs 原始宽
        // ⇒ 永远不"居中" ⇒ 形状腿恒废（⛔ 又一个我没适配的点）。
        // ✅ 改成按 `baseW`（基准宽）比。
        if let band = Self.widestPinkBand(img, box: Self.boxCta,
                                          color: s?.cta_color) {
            let cx = band.0, cy = band.1
            let off = abs(cx - baseW / 2.0)
            if off <= 10 {
                // 复核文案（形状过了不代表能点）
                let t = rec.ocrRegion(img, rect: CGRect(x: 0, y: max(0, cy - 26),
                                                        width: 442, height: 52),
                                      minConfidence: 0.3).map(\.0).joined()
                if let bad = Self.forbidden(t, extraKeys: forbidKeysCfg) {
                    log("   §\(tag) ⛔ 形状命中的药丸文案含违规词「\(bad)」⇒ **拒绝点击**")
                    return nil
                }
                log("   §\(tag) 形状优先：居中粉药丸 @(\(Int(cx)),\(Int(cy))) 文案「\(t.prefix(14))」过闸")
                nav.tapPoint(cx, cy)
                return "形状优先"
            }
            log("   §\(tag) 粉药丸不居中（cx=\(Int(cx))，偏离 \(Int(off))）⇒ 不用形状腿")
        }
        // ③ 文案兜底
        let ws = rec.ocrRegion(img, rect: Self.boxCta, minConfidence: 0.3)
        for (t, r, _c) in ws {
            guard ctaKeysCfg.contains(where: { t.contains($0) }) else { continue }
            if let bad = Self.forbidden(t, extraKeys: forbidKeysCfg) {
                log("   §\(tag) ⛔ CTA 文案「\(t)」含违规词「\(bad)」⇒ 跳过")
                continue
            }
            log("   §\(tag) 文案兜底：CTA「\(t)」@(\(Int(r.midX)),\(Int(r.midY)))")
            nav.tapPoint(Double(r.midX), Double(r.midY))
            return "文案兜底"
        }
        log("   §\(tag) ⛔ 没找到可点的 CTA（过闸后）⇒ 停手，⛔ 不盲点")
        return nil
    }

    /// 在 box 里找**最宽的粉色横带**，返回 (cx, cy, 宽度)；没有 ⇒ nil。
    ///
    /// 照 PC `pink_bands`：纯像素判据（⛔ 不过 OCR）—— CTA 的**形状不变、只有文案会变**。
    ///
    /// # ⛔⛔⛔ §2631 **全局适配：必须先归一到基准，才能按基准 box 索引像素**
    ///
    /// ## 用户令（逐字）
    /// > 「**你换了图片识别好像搞崩了程序 现在全识别未知了。你要做好全局适配啊**」
    ///
    /// ## ⛔ 我犯的错（本轮）
    /// 我把录屏扩展的 `outWidth` 从 451 改成 0（原分辨率，帧变 **888×1920**），
    /// 但**忘了**这类函数是**直接在原图上按像素索引**、而 `box` 是**基准坐标**：
    /// ```swift
    /// let bx = Int(box.minX)          // 基准 0
    /// let bw = Int(box.width)         // 基准 451
    /// for x in bx..<(bx+bw) { ... }   // ⛔ 但扫的是**原图**的 0..451
    /// ```
    /// ⇒ 帧一变大，它扫的就变成**左上角一小块**（888 宽里的 451 宽）
    ///   ⇒ 判据全落在错的区域 ⇒ 认不出 ⇒ **全 unknown**（用户看到的现象）。
    ///
    /// ## ✅ 全局修法 = 照本仓库**已有**的约定（⛔ 不是新发明）
    /// `ColorBlob.findCoinBall`（第 60 行）与 `ModalX.find`（第 58 行）**早就是**这个做法：
    /// ```swift
    /// let base = FrameNormalizer.normalize(img)   // ⭐ 先归一，再按基准索引
    /// ```
    /// ⇒ 本函数以及同类的像素函数（`looksLikeAppStorePage` / `findDownloadCloud` /
    ///   `clickCTA` 的居中判据）**一律照此办理** —— 这才是"全局适配"。
    /// ⭐⭐⭐ §2645 **颜色判据可配**（`settings.cta_color`）。
    ///
    /// ⛔ 缺省（`color == nil` 或字段缺失）⇒ **逐字**用改动前的 `r > 200 && g < 120 && b < 150`。
    /// ⚠️ 三个分量**各自**带默认值 ⇒ 只配一个（如只调 `g_max`）也是安全的。
    static func widestPinkBand(_ img: UIImage, box: CGRect,
                               color: PGConfig.Settings.CtaColor? = nil) -> (Double, Double, Int)? {
        // ⭐ §2631 **先归一到基准**（451×977）⇒ `box` 的基准坐标才成立
        let base = FrameNormalizer.normalize(img)
        guard let cg = base.cgImage else { return nil }
        // ⭐ §2645 颜色判据（⛔ 缺省逐字 = 改动前的粉色判据 R>200 且 G<120 且 B<150）
        let rMin = color?.r_min ?? ctaColorDefault.rMin
        let gMax = color?.g_max ?? ctaColorDefault.gMax
        let bMax = color?.b_max ?? ctaColorDefault.bMax
        let W = cg.width, H = cg.height
        let bx = max(0, Int(box.minX)), by = max(0, Int(box.minY))
        let bw = min(W - bx, Int(box.width)), bh = min(H - by, Int(box.height))
        guard bx < W, by < H, bw > 8, bh > 8 else { return nil }
        var best: (Double, Double, Int)?
        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        for y in by..<(by + bh) {
            var minX = -1, maxX = -1
            for x in bx..<(bx + bw) {
                let o = y * bpr + x * bpp
                let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
                // PC 的粉色判据：R>200 且 G<120 且 B<150
                // ⭐ §2645 三个阈值现在来自配置（`cta_color`）；⛔ 缺省逐字等于上面那句
                if Double(r) > rMin && Double(g) < gMax && Double(b) < bMax {
                    if minX < 0 { minX = x }
                    maxX = x
                }
            }
            if minX >= 0 {
                let w = maxX - minX
                if best == nil || w > best!.2 {
                    best = (Double(minX + maxX) / 2.0, Double(y), w)
                }
            }
        }
        return best
    }

    /// ⭐ 转化：浏览落地页 —— 逐条移植 PC `browse_landing`（`_1377_ad_loop.py:8535`）。
    ///
    /// ## PC 原文
    /// ```python
    /// def browse_landing(tag):
    ///     '''⭐⭐⭐ §1559 转化浏览（用户口径）：上滑 4~8 次、每次间隔 3~6s。'''
    ///     _ns = random.randint(4, 8)
    ///     for _i in range(_ns):
    ///         cmd(SWIPE)
    ///         wait(random.uniform(3.0, 6.0))
    /// ```
    /// ## ⛔ 用户令（不许自己发明）
    /// > 「**不是上滑浏览，是点击 CTA 互动按钮 → 进去 → 再上滑浏览**」（§1532）
    /// > 「**我说不支付 不是说不浏览**」（§1562）⇒ 购物型也要浏览
    /// ⛔ 唯一红线 = **不支付/不购买**（由 `forbidden()` 守）
    private func browseLanding(tag: String) {
        let n = Int.random(in: 4...8)
        log("   §\(tag) 转化浏览：上滑 \(n) 次，每次隔 3~6s（照 PC `browse_landing`）")
        for _ in 0..<n {
            if isCancelled() { break }
            swipeUp(3.0, 6.0)
        }
        log("   §\(tag) 转化浏览完成")
    }

    /// ⭐⭐⭐⭐⭐ §2640 **从落地页回广告页** —— 逐条移植 PC `return_to_ad`
    /// （`_1377_ad_loop.py:2771`）。
    ///
    /// # ⛔⛔ 为什么必须有它（用户令，逐字）
    /// > 「**这个未点X就切下一个了**」
    ///
    /// ## 血案（用户截图 + trace）
    /// 截图停在**天猫落地页**（「商品正在加速赶来中」）⇒ CTA **点成功了**，
    /// 但代码**在落地页上直接跑 G3/G4 找广告胶囊 ✕** ⇒ 找不到
    /// ⇒ `finishAdPanel` 返回 false ⇒ 本条"结束" ⇒ **去切下一个广告**
    /// ⇒ 现象正是「**未点 X 就切下一个**」。
    ///
    /// ## PC 的腿序（`_1377_ad_loop.py:2815-2975`，⛔ 按 k 轮次选腿）
    /// ```
    /// 每轮先无条件过：① 系统弹窗 → ② 券弹窗✕（位置闸）→ ③ 小店 H5 闸
    ///   k=0 : 面包屑「◀快手」→ 应用内商店页「完成」→ 应用内「〈」
    ///   k=1,2: 应用内「〈」（H5 订单页唯一出路，§1416 实测点得动的是 scr(40,85)）
    ///   k=3  : 下滑（沉浸式直播间：下滑后才出现「退出直播间」）
    ///   k=4  : 定位并点「退出直播间」
    ///   k=5  : **iOS 左边缘侧滑**（兜底；§1377b 实测：沉浸式带货直播间整页无 ✕，只有它能回）
    ///   k=6..8: **终端腿** H:HOME → 点桌面图标重进
    /// ```
    /// 📏 关键（PC 原话）：**"返回"是一个要反复尝试的动作**，⛔ 不是"我以为已经回来了"。
    /// ⚠️ 本函数**只做"回"，⛔ 不管"到了没有"** —— 判"到了没有"由调用方的
    ///   `looksLikeAdPage` 循环负责（照 PC 的 `for k in range(9)` 结构）。
    /// - Parameter k: 第几轮（决定用哪条腿，照 PC 的轮次语义）
    private func returnToAd(_ img: UIImage, tag: String, k: Int) {
        // ── 每轮先过的三层闸（照 PC 2815-2888，⛔ 顺序不许改）──
        // ① 系统弹窗（盖屏 ⇒ 底下什么都点不到）
        if let hit = nav.detect("sys_prompt", img: img) {
            log("   §\(tag) 返回闸①：系统弹窗 ⇒ 点消极项（照 PC `dismiss_sys_prompt`）")
            nav.tapPoint(Double(hit.center.x), Double(hit.center.y))
            return
        }
        // ② 券弹窗 ✕（**位置闸**，PC §1724 已删语义闸）
        if nav.detect("coupon_x", img: img) != nil {
            log("   §\(tag) 返回闸②：券弹窗 ✕ ⇒ 点它（照 PC `click_coupon_x`）")
            _ = nav.tap("coupon_x", img: img, atomic: true)
            return
        }
        // ③ 小店 H5（收银台/订单页）—— PC `handle_shop_h5` 自带状态机；
        //    手机端用已有的 `shop_h5_x` 元素等价处理（⛔ 找不到就不动）
        if nav.detect("shop_h5_x", img: img) != nil {
            log("   §\(tag) 返回闸③：快手小店 H5 ⇒ 点它的关/取消（照 PC `handle_shop_h5`）")
            _ = nav.tap("shop_h5_x", img: img, atomic: true)
            return
        }

        // ── 按轮次选腿（照 PC 2893-2975）──
        switch k {
        case 0:
            // 面包屑「◀快手」（**OCR 定位**，⛔ 不是写死坐标）
            if nav.detect("breadcrumb", img: img) != nil {
                log("   §\(tag) 返回腿 k=0：面包屑「◀快手」⇒ 点它（照 PC `click_breadcrumb`）")
                _ = nav.tap("breadcrumb", img: img, atomic: true)
                return
            }
            // 应用内商店页左上「完成」
            if nav.detect("appstore_done", img: img) != nil {
                log("   §\(tag) 返回腿 k=0：应用内商店页「完成」⇒ 点它")
                _ = nav.tap("appstore_done", img: img, atomic: true)
                return
            }
            log("   §\(tag) 返回腿 k=0：应用内「〈」⇒ 点它（照 PC `click_page_back`）")
            _ = nav.tap("back_arrow", img: img, atomic: true)
        case 1, 2:
            // 应用内 WebView 左上「〈」—— §1416 实测：H5 订单页唯一出路
            log("   §\(tag) 返回腿 k=\(k)：应用内「〈」（H5 唯一出路，§1416）")
            _ = nav.tap("back_arrow", img: img, atomic: true)
        case 3:
            // 下滑（沉浸式直播间：下滑后页面才出现「退出直播间」）
            log("   §\(tag) 返回腿 k=3：★下滑（沉浸式直播间先下滑才出「退出直播间」）")
            let cmd = BLEController.swipe(x1: baseW / 2, y1: baseH * 0.30,
                                          x2: baseW / 2, y2: baseH * 0.70,
                                          speed: .fast, baseW: baseW, baseH: baseH, yFix: yFix)
            ble.send(cmd)
        case 4:
            // 定位并点「退出直播间」
            if nav.detect("exit_live", img: img) != nil {
                log("   §\(tag) 返回腿 k=4：点「退出直播间」（照 PC `click_words(BOX_EXITLIVE)`）")
                _ = nav.tap("exit_live", img: img, atomic: true)
            } else {
                log("   §\(tag) 返回腿 k=4：没找到「退出直播间」⇒ 不放枪（铁律①）")
            }
        case 5:
            // ⭐ **iOS 左边缘侧滑**（兜底；§1377b：沉浸式带货直播间整页无任何 ✕，只有它能返回）
            log("   §\(tag) 返回腿 k=5：★iOS 左边缘侧滑（中部 3 发 + 上部/H5 3 发，照 PC §1720）")
            for _ in 0..<3 {
                if isCancelled() { return }
                _ = nav.backEdge()
                sleep(1.2)
            }
        default:
            // ── 终端腿（k>=6）：H:HOME → 点桌面图标重进（照 PC §1633）──
            log("   §\(tag) 返回腿 k=\(k)：★终端腿 = 回主屏 + 点桌面图标重进（照 PC §1633）")
            let ok = Navigator.switchToApp(named: "kslite", rec: rec, ble: ble,
                                           frame: { [weak self] in self?.grab() },
                                           baseW: baseW, baseH: baseH, yFix: yFix,
                                           log: { [weak self] s in self?.log(s) })
            if !ok {
                log("   §\(tag) 终端腿：桌面没找到「kslite」图标 ⇒ 不放枪（先找到再点）")
            }
        }
    }

    /// ⭐ 转化：点落地页里的「安装/获取」—— 移植 PC `click_install`（`_1377_ad_loop.py:8738`）。
    ///
    /// ## PC 的来历（用户令）
    /// > 「**现在安装的链路也不对，你看看是点击当前屏幕这个云的位置下载。**」
    /// 根因：App Store 详情页的下载钮是**一个纯图形（蓝色云朵+向下箭头）**，**上面一个字都没有**
    /// ⇒ 只 OCR 找「获取/安装/下载/免费」**永远命中不了**。
    ///
    /// PC 的两条形状判据（必须**同时**成立，只靠颜色/位置分不开）：
    /// ```
    ///   ① 主体**横宽**：w ≥ 1.25·h          （云 30/20=1.50 ✅ ／ 分享方框 20/19=1.05 ✗）
    ///   ② **箭头在主体正下方**：x 相差 ≤10 且 0 < Δy ≤ 25（分享的箭头在上方 ✗）
    /// ```
    /// ⚠️ 本函数**先过 App Store 页闸**（左上蓝像素）—— PC §1620：光靠形状有 **29% 误报**
    ///   （美团「镜」/淘宝商品图/微信头像/直播间贴图都会命中），没有这层闸就会在落地页乱点蓝块。
    private func clickInstall(_ img: UIImage, tag: String) {
        // ① App Store 页闸（照 PC `is_appstore_page`，BOX_DONE_BLUE）
        guard Self.looksLikeAppStorePage(img) else {
            log("   §\(tag) 不是 App Store 页 ⇒ 跳过点安装（照 PC §1620 的误报闸）")
            return
        }
        // ② 形状判据（云朵：横宽 + 箭头在下方）
        if let p = Self.findDownloadCloud(img) {
            log("   §\(tag) 云朵下载钮 @(\(Int(p.x)),\(Int(p.y)))（横宽+箭头在下方 双判据）⇒ 点它")
            nav.tapPoint(Double(p.x), Double(p.y))
            return
        }
        // ③ 文案兜底（⛔ 过后只有文字版式才有用）
        for (t, r, _c) in rec.ocrRegion(img, rect: CGRect(x: 0, y: 320, width: baseW, height: 440),
                                        minConfidence: 0.3) {
            if ["获取", "安装", "下载", "免费"].contains(where: { t.contains($0) }) {
                if let bad = Self.forbidden(t, extraKeys: forbidKeysCfg) {
                    log("   §\(tag) ⛔ 安装文案「\(t)」含违规词「\(bad)」⇒ 跳过")
                    continue
                }
                log("   §\(tag) 安装文案兜底：「\(t)」⇒ 点它")
                nav.tapPoint(Double(r.midX), Double(r.midY))
                return
            }
        }
        log("   §\(tag) ⚠️ 没找到安装钮（云朵/文案都没中）⇒ 不点")
    }

    /// 照 PC `is_appstore_page`：左上「完成/打开」那一带是否够 **iOS 蓝**。
    ///
    /// PC 全量真帧标定（5071 帧）：App Store 模态页 = **289~290** 个蓝像素；**其它任何页面 = 0**。
    /// ⇒ 阈值取 **100**（两侧各留 ~3 倍余量）。
    /// ⚠️ 真机实测（`_dev/_2423_appstore_page.py`）：新版 iOS 上这台机器只有 **25** 个蓝像素
    ///   ⇒ 阈值 100 会**漏判**。⇒ 这里放宽到 15，并且**另配文案判据**（`更多来自/获取/打开`）。
    ///
    /// ⛔⛔ §2631 **全局适配**：`BOX_DONE_BLUE=(0,85,140,150)` 是**基准坐标**
    ///   ⇒ 必须**先归一到基准**再索引像素（⛔ 否则帧 888 宽时会扫错区域）。
    ///   （本函数属"像素类判据"；OCR 类走 `ocrRegion`，那里**已经**有比例换算，不受影响。）
    static func looksLikeAppStorePage(_ img: UIImage) -> Bool {
        let base = FrameNormalizer.normalize(img)      // ⭐ §2631 先归一
        guard let cg = base.cgImage, let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        // BOX_DONE_BLUE = (0, 85, 140, 150)
        var n = 0
        for y in 85..<min(150, cg.height) {
            for x in 0..<min(140, cg.width) {
                let o = y * bpr + x * bpp
                let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
                if b > 180 && r < 120 && g > 80 && g < 190 { n += 1 }
            }
        }
        return n >= 15
    }

    /// 找 App Store 详情页那个**蓝色云朵（下载/安装）**：主体横宽 + 箭头在正下方。
    /// ⛔ 找不到 ⇒ nil（调用方不点）；⛔ 不会误点右侧的「分享」方框（它箭头在上方）。
    ///
    /// ⛔⛔ §2631 **全局适配**：`BOX_CLOUD=(0,320,451,760)` 是**基准坐标** ⇒ 先归一。
    static func findDownloadCloud(_ img: UIImage) -> CGPoint? {
        let baseImg = FrameNormalizer.normalize(img)   // ⭐ §2631 先归一
        guard let cg = baseImg.cgImage, let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        // PC BOX_CLOUD = (0, 320, 451, 760)
        var blocks: [(Int, Int, Int, Int, Int)] = []      // minX,minY,maxX,maxY,area
        var seen = Set<Int>()
        func isBlue(_ x: Int, _ y: Int) -> Bool {
            let o = y * bpr + x * bpp
            let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
            return b > 180 && r < 120 && g > 80 && g < 190
        }
        let x0 = 0, x1 = min(451, cg.width), y0 = 320, y1 = min(760, cg.height)
        for y in y0..<y1 {
            for x in x0..<x1 where isBlue(x, y) && !seen.contains(y * 4096 + x) {
                // 洪水填充
                var stack = [(x, y)], minX = x, maxX = x, minY = y, maxY = y
                seen.insert(y * 4096 + x)
                while let (cx, cy) = stack.popLast() {
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = cx + dx, ny = cy + dy
                            guard nx >= x0, nx < x1, ny >= y0, ny < y1,
                                  !seen.contains(ny * 4096 + nx), isBlue(nx, ny) else { continue }
                            seen.insert(ny * 4096 + nx)
                            stack.append((nx, ny))
                        }
                    }
                }
                let w = maxX - minX + 1, h = maxY - minY + 1
                if w * h >= 60 { blocks.append((minX, minY, maxX, maxY, w * h)) }
            }
        }
        // 判据① 主体横宽 w ≥ 1.25h；判据② 另有一块在它**正下方**（x 近、0<Δy≤25）
        for (i, b) in blocks.enumerated() {
            let w = b.2 - b.0 + 1, h = b.3 - b.1 + 1
            guard Double(w) >= 1.25 * Double(h) else { continue }
            let bcx = Double(b.0 + b.2) / 2.0
            for (j, c) in blocks.enumerated() where j != i {
                let ccx = Double(c.0 + c.2) / 2.0
                let dy = c.1 - b.3
                if abs(ccx - bcx) <= 10 && dy > 0 && dy <= 25 {
                    return CGPoint(x: bcx, y: Double(b.1 + b.3) / 2.0)
                }
            }
        }
        return nil
    }

    /// ⭐⭐ §2309 **任务列表下滑**（把列表往上拉，露出更靠上的行）。
    ///
    /// 为什么单独一个函数：刷视频的上滑要**_快_**（模拟用户划走），
    /// 而任务列表翻页要**_慢一点_**（让列表真的滚动到下一屏，⛔ 不是当成“划走”丢出去）。
    /// 距离也短一些（半屏），避免一下子飞到列表底部错过目标行。
    private func swipeDownList(baseW bw: Double, baseH bh: Double) {
        // ⛔⛔ §2309 方向必须是**下滑**（手指从上往下）—— 真机实测定死的
        //
        // 我第一版写成"上滑"（手指从下往上），结果 6 次都找不到目标行。
        // 同一屏上两个方向各试（真机实测）：
        //   下滑 x4 ⇒ 第 3 次 FOUND y=756、第 4 次 FOUND y=837  ✅
        //   上滑 x6 ⇒ **6/6 全部 not-found**                       ⛔
        // ⇒ 目标行在列表**靠上**的位置，得把列表往下拖才能露出来。
        // 📏 与“刷视频上滑换下一条”方向相反，所以绝不能复用 `swipeUp`。
        let midX = bw / 2.0
        let yStart = bh * 0.36        // 起点靠上
        let yEnd = bh * 0.80          // 向下拖（⛔ 不进底栏）
        let cmd = BLEController.swipe(x1: midX, y1: yStart, x2: midX, y2: yEnd,
                                      speed: .mid, baseW: bw, baseH: bh, yFix: yFix)
        ble.send(cmd)
        sleepWithCancel(1.6)
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
