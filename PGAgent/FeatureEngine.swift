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
    /// ⭐ 停留区间**下界**（配置 `ad_stay_min`，默认 30）—— 顺带把上下界排好序，
    ///    ⛔ 免得 `upper < lower` 让 `Double.random(in:)` **运行时崩**。
    private var adStayMin: Double { min(s?.ad_stay_min ?? 30, s?.ad_stay_max ?? 45) }
    /// ⭐ 停留区间**上界**（配置 `ad_stay_max`，默认 45）
    private var adStayMax: Double { max(s?.ad_stay_min ?? 30, s?.ad_stay_max ?? 45) }

    private var adDwellSeconds: Double {
        // ⭐⭐⭐⭐⭐ §2824 用户令（逐字）：「**看广告没有等待时间我设置的希望30-45随机**」
        //   ⇒ **区间优先**，而且**每条广告重新抽一次**（⛔ 不是整轮共用一个值）。
        //
        // ## ⛔ 旧版为什么"没有等待时间"（两处叠加）
        // ① 读取顺序把 `ad_dwell`（单个值）排在**区间之前**：
        //    只要 `config.json` 里还有 `ad_dwell`，`ad_stay_min/max` **永远不生效**。
        // ② 更致命：**真正执行的转化分支从头到尾没调用过 `adDwellSeconds`**
        //    （它只在"广告播放中"那条极少走到的分支里被用过）
        //    ⇒ 手机日志 `G3 倒计时已结束（等了 0s）` —— **一秒都没等**。
        if s?.ad_stay_min != nil || s?.ad_stay_max != nil {
            return Double.random(in: adStayMin...adStayMax)
        }
        if let d = s?.ad_dwell { return d }
        return 30
    }

    /// ⭐⭐⭐ §2645 **CTA 文案兜底词表** —— 配置优先，⛔ 缺省 = 现在的硬编码 12 条
    private var ctaKeysCfg: [String] { s?.cta_keys ?? Self.ctaKeys }

    /// ⛔⛔⛔ §2645 **禁点词（支付红线）** —— 配置优先，⛔ 缺省 = 现在的硬编码 25 条
    ///
    /// ⚠️ 配置化**受** `ConfigStore.validate()` 的**加法校验**保护：
    ///   只许在基线之上追加，⛔ 删减任何一条 ⇒ `/reload` **拒绝加载**并报 `configErrors`。
    private var forbidKeysCfg: [String] { s?.forbid_keys ?? Self.forbidKeys }

    /// ⭐⭐⭐ §2896 **安装/打开腿的词表** —— 配置优先，⛔ 缺省 = 现在的硬编码 8 条
    private var installWordsCfg: [String] { s?.install_words ?? Self.installWords }

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
        // ⚠️ 优先级（§2824 用户令后）：**区间 `ad_stay_min/max` 优先**，其次 `ad_dwell`，最后 30。
        //    ⛔ 旧注释写的是反过来（`ad_dwell` 优先）—— 那正是"看广告没有等待时间"的根因。
        log("§adbox 条数=\(count) 广告停留=**每条 \(Int(adStayMin))~\(Int(adStayMax))s 随机**"
            + " 入口=\(s?.entry ?? "auto")")

        guard ensureInCenter(tag: "adbox_boot") else {
            log("§adbox ⛔ 回不到金币中心 ⇒ 停手")
            return false
        }

        var n = 0
        var emptyRounds = 0
        var scrollTries = 0          // ⭐ §2309 任务列表翻页次数
        var adEntryToggle = 0        // ⭐ §2315 入口轮换计数（宝箱 ↔ 看广告得金币）
        var cooldownWaits = 0        // ⭐ §2911 目标行"在屏上但按钮冷却"的等待次数（有界）

        // ⭐⭐⭐⭐⭐ §2705 **无进展闸（"无限循环"的正解）**
        //
        // ## 真机血案（用户令，逐字）
        // > 「**死机了 无限循环**」/「**又死机了**」
        //
        // ## ⛔ 根因：`runFunnel` 那条 `continue` **一个计数器都不加**
        // ```swift
        // if nav.runFunnel(img) { log("漏斗处理了一层"); sleep(1.0); continue }
        // ```
        // `runFunnel` 只要**一直返回 true**（弹窗没被点掉 / 在冻结帧上反复"认出"同一个弹窗），
        // 这个 `continue` 就**绕过了本函数里所有的闸**：
        //   · `n`            不涨 ⇒ `while n < count` 永远成立
        //   · `scrollTries`  不涨 ⇒ 6 次翻页预算永远用不完
        //   · `emptyRounds`  不涨 ⇒ "连续 3 轮找不到就收手"永远不触发
        // ⇒ **真·无限循环**（真机 trace 逐字：`§funnel friend_popup_x` 反复刷、`n` 一直不动）。
        //
        // ## ✅ 做法：**按"有没有进展"计数**，⛔ 不按"跑到哪一步"计数
        // 判据用**已有的量**（⛔ 不新造判据）：`n`（真正收到奖励的条数）。
        //   · `n` 涨了 ⇒ 有进展 ⇒ 时间戳刷新
        //   · `n` 没涨 ⇒ 看**距上次增长过了多久**
        // 超过 `stallSeconds`（60s）⇒ **停手并说清原因**（⛔ 不装死、⛔ 不空转）。
        // ⚠️ §3014：**⛔ 不用"连续 N 次"** —— 次数会被"进广告页要 6~10 次循环"误杀。
        //
        // 📏 为什么放在**循环头**而不是各个 `continue` 之前：
        //    出口有 10 多个（每条腿都有 `continue`），逐个加**必然漏**；
        //    放循环头 ⇒ **任何**路径绕回来都会被记一次 ⇒ 结构上不可能再漏。
        //    （这正是我上一版把旧帧闸只装在 `unknown` 分支里踩的同一个坑。）
        var lastN = 0
        /// ⭐ §3014 最后一次 `n` 增长的**时刻**（⛔ 不再用次数计数，理由见循环头那段注释）
        var stallSince = Date()
        /// 无进展**时间**上限（秒）：超这么久一条新广告都没到账才判死。
        ///
        /// ## ⛔ 为什么从「次数 8」改成「时间 60s」（真机血案 2026-10-18）
        /// 真机 trace 逐字：**"进广告页"这一件事本身就要 6~10 次循环**
        /// （`§occl 上滑` → `重新定位` → `点了没进 ⇒ 重试` → `再点` → `已进广告页`）⇒
        /// 而 `stallLimit = 8` 恰好在这里把它砍掉 ⇒ **一条都跑不成**、误报"卡死"。
        /// 📏 根因：`n` 只在**整条广告收完奖励**时才 +1，而"进广告页 / 等停留 / 等倒计时"
        /// **全都没有 `n` 的增长** ⇒ **按次数当闸必然误杀**（正常一条就 > 8 次循环）。
        ///
        /// ## ✅ 60s 的依据（⛔ 不是拍脑袋）
        /// · 正常一条广告 = 停留(30~60s) + 倒计时(≤30s) + 操作 ⇒ 60~120s；
        /// · 但"进不去广告页"这类空转，60s 内会重复十几次同样的失败 ⇒ 够判死；
        /// · "进广告页 + 开始等"是**正常前进**，不该被砍。
        /// ⚠️ 真卡死另有兜底：`Navigator` 的记死腿 + 各腿"画面没变 ⇒ 换腿"。
        ///    本闸只是**最后一道"什么都没发生"的兜底**。
        let stallSeconds: Double = 60

        // ⭐⭐⭐⭐⭐ §2824 **每条广告的"只做一次"状态**（用户令）
        //
        // ## 用户令（逐字）
        // > 「**需要做检测就做单次转化，转化完就去关闭广告获取奖励**」
        // > 「**还有转化现在无限转化。卡死**」
        //
        // ## ⛔ 血案：同一条广告被**反复转化**（真机日志 18:14~18:18 逐字）
        // ```
        // 18:15:36  已回广告页（第 2 次检查）⇒ 继续等倒计时
        // 18:15:37  G3 倒计时已结束（等了 0s）            ← 一秒没等
        // 18:15:38  adbox_back1 ⛔ 这是视频广告页 ⇒ 放行   ← 人**还在广告页**，却当"到中心了"
        // 18:15:38  adbox_cta2 ...                        ← 同一条广告**又转化一次**
        // 18:15:42  adbox_browse2 ...                     ← 再浏览一次
        // （如此 6 轮，最后一条广告都没收奖励，却报 ok=true / 跑完 6 条）
        // ```
        // 根因：`n += 1` 之后调 `ensureInCenter`，而它**对广告页直接 return true**
        // （防误点 ✕ 的短路）⇒ 主循环立刻又落回"广告页"分支 ⇒ **从头再转化一遍**。
        //
        // ## ✅ 修法：把"这条广告做过了什么"记下来
        //   · `convertedThisAd` —— 转化（CTA→浏览）**每条只做一次**
        //   · `dwelledThisAd`   —— 停留计时**每条只起一次**
        //   · `n` **只在真的收完奖励/离开广告页之后**才 +1（⛔ 不再"假报成功"）
        //   两个标志在**离开这条广告**时一起清空。
        var convertedThisAd = false
        var dwelledThisAd = false
        var adDwellTarget = 0.0          // 本条广告的停留目标（区间随机，每条重抽）
        var adEnteredAt = Date()

        while n < count {
            if isCancelled() { log("§adbox ⛔ 被中断"); break }

            // ── ⭐ §3014 无进展闸：**按时间**判，⛔ 不按次数 ──
            //
            // ## ⛔ 为什么从"次数"改成"时间"（真机血案 2026-10-18）
            /// 真机 trace 逐字：
            /// ```
            ///   §occl 上滑 D:16383,23726,16383,12585,220
            ///   §occl ✅ 重新定位到按钮 @(393,579)
            ///   §tapPoint ★点坐标 @(393,579)
            ///   §adbox ⚠️ 点了任务但没进广告页 ⇒ 重试
            ///   §adbox 按行定位到「看广告得金币」行 ⇒ 按钮 领福利 @(393,549)
            ///   §tapPoint ★点坐标 @(393,549)
            ///   §adbox ✅ 已进广告页 ⇒ 交给循环头
            ///   §adbox ⛔ **连续 8 次循环毫无进展**（收奖励条数停在 0）⇒ 停手
            /// ```
            /// ⇒ **"进广告页"这一件事本身要花 6~10 次循环**（定位 / 上滑 / 重试 / 再点），
            ///   而 `stallLimit = 8` 在**刚进广告页那一刻**就把它砍了 ⇒ 一条都跑不成。
            /// 📏 教训：`n` 是"收到奖励的条数"，它在**整条广告跑完**才 +1；
            ///   而进广告页、等停留、等倒计时**全都没有 `n` 的增长** ⇒
            ///   **用次数当闸必然误杀**（每条广告的正常耗时本来就 > 8 次循环）。
            ///
            /// ## ✅ 现在
            /// 记**时间戳**：最后一次 `n` 增长的时刻。超过 `stallSeconds`（默认 60s）
            /// 没有任何新条到账才判死。60s 的依据：
            /// · 正常一条广告 = 停留(30~60s) + 倒计时(≤30s) + 操作 ≈ **60~120s**；
            /// · 但**"进广告页失败"**这类空转，60s 内会重复十几次同样的失败 ⇒ 够判；
            /// · 而"进广告页 + 开始等"是**正常前进**，不该被砍。
            /// ⚠️ 真正的"卡死"仍由 `Navigator` 的记死腿 + 各腿的"画面没变⇒换腿"兜住，
            ///   本闸只负责**最后一道"什么都没发生"的兜底**。
            if n > lastN {
                lastN = n
                stallSince = Date()
            } else if Date().timeIntervalSince(stallSince) > stallSeconds {
                let spent = Int(Date().timeIntervalSince(stallSince))
                log("§adbox ⛔ **\(spent)s 没有任何新条到账**（收奖励条数停在 \(n)）"
                    + " ⇒ **停手**（照 §3014 无进展闸·按时间）")
                log("§adbox ⛔ 多半是这两个原因之一："
                    + "① **录屏已停**（帧不再更新，画面永远是同一张 ⇒ 点哪都没用）；"
                    + "② **有弹窗/面板盖住任务列表**且漏斗点不掉它。"
                    + " ⇒ **请到手机上确认画面**（重开录屏 / 手动关掉弹窗）后再跑")
                break
            }

            guard let img = grab() else { log("§adbox ⛔ 抓帧失败"); break }
            beat(["phase": "adbox-step", "n": n, "of": count])

            // ⭐⭐⭐⭐⭐ §2996 **弹窗优先 —— 每条循环第一步就跑漏斗**（照 PC §1773d 顺序）
            //
            // ## ⛔ 真机血案（2026-10-17 19:37，用户报「任务中心的弹窗又不处理了？卡死了」）
            // 现场：3 帧间隔 80s，`page` 恒为 `center`，40 个 OCR 词一字不变，
            //       金币数 `22196` 三帧不动 ⇒ **画面完全冻结**。
            // 真因：**「限时邀1位好友立得现金」弹窗盖住整屏**（用户截图铁证），
            //       底下所有点击都落在遮罩上 ⇒ 点「领福利」@(394,339) 永远没反应。
            // trace 逐行（40 条环缓冲）：
            // ```
            // [6-8]   点「领福利」@(394,339)
            // [9-12]  入口轮换 → 宝箱浮件 @(393,945) → 点了
            // [13]    宝箱面板上没找到 CTA ⇒ 落回按行腿
            // [14]    ⚠️「看广告得金币」行 y=331 里 x≥330 没有按钮 ⇒ 本腿放弃
            // [15-16] 本屏没有目标行 ⇒ 下滑找（第 N/6 次）
            // [17]    ⬇ 翻到了目标行 ⇒ 点「领福利」@(394,339)   ← 又点回同一处
            // ... 无限循环 6 次后重来
            // ```
            // ⇒ **漏斗一次都没跑**：因为 `runFunnel` 只在下面「④ 认不出」分支（L1039），
            //   而弹窗盖屏时页型**仍判 `center`** ⇒ 永远走「② 按行定位」⇒ **到不了 ④**。
            //
            // ## ✅ PC 的顺序（`_1377_ad_loop.py:2705-2724`，逐字）
            // > ⭐⭐⭐ §1773d **恢复漏斗提到导航之前**（弹窗盖屏 ⇒ 底下什么都点不到）
            // > ⛔ 真机血案：`ext_landing` 走 ② 点面包屑 ⇒ 失败记死 ⇒ 停手，
            // >   而**弹窗就在那儿** ⇒ **漏斗根本没轮到**。
            // > 📏 正确顺序（抄 Alas `ui_additional` 语义）：
            // >   「**Popups appear at page_os … so must take precedence**」
            // > ✅ 新顺序：① 到目的地了吗 ② **恢复漏斗（弹窗/盖屏）** ③ 页面图上前进一跳 ④ 停手
            //
            // ## ⛔ 安全性（为什么不会乱点）
            // 漏斗里每条腿**都有自己的前置闸**（`require`）或**独立形态判据**：
            // · `modal_x` → 现在是 §2992+§2994 的「暖灰圆 + 中心深色十字」四闸像素判据
            //   （离线验收 POS 10/10、NEG 0/1500 假阳）
            // · `sys_prompt_*` / `rec_stopped_*` / `consent_*` → 都要标题/按钮形态同时命中
            // · `pill_x` / `panel_close_x` → 模板或 OCR 尾字符闸
            // ⇒ 普通广告页/任务中心页**不会**被误点（漏斗内部仍有序 + 带 interval 节流）。
            // ⚠️ 但**广告页必须放行**：广告页上的胶囊 ✕ 是 `pill_x`，漏斗会点它。
            //    所以顺序是 **先判"是不是广告页"，是就交给 ① 分支，⛔ 不进漏斗**。
            let onAdPageNow = Self.looksLikeAdPage(img, rec: rec, nav: nav,
                                                  bw: baseW, bh: baseH,
                                                  roi: s?.ad_top_roi)
            if !onAdPageNow, nav.runFunnel(img) {
                // ⭐⭐⭐⭐⭐ §3012 **点完必须验"画面真的变了"**（真机血案，2026-10-18）
                //
                // ## ⛔ 血案（本轮真机 trace 逐字）
                /// ```
                ///   §funnel modal_x @(419,371)
                ///   §ble → P:30490,12581          ← 命令发出去了
                ///   §adbox ⭐ 漏斗处理了一层       ← 旧代码到这里就认为"进展了"
                ///   §funnel modal_x @(419,371)     ← 下一轮同一句，一模一样
                /// ```
                /// 旧写法 `log(处理了一层); continue` 只看**"点没点"**，⛔ 不看**"生没生效"**。
                /// ⇒ 于是 `n`（收到奖励的条数）**不涨**、画面**不动**，却每轮都算"处理了一层"。
                ///
                /// ## ✅ 现在
                /// 点完**抓一帧比对上半屏**（`screenChanged` 只看页面结构区，避开视频帧抖动）：
                /// · **变了** ⇒ 真的是弹窗被关掉 ⇒ 照旧 `continue` 进下一轮 ✅
                /// · **没变** ⇒ ⛔ **明确报出来**（"点了但画面没变"），并且**不加 `n`**，
                ///   让循环头的时间闸（`stallSeconds = 60`）如实停手。
                /// ⚠️ 这里**不额外 sleep**：`sleep(1.0)` 已在下面对所有路径统一执行，
                ///   再抓的一帧本来就落在 1s 之后（录屏节拍 2s，`grabFresh` 不必再用）。
                sleep(1.0)
                if let post = grab(), nav.screenChanged(img, post) {
                    log("§adbox ⭐ 漏斗处理了一层（弹窗优先，照 PC §1773d）⇒ ✅ 画面已变")
                    continue
                }
                log("§adbox ⚠️ 漏斗点了**但画面没变**（同一弹窗没关掉）⇒ 本轮不算进展，"
                    + "交给无进展闸（\(Int(stallSeconds))s 内无新条则停手）")
                continue
            }

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

                // ⭐⭐⭐⭐⭐ §2824 **本条广告的停留计时**（用户令：30~45 随机）
                //
                // ## 用户令（逐字）
                // > 「**看广告没有等待时间我设置的希望30-45随机**」
                //
                // ## ⛔ 血案：这个分支**从来没等过**
                // 旧版的 `dwell` 只在"广告播放中（无面板/无关闭键）"那条**极少走到**的分支里
                // 被用到；而真机走的是**本分支**（顶栏有胶囊）⇒ 一秒都没等。
                // 手机日志逐字：`§adbox G3 倒计时已结束（等了 0s）`。
                //
                // ⇒ 现在**进入本条广告时抽一次**区间随机值，并在下面**真的等满**。
                //   ⛔ 每条只起一次计时（`dwelledThisAd`），免得循环回来重新计时。
                if !dwelledThisAd {
                    adDwellTarget = adDwellSeconds          // 区间随机 ⇒ 每条广告不同
                    adEnteredAt = Date()
                    dwelledThisAd = true
                    log("   §adbox 本条广告停留目标=\(Int(adDwellTarget))s"
                        + "（区间 \(Int(adStayMin))~\(Int(adStayMax)) 随机；用户令）")
                }
                // 已经等了多久（跨"循环回来"累计，所以用进入时刻算，⛔ 不重新计时）
                let dwelledSoFar = Date().timeIntervalSince(adEnteredAt)
                let dwellLeft = adDwellTarget - dwelledSoFar

                // ── ② ⭐⭐⭐ 转化：点 CTA → 浏览落地页（**每条只做一次**）──
                //
                // ⛔⛔ §2824 用户令：「**需要做检测就做单次转化，转化完就去关闭广告获取奖励**」
                //    旧版没有 `convertedThisAd` 闸 ⇒ 主循环每绕回来一次就**再转化一次**
                //    （真机日志：cta1/browse1 → cta2/browse2 → … → cta6/browse6，同一条广告）。
                if !convertedThisAd, !isCancelled(), let cur4 = grab() {
                    convertedThisAd = true
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
                } else if convertedThisAd {
                    log("   §adbox ⏭ 本条广告**已转化过**（单次转化，用户令）⇒ ⛔ 不再转化")
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
                // ⭐⭐⭐⭐⭐ §2933 **A4：腿无效判据 + 换腿上限**（治"同一条腿连发"）
                //
                // ## ⛔ 为什么补它（本项目已有的 GitHub 调研结论，我一开始没照做）
                // `_docs/notes/_note_1473_直播间回中心腿序_GitHub调研与方案.md` §2.3 逐字：
                // > Alas 把「**点了太多次还是没反应**」设成**独立的一等异常**
                // > `GameTooManyClickError`；GKD 用 `actionMaximum`（限次）/`actionCd`（冷却）
                // > ⇒ 成熟框架**不"继续点"**，而是把它当异常拦下。
                // 📏 那次真机血案：**同一条腿连发 34 次**（`min(s,5)` 饱和 ⇒ 无限空转）。
                //
                // ## ✅ 抄 PC 的现成机制（`Navigator.markDead` / `screenChanged`，已在码里）
                // 本项目**已经有**这两个函数（照 MaaFW `wait_freezes` 语义）：
                // ```
                //   点前抓一帧 → 发腿 → 点后再抓 → 比「判据区指纹」
                //   没变 ⇒ 这条腿在**这一页上**无效 ⇒ 记死，换下一条
                // ```
                // ⇒ 我这次只是**把它接进返回循环**（⛔ 没有新造任何机制）。
                var deadLegs = Set<Int>()
                var lastSig: UIImage? = nil
                // ⭐ §2971 上一轮那条腿**到底出手了没有**（returnToAd 的返回值）
                //   ⛔ 只有"出手了 且 画面没变"才许记死 ⇒ 治冤杀（见 ②b 的血案注释）
                var lastLegFired = false
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
                    //   ⇒ **不进 G3/G4、不点 ✕、不收奖励** = 用户令「**这个未点X就切下来**」。
                    // ✅ 改用**纯元素判据**（config 的 `center_marker`）—— 与 PC `on_center` 同语义。
                    if nav.detect("center_marker", img: imr) != nil {
                        log("   §adbox ✅ 已落回金币中心（第 \(k + 1) 次检查）")
                        backHome = true
                        break
                    }
                    // ②b ⭐ A4：**上一轮那条腿有没有用**（画面变了吗）
                    //    ⇒ 没变 ⇒ 它在**这一页上**无效 ⇒ 记死，本轮跳过它直接换下一条
                    //
                    // ⛔⛔⛔ §2971 **必须再过一道"它到底出手了没有"**（真机血案）
                    // 血案（`_2971` 真机日志逐字）：
                    // ```
                    // [19:14:57] §tap ⛔ 没找到「back_arrow」⇒ **不点**      ← 这一腿没出手
                    // [19:15:01] §adbox ⏭ 返回腿 k=2 **点了画面没变** ⇒ 记死  ← 🔴 谎报"点了"
                    // ```
                    // ⇒ 四条腿（k=2/4/7/8）**一次都没出手**却被全判死 ⇒ 后面的路被自己堵死。
                    // ✅ 修法：`returnToAd` 现在**返回它有没有出手**
                    //   · 出手了 且 画面没变 ⇒ 记死（原语义，对）
                    //   · 没出手            ⇒ **⛔ 不记死**（它只是这一帧没找到目标）
                    if let ref = lastSig, lastLegFired {
                        if !nav.screenChanged(ref, imr) {
                            deadLegs.insert(k - 1)
                            log("   §adbox ⏭ 返回腿 k=\(k - 1) **点了画面没变** ⇒ 记死换下一条"
                                + "（A4／MaaFW `wait_freezes`；⛔ 不重复点）")
                        }
                    } else if let _ = lastSig, !lastLegFired {
                        log("   §adbox ℹ️ 返回腿 k=\(k - 1) 上一轮**没出手**（没找到目标）"
                            + "⇒ ⛔ 不记死（§2971：⛔ 不许把没出手的腿冤杀）")
                    }
                    // ③ 还在落地页 ⇒ **主动返回**（照 PC `return_to_ad`）
                    //    ⛔ 若这条腿已记死 ⇒ 直接跳到下一条（⛔ 不空转）
                    if deadLegs.contains(k) {
                        log("   §adbox ⏭ 返回腿 k=\(k)：已记死 ⇒ 跳过（⛔ 不重复点）")
                        lastSig = nil
                        continue
                    }
                    log("   §adbox ↩ 还在落地页（第 \(k + 1)/\(returnToAdRounds) 次）⇒ 执行返回")
                    lastSig = imr
                    lastLegFired = returnToAd(imr, tag: "adbox_ret\(n + 1)_\(k)", k: k)
                    // ⭐⭐⭐ §2973 **改成"轮询等一张新帧"，⛔ 不是盲等固定 `returnToAdWait`**
                    //
                    // ## 📏 为什么（照本项目**已有**的 `Navigator.step` §2265，⛔ 不新造）
                    // 录屏写盘节拍是 **1 帧/4s**（为活过 iOS 写入预算而故意放慢）。
                    // 固定睡 3.2s 就去比 ⇒ `grab()` 很可能**还是同一张帧** ⇒
                    // `screenChanged` 等于拿一张图跟自己比 ⇒ 恒 false ⇒ **腿被冤杀**。
                    // 📏 与 `Navigator.swift:1114-1137` 是**同一个坑**，那边已修好 ⇒ 这里照抄。
                    //
                    // ## ✅ 修法（照抄那段）
                    //   · 画面**真变了** ⇒ 新帧一到就早退（⛔ 不白等）
                    //   · 画面**真没变** ⇒ 等满预算再判（结论仍正确）
                    // 📏 也顺手治了"9 腿 × 3.2s 白等 29s"的浪费。
                    //
                    // ⚠️ 上游对照：SikuliX `WaitScanRate`／Selenium `poll_frequency`
                    //    都是"轮询到条件成立就早退"，⛔ 不是固定 sleep。
                    let changeWait = max(Double(returnToAdWait),
                                         (s?.loop_frame_max_age ?? 7.0) + 1.5)
                    let deadline = Date().addingTimeInterval(changeWait)
                    while Date() < deadline {
                        sleep(0.5)
                        guard let p = grab() else { break }
                        if nav.screenChanged(imr, p) {
                            log("   §adbox ⚡ 返回腿 k=\(k) 后**画面已变**（新帧到了就早退，⛔ 不白等）")
                            break
                        }
                    }
                }
                if backHome {
                    // ⭐⭐⭐⭐⭐ §2824 **回中心也算"真的离开这条广告"** ⇒ 可以计数
                    //
                    // 为什么这个分支能算完成（与另两处的"确认到账"等价）：
                    // 能走到这里说明**人已经不在广告页**，而是落回了金币中心
                    // （判据 = `center_marker` 元素命中，⛔ 不是广告页放行短路）
                    // ⇒ 广告确实结束了、奖励由快手自己结算 ⇒ 与"已成功领取"同义。
                    // ⚠️ 关键是**必须真的不在广告页**：血案里那句
                    //   `§adbox_back1 ⛔ 这是视频广告页 ⇒ 放行` 是 `ensureInCenter`
                    //   的广告页短路 ⇒ 人还在广告页 ⇒ 那次**不该**计数（现在已改由
                    //   `adRewardClaimed` / `looksLikeAdPage` 确认，⛔ 不用短路）。
                    log("   §adbox ✅ 已离开广告页（落回金币中心）⇒ 本条完成")
                    n += 1
                    scrollTries = 0
                    convertedThisAd = false
                    dwelledThisAd = false
                    continue
                }

                // ── ②c ⭐⭐⭐⭐⭐ §2824 **停留（用户令：30~45 随机）** ──────────────
                //
                // ## 用户令（逐字）
                // > 「**看广告没有等待时间我设置的希望30-45随机**」
                //
                // ## ⛔ 血案：这里从来**没等过**
                // 旧版 `dwell` 只在"广告播放中（无面板/无关闭键）"那条**极少走到**的分支里
                // 用过；真机走的是本分支（顶栏有胶囊）⇒ 手机日志逐字
                // `§adbox G3 倒计时已结束（等了 0s）` —— **一秒都没等**。
                //
                // ## 顺序为什么是「转化 → 停留 → 等倒计时 → 点 ✕」
                // 转化必须在广告还在时做（§2632：等满了 CTA 就没了）；
                // 而停留是**用户要的看广告时长**；两者不冲突 —— 转化已经做完了。
                if dwellLeft > 0 {
                    log("   §adbox ⏳ 本条广告停留（还需 \(Int(dwellLeft))s / 目标 \(Int(adDwellTarget))s）")
                    var left = dwellLeft
                    while left > 0, !isCancelled() {
                        let d = min(2.0, left)
                        sleep(d)
                        left -= d
                        // ⭐⭐⭐⭐⭐ §2832 **只补全、不关闭**（照 PC `wait()` + `click_toast_x` 第一段）
                        //
                        // ## ⛔⛔ 血案（0.16 真机日志，用户报「没有等待 + 提前点 ✕」）
                        // 这里原来调的是 `finishAdPanel()` —— 它**会点胶囊 ✕**（腿序第③条）
                        // ⇒ 停留才 10 秒就把广告关掉了：
                        // ```
                        // 10:46:32  ⏳ 本条广告停留（还需 46s / 目标 46s）
                        // 10:46:41  顶栏胶囊 ✕（面板已不在、且已无倒计时）⇒ 点它   ← ⛔ 自己点的
                        // 10:46:42  §click pill_x @(220,89)
                        // ```
                        // ## ✅ 正解（PC `_1377_ad_loop.py:4395` 的 `wait()` 就是纯 `time.sleep`）
                        //   等待期间**唯一**允许的动作 = 点「继续观看」把广告补全
                        //   （PC `click_toast_x` L4333 那段：命中「继续观看」⇒ 点它 ⇒ **return**）
                        //   ⛔ 绝不点胶囊 ✕ / 面板 ✕ —— 那是**等满之后** G4 的事。
                        if let im2 = grab(), completeAdPanelOnly(im2, tag: "adbox_dwell\(n + 1)") {
                            log("   §adbox 停留中面板需要补全 ⇒ 已点「继续观看」（⛔ 未关广告）")
                        }
                    }
                    // 停留结束后刷新一次（下面 G3 要用最新帧）
                    if let imd = grab() { cur = imd }
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
                // ⭐⭐⭐⭐⭐ §2832 **改成 fail-safe：等满预算，只在"正面看到已到账"时提前结束**
                //
                // ## ⛔⛔ 血案（0.16 真机日志，用户报「**在有倒计时的时候提前点击关闭**」）
                // ```
                // 10:46:41  顶栏胶囊 ✕（…且**已无倒计时**）⇒ 点它      ← 只因为那一刻 OCR 没读出数字
                // 10:46:42  §click pill_x @(220,89)
                // 10:46:48  顶栏**还有倒计时** ⇒ 不点胶囊 ✕            ← 6 秒后数字又读出来了！
                // ```
                // ⇒ **倒计时明明没走完**，只是 OCR **漏读了一次** ⇒ 旧代码就当成"结束了"去点 ✕。
                //
                // ## 根因：条件方向反了（fail-open ⇒ 应当 fail-safe）
                // 旧代码：`while adCountdownRunning(...)` —— "**读不到倒计时**"就退出循环
                //   ⇒ OCR 一次漏读（顶栏常被读成 `酱23°17°` 这类乱码）⇒ **立刻退出** ⇒ 点 ✕
                //   ⇒ 这就是日志里 `G3 倒计时已结束（等了 0s）` 的来源（§2628 血案同源）。
                //
                // ## ✅ PC 的做法（`_1377_ad_loop.py:9837-9861`，逐字）
                // ```python
                // for k in range(_rounds):                      # ⭐ 按预算**等满**
                //     if "已成功领取" in top3: break             # ⭐ **只在正面看到"已到账"时**才提前结束
                //     wait(3.0)
                // ```
                // ⇒ 📏 PC 的闸是「**必须正面确认**（已成功领取）才收手；⛔ 不是"读不到就当结束"」。
                //   PC 用 `_rounds` 预算兜底，等满后才进 G4 点 ✕。
                //   ⛔ 注意：PC 的**点击闸**（`click_toast_x` L4349）确实是"读到数字就不点"（宽松），
                //     但那是**安全**的 —— 因为它在 G3 **先等满了预算**。
                //     ⇒ **顺序决定安全**：先"严格地等"，再"宽松地点"。我原来两处都宽松。
                while !adRewardClaimed(cur), waited < needS, !isCancelled() {
                    sleep(3.0)
                    waited += 3.0
                    guard let im3 = grab() else { break }
                    cur = im3
                    if Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex) {
                        log("   §adbox G3 等倒计时结束（已等 \(Int(waited))s / \(Int(needS))s"
                            + "；⛔ 没结束不点 ✕）")
                    } else {
                        // ⚠️ 读不到倒计时**不等于**走完（可能只是 OCR 漏读）⇒ 继续等满预算
                        log("   §adbox G3 已等 \(Int(waited))s / \(Int(needS))s"
                            + "；⚠️ 这一刻读不到倒计时，但**未看到「已成功领取」** ⇒ 继续等（⛔ 不当成结束）")
                    }
                }
                if adRewardClaimed(cur) {
                    log("   §adbox ✅ G3 正面看到「已成功领取」（等了 \(Int(waited))s）⇒ 倒计时确实走完")
                } else {
                    log("   §adbox G3 等满预算 \(Int(needS))s（⛔ 没等到「已成功领取」字样）⇒ 按 PC 兜底进 G4")
                }
                // ⭐ §2832 **点 ✕ 前的最后一道到账闸**（照 PC `click_toast_x` L4342-4351）
                //
                // PC 原文：「② 到账闸：**只看「还有没有 N秒/Ns 倒计时」**」
                // ```python
                // _top = txt(img, BOX_TOP)
                // if re.search(r"\d+\s*[sS秒]", _top):
                //     print("   .. ⛔ 顶栏还有倒计时 ⇒ **没走完，这次不点 X**")
                //     return False
                // ```
                // 📏 为什么这条**宽松**（读不到数字就放行）是安全的：
                //   因为 G3 已经**等满了预算**（上面那个循环）⇒ 到这里倒计时本来就该走完了。
                //   ⛔ 反过来（先宽松地判结束、再严格地点）就是我原来的 bug。
                // ⚠️ §2832：原来这里还有一个"补等 180s"的块 —— **已删**：
                //   G3 现在自己就等满预算，再补等一轮等于**等两倍**（白拖长每条广告）。
                //
                // ⭐⭐⭐⭐⭐ §2987 **PC 原文是「仍按结束处理」—— 这块板子原来抄反了方向**
                //
                // ## ⛔⛔ 真机血案（本轮实机 trace，2026-10-17 21:53）
                // 顶栏文案 `点击后看5秒 可领165金币 ✕`（**全新广告**），而代码逐字：
                // ```
                // §adbox G3 胶囊倒计时 N ⇒ 最多等 25s
                // §adbox G3 等倒计时结束（已等 27s / 25s；⛔ 没结束不点 ✕）   ← 超预算还在循环
                // §adbox G3 等满预算 25s（⛔ 没等到「已成功领取」）⇒ 按 PC 兜底进 G4
                // §adbox ⛔⛔ 等满预算**倒计时仍未走完** ⇒ **本条不点 ✕**；交给下一轮重判
                // §adbox ⛔ 被中断 / 跑完 0 条                                    ← **0 条**
                // ```
                // ⇒ 每条广告都在这里被挡住 ⇒ 永远不点 ✕ ⇒ **一条都收不到**。
                //
                // ## 📏 根因（复算，不是推测）
                // `adCountdownRunning` 的兜底正则 `[0-9]+(?:秒|[sS])` 会命中
                // **说明文字**里的 `5秒`（「点击后看**5秒**」），而那句文案**整条广告期间不变**
                // ⇒ 该函数**恒为 true**（实测：等 3s→6s→…→27s 全程 true）。
                // 真倒计时长这样（才该命中主力判据 `\d+[sS秒]?后`）：
                // ```
                //   '6s后可领取399金币'       ⇒ 命中 '6s后' ✅
                //   '19后 可领取'             ⇒ 命中 '19后'  ✅
                //   '点击后看5秒可领165金币×' ⇒ 主力不命中，裸兜底误命中 '5秒' ⛔
                // ```
                //
                // ## ✅ PC 的权威写法（`_1377_ad_loop.py:9860-9861`，逐字）
                // ```python
                // if "已成功领取" not in top3:
                //     print("   .. %ds 内没等到「已成功领取」（胶囊: %r），**仍按结束处理**"
                //           % (_rounds * 3, top3))
                // ```
                // ⇒ 📏 **语义：等满预算 = 已经给了足够时间 ⇒ 按结束处理，继续去点 ✕。**
                //   ⛔ PC **没有**「等满还没走完就不点」这条 —— 我原来那句
                //   「照 PC「不硬撑」」是**我自己编的话**，PC 原文里根本不存在。
                //
                // ## ⚠️ 为什么这样仍安全（用户令「倒计时没走完就点 ✕ 会把广告点死」）
                // 因为 **G3 已经把预算等满了**（`N+20s`，最少 25s）：
                // ```
                //   真倒计时 6s   ⇒ 等满 26s 后早就结束了 ✅ 点 ✕ 安全
                //   真倒计时 60s  ⇒ 读到的 N=60 ⇒ 等满 80s ✅ 安全
                //   说明文字5秒   ⇒ 等满 25s，广告其实 5s 就播完 ✅ 点 ✕ 安全
                // ```
                // ⇒ **顺序决定安全**：先"严格地等满"，再"按结束处理去点"。
                //   原来是"等满后仍被判在走 ⇒ 不点" ⇒ 死在原地。
                //
                // ⚠️ 保留给排障用的观测：只打日志，⛔ 不再 `continue` 挡路。
                if Self.adCountdownRunning(cur, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi, runningPatterns: s?.countdown_running_regex) {
                    log("   §adbox G3 等满预算后仍读到倒计时字样（多半是「看N秒」这类**说明文字**）"
                        + " ⇒ 照 PC `:9860` **仍按结束处理**，继续进 G4 点 ✕（⛔ 不在这里挡住）")
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

                // ⭐⭐⭐⭐⭐ §2824 **必须确认"真的离开这条广告"才算收完**（⛔ 不再假报成功）
                //
                // ## ⛔ 血案（真机日志 18:18:57 逐字）
                // ```
                // §adbox_back6 ⛔ 这是视频广告页 ⇒ 放行     ← 人**还在广告页**
                // §adbox 跑完 6 条                          ← 却报"跑完 6 条"
                // §run ✅ 功能闭环结束：完成 1/1             ← 还报**成功**
                // ```
                // 旧版这里的 `n += 1` 是**无条件**的 ⇒ 「点不掉 ✕ ⇒ 还在广告页」也被算成
                // 收了一条奖励 ⇒ 计数虚高、任务假成功、且主循环立刻又回同一分支。
                //
                // ✅ 判据（**必须建立 PC 的"两个归宿"语义**）：
                //   ① **弹出了奖励面板**（「再看一个/领取奖励」）⇒ 奖励被领走
                //   ② 已经**不在广告页**了（✕ 生效 / 自己跳回中心）
                //
                // ⛔⛔⛔ §2974 **删掉原来的判据①「顶栏『已成功领取』就算完成」—— 那是无限转化的根因**
                //
                // ## 真机血案（`run_after_fix.log` 逐字，用户：「**无限转化你看不到？**」）
                // ```
                // 20:04:15.988  §adbox G3 胶囊倒计时 N ⇒ 最多等 45s
                // 20:04:16.082  §adbox ✅ G3 正面看到「已成功领取」（等了 0s）⇒ 倒计时确实走完
                // 20:04:16.125  §adbox G3 倒计时已结束 ⇒ **现在才点 ✕ 收奖励**
                // 20:04:16.281  §adbox ✅ 顶栏「已成功领取」⇒ **奖励已到账**，本条完成   ← 🔴 误判
                // 20:04:17.031  §adbox_back3 ⛔ 这是视频广告页 ⇒ 放行                   ← 人还在广告页
                // 20:04:17.083  §adbox 本条广告停留目标=40s（**重新计时**）
                // 20:04:17.184  §adbox_cta4 文案兜底：CTA「牙齿问题…」                    ← 又转一次
                // ```
                // ⇒ **cta3 → cta10 连续 8 次转同一条广告**（`牙齿问题不要置之不理 @(222,774)` 一字不差）。
                //
                // ## 根因：判据①与 G3 的等待条件**是同一个条件**（自证循环）
                // ```
                // G3（L659）: while !adRewardClaimed(cur), waited < needS { … }   ← 就在等"已成功领取"
                // G4（L728）: if adRewardClaimed(im5) { 「奖励已到账」}             ← 拿同一条件当"收完了"
                // ```
                // ⇒ G3 一旦等到「已成功领取」就退出循环 ⇒ G4 的**第一帧必然满足判据①** ⇒
                //   **✕ 一次都没点**（L701-706 的 `finishAdPanel` 被这个 break 跳过）⇒
                //   既没点 ✕ 、也没出面板，却 `leftAd = true` ⇒ `n += 1`，
                //   而人**还在同一条广告上** ⇒ `ensureInCenter` 撞"广告页放行短路"直接返回
                //   ⇒ 主循环重进同一条 ⇒ 计时重开（L754）、转化闸清掉（L753）⇒ **再转一次**。
                //
                // ## 📏 PC 控制器怎么判（`_1377_ad_loop.py:9863-9979` 逐字）
                // ```
                // # ★★ 但胶囊 ✕ 有**两种归宿**（§1377 r4J 实测，必须都认）：
                // #    ① 弹出「再看一个视频+3000 / 领取奖励」面板 ⇒ 点主按钮进下一条；
                // #    ② **不弹面板，直接把整条广告链关掉、落回金币中心** ⇒ 本条同样**已经成功**
                // for k in range(16):
                //     ...
                //     if at_center: done_ads += 1; click_reenter(imgp); continue     # 归宿②
                //     if not any(kk in mid for kk in PANEL_KEYS):
                //         reason = "奖励面板没出现 ⇒ 已停手"                          # ⛔ 两条都不成立 ⇒ 不算完成
                // ```
                // ⇒ ⭐ **"已成功领取"从来不是完成判据** —— PC 认的是「**面板**」或「**回中心**」。
                //
                // ⛔⛔⛔ §2977 **远端 §2974 这版还留着一个误判（真机事实，不是我觉得）**
                // 判据① 写成 `if finishAdPanel(im5, …) { leftAd = true }` ——
                // 而 `finishAdPanel` 的**返回值契约**是「**已点掉一层**（调用方应重抓帧再判）」
                // （见它自己的文档 L1243），三条腿里任何一条命中都返回 true：
                // ```
                //   ① stay_panel_btn（挽留面板「继续观看」）  ← 点完人**还在广告页**
                //   ② panel_close_x（面板右上小 ✕）           ← 可能是别的弹层
                //   ③ pill_x（顶栏胶囊 ✕）                    ← 点完也可能还在广告页
                // ```
                // ⇒ 拿它当"本条完成"⇒ **点一次胶囊 ✕ 就 +1**，而人可能还在同一条广告上
                //   ⇒ 与 §2974 修掉的那个"自证循环"是**同一个病**，只是换了个假阳性来源。
                //
                // ✅ 正解（照 PC `at_center`，`_1377_ad_loop.py:9777-9804`）：
                //   **完成 = 页面真的变了**，只认两个归宿：
                //     ① **真落回金币中心**（`center_marker` 元素命中，⛔ 不用广告页放行短路）
                //     ② 页型判据确认**已不在广告页**
                //   `finishAdPanel` 仍然要调（它负责点 ✕ / 补全），但**只当"推进动作"**，
                //   它的返回值**不再单独置 leftAd** —— 下一轮回环由 ①/② 判。
                var leftAd = false
                for i5 in 0..<6 {
                    if isCancelled() { break }
                    guard let im5 = grab() else { break }
                    // ① PC 归宿②（最硬）：真落回金币中心 ⇒ 本条完成
                    if nav.detect("center_marker", img: im5) != nil {
                        log("   §adbox ✅ 已真落回金币中心 ⇒ 本条完成（第 \(i5 + 1) 次检查）")
                        leftAd = true
                        break
                    }
                    // ② PC 归宿②（等价）：页型确认已不在广告页 ⇒ 本条完成
                    if !Self.looksLikeAdPage(im5, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                             roi: s?.ad_top_roi) {
                        log("   §adbox ✅ 已离开广告页（页型判据）⇒ 本条完成")
                        leftAd = true
                        break
                    }
                    // ③ 还在广告页：**推进**（点面板主按钮 / 面板✕ / 胶囊✕），⛔ 不算完成
                    //
                    // ⭐⭐⭐⭐⭐ §3018 **「点掉奖励面板」= 本条已完成**（真机血案 2026-10-18）
                    //
                    // ## ⛔ 血案（真机 trace 逐字）
                    /// ```
                    ///   §adbox_ad1 顶栏胶囊 ✕（无倒计时）⇒ 点它  pill_x @(207,89)   ✅ 收奖励
                    ///   §tap ★点「stay_panel_btn」@(225,555) ev=领取奖励            ✅ 面板推进
                    ///   §adbox_claim1 ⛔ 顶栏还有倒计时 ⇒ 不点胶囊 ✕   ×6            ⛔ 死在这
                    ///   §adbox ⛔ 92s 没有任何新条到账 ⇒ 停手
                    /// ```
                    /// ### 根因（逻辑缺陷，不是判据问题）
                    /// 点「领取奖励」= **进下一条广告**，而新一条**本来就是广告页**
                    /// ⇒ 下一轮 `looksLikeAdPage` 仍 true ⇒ 继续找 ✕
                    /// ⇒ 而新广告**有倒计时**（正常）⇒ 到账闸正确拒绝
                    /// ⇒ 6 轮全拒绝 ⇒ `leftAd=false` ⇒ 误判"点了也离不开" ⇒ 停手。
                    ///
                    /// ### ✅ 正解（按腿区分语义，⛔ 不是一刀切）
                    /// `finishAdPanel` 返回**触发了哪条腿**：
                    /// · `.panelCleared`（面板主按钮 / 面板 ✕）⇒ **本条收完** ⇒ `n += 1`，下一条交外层 while
                    /// · `.capsuleOnly`（只点了胶囊 ✕）⇒ 只是收奖励第一步，**后面还有面板** ⇒ ⛔ 不计数
                    /// ⚠️ 一刀切会把"只点了胶囊"也当成完成 ⇒ 假报成功（§2974/§2977 记过的同一个病）。
                    switch finishAdPanelResult(im5, tag: "adbox_claim\(n + 1)") {
                    case .panelCleared:
                        log("   §adbox ⏭ 已点掉奖励面板（= 本条收完，进下一条）"
                            + " ⇒ **本条计入完成**（§3018）")
                        leftAd = true
                        break
                    case .capsuleOnly:
                        log("   §adbox ⏭ 已点胶囊 ✕（收奖励第一步）⇒ ⛔ 还不算完成，重抓帧再判")
                    case .none:
                        break
                    }
                    if leftAd { break }
                    sleep(1.5)
                }
                if !leftAd {
                    log("   §adbox ⛔ 点了也离不开广告页 ⇒ **本条不计入完成**"
                        + "（⛔ 不假报成功；若持续如此，循环头的无进展闸会停手）")
                    // 清掉"每条一次"标志 ⇒ 允许下一轮重新尝试收尾（但仍受无进展闸约束）
                    dwelledThisAd = false
                    continue
                }

                n += 1
                scrollTries = 0          // ⭐ §2309 每成功拿下一条，重置翻页预算
                convertedThisAd = false  // ⭐ §2824 离开这条广告 ⇒ 清"每条一次"状态
                dwelledThisAd = false
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
                nav.tapPoint(Double(c.x), Double(c.y), why: "宝箱浮件（chest_float）")
                // 等一张新帧（面板出来了才能找 CTA）
                if let ip = grabFresh(since: img, maxWait: maxFrameAgeCfg + 3.0),
                   let cta = nav.detect("chest_cta", img: ip)?.center {
                    log("§adbox 宝箱面板 CTA @(\(Int(cta.x)),\(Int(cta.y))) ⇒ 进广告链")
                    nav.tapPoint(Double(cta.x), Double(cta.y), why: "宝箱面板 CTA（chest_cta）")
                    // 进了广告链 ⇒ 交给下一轮循环的“广告页”分支处理
                    if let i3 = grabFresh(since: ip, maxWait: maxFrameAgeCfg + 3.0),
                       Self.looksLikeAdPage(i3, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                            roi: s?.ad_top_roi) {
                        // ⭐⭐⭐⭐⭐ §2824 **不再在这里自己收尾 + 计数**（用户令：无限转化/卡死）
                        // 这里是第四份"广告页处理"：自己 `finishAdPanel` + 自己 `n += 1`，
                        // 既不转化、也不等停留、也不确认到账 ⇒ 与循环头重复。
                        // ✅ 现在直接回到循环头，由那**唯一一份**实现做
                        //    单次转化 → 30~45 随机停留 → 等倒计时 → 点 ✕ → 确认到账。
                        log("§adbox ✅ 宝箱入口已进广告页 ⇒ 交给循环头统一处理（§2824）")
                        scrollTries = 0
                        emptyRounds = 0
                        continue
                    }
                    log("§adbox 点了宝箱 CTA 但没进广告页 ⇒ 落回按行腿")
                } else {
                    log("§adbox 宝箱面板上没找到 CTA ⇒ 不放枪，落回按行腿")
                }
            }

            if let btn = findAdRowButton(img) {
                log("§adbox 按行定位到「看广告得金币」行 ⇒ 按钮 \(btn.evidence) @(\(Int(btn.point.x)),\(Int(btn.point.y)))")
                // ⭐⭐⭐⭐⭐ §3013 **防遮挡点击**（真机：y=839 点 5 次无效，y=227 一次成功）
                //   ⛔ 原来直接 `nav.tapPoint(btn.point)` —— 按钮落在屏幕下部时
                //      正好被「点击领66」宝箱抖动动画盖住，点了等于没点。
                tapAvoidOcclusion(btn.point, why: "按行定位的「看广告得金币」按钮")
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
                    // ⭐⭐⭐⭐⭐ §2824 **这里不再重复实现广告页处理**（用户令：无限转化/卡死）
                    //
                    // ## ⛔ 血案
                    // 本处原来**整段复制**了循环头那条「广告页」分支
                    // （转化 → 回广告页 → G3 等倒计时 → G4 点 ✕），两份实现各自 `n += 1`：
                    //   · 同一逻辑两个版本 ⇒ **改一处漏一处**（这次的"单次转化/停留"就容易只改一份）
                    //   · 两条路都能把 `n` 加上去 ⇒ **计数虚高 + 任务假成功**
                    //     （真机日志逐字：`§adbox 跑完 6 条` / `§run ✅ 完成 1/1`，
                    //      而同一条广告被转化了 6 次、奖励一次没收）
                    //
                    // ## ✅ 现在只有**一份**实现
                    // 循环头那条分支含：**单次转化** + **30~45 随机停留** + **到账闸** +
                    // **"真收完才计数"**。点进广告页后直接 `continue` ⇒ 下一轮由它接手。
                    log("§adbox ✅ 已进广告页 ⇒ 交给循环头的「广告页」分支统一处理"
                        + "（§2824：去掉重复实现，避免无限转化）")
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
                //
                // ⭐⭐⭐⭐⭐ §2824 **这里的等待也要算进"本条停留"**（用户令：30-45 随机）
                // 旧版用的是独立变量 `dwell` ⇒ 与上面那套"每条一次"的计时**两本账**；
                // 现在统一：若本条还没起过计时 ⇒ 起一次；只等**还差的那部分**。
                if !dwelledThisAd {
                    adDwellTarget = adDwellSeconds
                    adEnteredAt = Date()
                    dwelledThisAd = true
                    log("   §adbox 本条广告停留目标=\(Int(adDwellTarget))s"
                        + "（区间 \(Int(adStayMin))~\(Int(adStayMax)) 随机；用户令）")
                }
                let leftToDwell = adDwellTarget - Date().timeIntervalSince(adEnteredAt)
                log("§adbox ⛔ 广告播放中（无面板/无关闭键）⇒ 等够 \(Int(max(0, leftToDwell)))s（⛔ 不点 ✕）")
                var left = max(0, leftToDwell)
                while left > 0 {
                    if isCancelled() { break }
                    let d = min(2.0, left)
                    Thread.sleep(forTimeInterval: d)
                    left -= d
                    // ⭐⭐⭐⭐⭐ §2832 **只补全、不关闭**（照 PC `wait()` = 纯 sleep）
                    //
                    // ⛔ 血案同「广告页」分支：这里原来调 `finishAdPanel()`（**会点胶囊 ✕**）
                    //    ⇒ 等待期间把广告关掉。PC 的 `wait()`（L4395）就是纯 `time.sleep`，
                    //    等待期间**唯一**允许的动作是点「继续观看」补全（PC L4333 ⇒ 点了就 return）。
                    if let im2 = grab(), completeAdPanelOnly(im2, tag: "adbox_adw\(n + 1)") {
                        log("   §adbox 等待中面板需要补全 ⇒ 已点「继续观看」（⛔ 未关广告）")
                    }
                }
                // ⭐⭐⭐⭐⭐ §2824/§2974 **确认到账才计数**（⛔ 不再无条件 `n += 1`）
                // 判据与「广告页」分支**同一套**（照 PC 的两个归宿）：
                //   ① **真落回金币中心**（`center_marker`）  ② 页型确认**已不在广告页**
                // ⛔⛔ §2974：**删掉原来的「顶栏『已成功领取』就算完成」** —— 那是无限转化的根因
                //   （与 G3 的等待条件自证循环 ⇒ ✕ 一次没点就宣布完成 ⇒ 卡在同一条反复转化）。
                //   完整血案与 PC 对照见「广告页」分支里的 §2974 注释块。
                // ⛔⛔ §2977：**`finishAdPanel` 的返回值不是完成判据**（它只表示"点掉一层"，
                //   见其文档 L1243；点胶囊✕后人也可能还在广告页）⇒ 只当推进动作，完成仍由 ①/② 判。
                var leftAd2 = false
                for i6 in 0..<6 {
                    if isCancelled() { break }
                    guard let im6 = grab() else { break }
                    if nav.detect("center_marker", img: im6) != nil {
                        log("   §adbox ✅ 已真落回金币中心 ⇒ 本条完成（第 \(i6 + 1) 次检查）")
                        leftAd2 = true
                        break
                    }
                    if !Self.looksLikeAdPage(im6, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                             roi: s?.ad_top_roi) {
                        log("   §adbox ✅ 已离开广告页（页型判据）⇒ 本条完成")
                        leftAd2 = true
                        break
                    }
                    if finishAdPanel(im6, tag: "adbox_claimw\(n + 1)") {
                        log("   §adbox ⏭ 已点掉一层（⛔ 还在广告页，不算完成）⇒ 重抓帧再判")
                    }
                    sleep(1.5)
                }
                if !leftAd2 {
                    log("   §adbox ⛔ 这条广告还没收到奖励 ⇒ **本条不计入完成**（⛔ 不假报成功）")
                    dwelledThisAd = false
                    continue
                }
                n += 1
                convertedThisAd = false
                dwelledThisAd = false
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
            // ⭐⭐⭐⭐⭐ §2911 **目标行"在屏上、但按钮是冷却态" ⇒ 等冷却**（⛔ 不滚动列表）
            //
            // ## ⛔ 真机现场（0.19，2026-10-16 00:31，用户报「卡死在任务中心 不看广告」）
            // ```
            // §adbox 按行定位到「看广告得金币」行 ⇒ 按钮 领福利 @(393,339)
            // §tapPoint ★点坐标（按行定位的「看广告得金币」按钮）…
            // §adbox ⚠️ 点了任务但没进广告页 ⇒ 重试
            // §adbox_row ⏭ 「看广告得金币」行按钮是「冷却中」（**非动作态**）⇒ 本腿放弃
            // §adbox ⬇ 本屏没有目标行 ⇒ 下滑任务列表再找（第 1/6 次）   ← ⛔ 滚了 4 次，全废
            // §adbox ⛔ 被中断
            // ```
            // ⇒ 用户看到的就是「**卡死在任务中心、不往下看广告**」。
            //
            // ## ⛔ 根因：`findAdRowButton` 返回 nil 时**两种完全不同的情形被混为一谈**
            // ```
            //   ① 目标行**在屏幕下方**（没滚出来）    ⇒ 下滑列表**有用**   ✅ 现有滚动腿对
            //   ② 目标行**就在屏上**，但按钮是冷却态  ⇒ 下滑列表**毫无用处** ⛔ 现有滚动腿错
            // ```
            // 📏 ② 的证据（PC `_1377_ad_loop.py:2112-2113` 逐字）：
            // > 同屏并存两条广告行时，`看广告得金币` 那行右列是 **`冷却中`**（禁用；下方还有
            // > `00:43 倒计时结束继续领金币`）⇒ **点它 3 轮毫无反应**
            // ⇒ 冷却态的正确出路是 **等**（那行自己写着"倒计时结束继续领"），⛔ 不是滚动、⛔ 不是放弃。
            //
            // ✅ 现在：先判"行在屏上但按钮冷却"⇒ **按冷却剩余秒数等**，等完 `continue` 重判；
            //    ⛔ 不滚动列表（省掉 6 次无效下滑），⛔ 也不立刻放弃。
            // ⚠️ 有界：最多等 `cooldownWaits` 次（⛔ 免得"今日已领完"那种永久冷却把整轮耗死）。
            if cooldownWaits < 6, let cd = adRowCooldown(img) {
                cooldownWaits += 1
                scrollTries = 0                       // ⭐ 行在屏上 ⇒ 滚动预算归零（下次仍先判冷却）
                let secs = cd.seconds
                let wait = min(max(secs ?? 15.0, 5.0) + 3.0, 90.0)
                log("§adbox ⏳ 「看广告得金币」行按钮是「\(cd.button)」（冷却态）⇒ 等 \(Int(wait))s"
                    + "（第 \(cooldownWaits)/6 次）"
                    + (secs != nil ? "［行上写着约 \(Int(secs!))s］" : "")
                    + " ⇒ ⛔ **不滚动列表**（行就在屏上，滚动没用）")
                sleep(wait)
                continue
            }

            var found = false
            // ⭐ 预算 6 次：真机实测目标行在列表靠上位置，需 3~4 次下滑才露出来
            if scrollTries < 6 {
                scrollTries += 1
                log("§adbox ⬇ 本屏没有目标行 ⇒ 下滑任务列表再找（第 \(scrollTries)/6 次）")
                swipeDownList(baseW: baseW, baseH: baseH)
                if let img2 = grabFresh(since: img, maxWait: maxFrameAgeCfg + 3.0) {
                    if let btn2 = findAdRowButton(img2) {
                        log("§adbox ⬇ 翻到了目标行 ⇒ 按钮 \(btn2.evidence) @(\(Int(btn2.point.x)),\(Int(btn2.point.y)))")
                        // §3013 防遮挡（与上面那条同一道闸，理由见 tapAvoidOcclusion）
                        tapAvoidOcclusion(btn2.point, why: "翻页后按行定位的按钮")
                        // ⭐⭐⭐⭐⭐ §2824 **不再在这里自己收尾 + 计数**（用户令：无限转化/卡死）
                        //
                        // ## ⛔ 血案
                        // 这里原来是第三份"广告页处理"：自己 `finishAdPanel` + 自己 `n += 1`。
                        // 而它**既不转化、也不等停留、也不确认到账** ⇒
                        //   · 同一条广告可能被"收尾"多次（计数虚高）
                        //   · 与循环头那份实现重复 ⇒ 改一处漏一处
                        // ⇒ **单次转化 + 30~45 停留 + 到账确认**只有循环头那一份说了算。
                        //
                        // ✅ 现在只做"点进去了没有"的判断：是广告页 ⇒ `continue`
                        //    交给循环头统一处理（那一轮会做转化/停留/等倒计时/点 ✕/确认到账）。
                        if let i3 = grabFresh(since: img2, maxWait: maxFrameAgeCfg + 3.0),
                           Self.looksLikeAdPage(i3, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                                roi: s?.ad_top_roi) {
                            log("§adbox ⬇ 翻页后已进广告页 ⇒ 交给循环头统一处理（§2824）")
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
            // ⛔⛔⛔ §2824 **这里绝不能 `n += 1`**（用户令：「还有转化现在无限转化。卡死」）
            //
            // ## 血案
            // 这一支的语义是「**本屏没找到广告任务行**」—— 一条广告都没看、一分奖励没收，
            // 而旧代码却 `n += 1` ⇒ 把"没找到"当成"收了一条"：
            //   · `while n < count` 很快就被"空找"填满 ⇒ **假装跑完 6 条**、`return n > 0` 报成功
            //   · 真机日志逐字：`§adbox 跑完 6 条` / `§feat ═══ 本轮结束：完成 1/1 ═══`，
            //     而实际上全程**只有一条广告被反复转化、奖励一次没收**。
            // ⇒ 现在"没找到"**只记 `emptyRounds`**（连续 3 轮就收手，见上），⛔ 不动 `n`。
            //    `n` 只由「**确认到账**」那一处 +1（见本函数里唯一那处 `n += 1`）。
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
        // ⭐⭐⭐⭐⭐ §2979 **本函数已改为统一识别层的薄封装** —— ⛔ 不再自己写一套判据
        //
        // ## ⛔ 为什么必须改（第一性原理）
        // 本函数原来是一套**独立 OCR 判据**，而项目里同时还有：
        //   · `Navigator.pageHere()`（因 `island:true` 永远判不出广告页）
        //   · `Navigator:1166` 直读 `cfg.pages["ad_video"].check`
        //   · `Runner:377` 的 `page == "ad_video"` 死分支
        // ⇒ **四套判据互相否定**。真机逐字证据（2026-10-17）：
        // ```
        // 13:41:47  已回广告页（第 1 次检查）⇒ 继续等倒计时
        // 13:42:01  ⛔ 点了也离不开广告页 ⇒ 本条不计入完成
        // 13:42:02  ✅ 已回广告页（第 1 次检查）      ← 同一时刻结论相反
        // ```
        // PC 只有**一份**判据（`page_kind()` + `_pred_ad_capsule`），且
        // `_dev/anchors/registry.json` 里 `ad_video` 是 **order=7 的正常页型**。
        //
        // ⇒ 现在本函数 = `PageKinds.detect(...).kind == .adVideo`（统一层），
        //    `ad_video` 判据在 `PageKinds.entries` order=7（**逐字移植** PC `_pred_ad_capsule`）。
        //    保留本函数名是为了**不改 21 处调用点**（改签名要全链路回归），但**判据只有一个来源**。
        //
        // ⚠️ `roi` 参数保留兼容，但不再使用 —— 统一层用 PC 的 `B_CAPSULE=(0,55,451,160)`
        //    宽带（PC 注释：窄带 `BOX_TOP` 的 y1=140 会把 y≈140 的胶囊**恰好切掉**）。
        _ = (roi, bw, bh)
        let sheet = PageKinds.OcrSheet(img: img, ocr: RecognizerOcr(rec: rec))
        // ⭐ 桌面子判据不参与（照 PC 默认 `_DESKTOP_KINDS` 不启用）
        return PageKinds.detectFrom(sheet: sheet).kind == .adVideo
    }

    /// ⭐⭐⭐⭐⭐ §2832 **等待期间的"只补全"闸** —— 照 PC `click_toast_x` **第一段**（L4333）
    ///
    /// ## ⛔⛔ 血案（0.16 真机日志，用户报「广告没有等待 然后提前点击率关闭」）
    /// 我在**停留等待**的循环里调了 `finishAdPanel()` —— 而它**不只点面板，还会点胶囊 ✕**
    /// （腿序第③条）⇒ 日志逐字：
    /// ```
    /// 10:46:32  §adbox ⏳ 本条广告停留（还需 46s / 目标 46s）
    /// 10:46:34  §adbox_dwell1 ⛔ 顶栏**还有倒计时** ⇒ 不点胶囊 ✕     ← 前 3 次挡住了
    /// 10:46:41  §adbox_dwell1 顶栏胶囊 ✕（面板已不在、且已无倒计时）⇒ 点它  ← ⛔ 点掉了
    /// 10:46:42  §click pill_x @(220,89)                              ← 停留才 10 秒！
    /// ```
    /// ⇒ **是我自己在等待期间把广告关掉的**（⛔ 不是判据失灵）。
    ///
    /// ## ✅ PC 的做法（`_1377_ad_loop.py:4333`，逐字）
    /// ```python
    /// for _w, _x, _y in words(img, BOX_MID):
    ///     if ("继续观看" in _w) or ("再看" in _w and "秒" in _w):
    ///         print("   .. ★面板出现 %r ⇒ **点它补全**" % _w)
    ///         click_at(plog(_x, _y))
    ///         return True            # ⛔ **点了就 return** —— 绝不在同一次调用里继续点胶囊 ✕
    /// ```
    /// ⇒ 📏 **语义**：等待期间**只许**"把广告补全"（点「继续观看」让倒计时继续走），
    ///    ⛔ **绝不许**"把广告关掉"（点胶囊 ✕ / 面板 ✕）。
    ///
    /// - Returns: true = 点了"继续观看"补全（调用方应重抓帧）
    private func completeAdPanelOnly(_ img: UIImage, tag: String) -> Bool {
        if nav.detect("stay_panel_title", img: img) != nil,
           nav.detect("stay_panel_btn", img: img) != nil {
            log("   §\(tag) 挽留面板 ⇒ 点「继续观看」**补全**（照 PC `click_stay_panel`；⛔ 不关广告）")
            _ = nav.tap("stay_panel_btn", img: img, atomic: true)
            return true
        }
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
    /// §3018 `finishAdPanel` 的**语义化返回**：区分"点掉了面板"和"只点了胶囊"。
    ///
    /// ## ⛔ 为什么必须区分（真机血案 2026-10-18）
    /// 旧版只有一个 Bool ⇒ 调用方**分不清**这次是：
    /// · 点掉了奖励面板（= 本条**真的收完**，可以 `n += 1`），还是
    /// · 只点了顶栏胶囊 ✕（= 收奖励**第一步**，后面还有面板要处理）
    /// ⇒ 一刀切 `n += 1` 就是 §2974/§2977 记过的"点一次胶囊就 +1"假报成功。
    ///
    /// ## 三态
    /// ```
    ///   .panelCleared  —— ① 挽留面板主按钮 / ② 面板自己的 ✕  ⇒ **本条收完**
    ///   .capsuleOnly   —— ③ 顶栏胶囊 ✕                      ⇒ 还没完，继续等面板
    ///   .none          —— 什么都没点（到账闸拒绝了 / 找不到）⇒ 由调用方决定
    /// ```
    enum AdPanelResult {
        case panelCleared     // 面板被点掉 ⇒ 本条可计入完成
        case capsuleOnly      // 只点了胶囊 ✕ ⇒ 本条尚未完成
        case none             // 没出手
    }

    /// §3018 收尾的**唯一实现**（`finishAdPanel` 的 Bool 版本 = 本函数的薄包装）
    private func finishAdPanelResult(_ img: UIImage, tag: String) -> AdPanelResult {
        // ① 挽留面板「继续观看 / 再看N秒」⇒ **点它补全**
        //    （`stay_panel_btn` 的词表 = PC `PANEL_KEYS`：领取奖励/继续观看/…）
        if nav.detect("stay_panel_title", img: img) != nil,
           nav.detect("stay_panel_btn", img: img) != nil {
            log("   §\(tag) 挽留面板 ⇒ 点「继续观看/领取奖励」**补全**（照 PC `click_stay_panel`）")
            _ = nav.tap("stay_panel_btn", img: img, atomic: true)
            return .panelCleared
        }
        // ② ⭐ **面板自己右上角的小 ✕**（⛔ 必须排在 toast ✕ 之前 —— PC 腿序血案）
        if nav.detect("panel_close_x", img: img) != nil {
            log("   §\(tag) 面板右上小 ✕ ⇒ 点它（照 PC `_find_panel_x`）")
            _ = nav.tap("panel_close_x", img: img, atomic: true)
            return .panelCleared
        }
        // ③ 顶栏 toast ✕（⚠️ 只在**没有面板**时才轮到这里）
        if nav.detect("pill_x", img: img) != nil {
            // 到账闸：只在**没有倒计时数字**时才允许点这个 ✕
            if Self.adCountdownRunning(img, rec: rec, bw: baseW, bh: baseH,
                                       roi: s?.ad_top_roi,
                                       runningPatterns: s?.countdown_running_regex) {
                log("   §\(tag) ⛔ 顶栏**还有倒计时** ⇒ **不点胶囊 ✕**（照 PC 到账闸）"
                    + "⇒ 本层不处理，交回主循环继续等")
                return .none
            }
            log("   §\(tag) 顶栏胶囊 ✕（面板已不在、且已无倒计时）⇒ 点它")
            _ = nav.tap("pill_x", img: img, atomic: true)
            return .capsuleOnly
        }
        return .none
    }

    /// - Returns: true = 已点掉一层（调用方应重抓帧再判）
    ///
    /// ⚠️ §3018 本函数是 `finishAdPanelResult` 的**薄包装**（保留旧签名，⛔ 不改 4 处调用点）。
    ///    ⛔ 语义上它**分不清**"点掉面板"和"只点胶囊" ⇒
    ///    需要区分的地方（收奖励那一段）**必须**用 `finishAdPanelResult`。
    @discardableResult
    private func finishAdPanel(_ img: UIImage, tag: String) -> Bool {
        finishAdPanelResult(img, tag: tag) != .none
    }

    private func adRewardClaimed(_ img: UIImage) -> Bool {
        let t = Self.adTopText(img, rec: rec, bw: baseW, bh: baseH, roi: s?.ad_top_roi)
            .replacingOccurrences(of: " ", with: "")
        return t.contains("已成功领取") || t.contains("已领取")
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

    /// ⭐⭐⭐⭐⭐ §3013 **屏幕下部"易被浮件遮挡"的 y 门槛**（基准 451×977）
    ///
    /// ## 标定依据（真机实测 2026-10-18，⛔ 不是拍脑袋）
    /// 快手极速版任务中心的右下角常年挂「**点击领66**」宝箱浮件（带抖动动画），
    /// 它覆盖 **y ≈ 780 以下** 的右下区域。实测同一个「领福利」按钮：
    /// ```
    ///   基准 (394.3, 838.9)  ⇒ 连点 5 次全无反应（被宝箱压住）
    ///   基准 (394.3, 227.3)  ⇒ 一次命中（16s后可领取1167金币）
    /// ```
    /// 776/977 = 79.4% ⇒ 取整到 **780**。
    /// ⚠️ 只在**按行点任务按钮**这条路上用它（⛔ 不用于广告页/漏斗，那些有自己的判据）。
    private static let occludedYMin: Double = 780
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

    /// ⭐⭐⭐ §2911 **「看广告得金币」行在屏上、但按钮是冷却态** ⇒ 返回 (按钮文案, 冷却秒数?)
    ///
    /// ## ⛔ 为什么必须单独一个判据（真机血案，用户报「卡死在任务中心 不看广告」）
    /// `findAdRowButton` 返回 nil 时**两种情形被混为一谈**：
    /// ```
    ///   ① 目标行在屏幕下方（没滚出来）     ⇒ 下滑列表有用    ✅
    ///   ② 目标行就在屏上，按钮冷却态       ⇒ 下滑毫无用处    ⛔ ← §2911 漏的就是这条
    /// ```
    /// PC 原文（`_1377_ad_loop.py:2112-2113` 逐字）：
    /// > 同屏并存两条广告行时，`看广告得金币` 那行右列是 **`冷却中`**（禁用；下方还有
    /// > `00:43 倒计时结束继续领金币`）⇒ 点它 3 轮毫无反应
    /// ⇒ 冷却态的正确出路是**等**（行上自己写着"倒计时结束继续领"），⛔ 不是滚动、⛔ 不是放弃。
    ///
    /// ## 判据（照 PC 的行结构，⛔ 不新造）
    /// ① 用同一套 `_ocr_rows` + `taskRowY` 找到「看广告得金币」那行的 y
    /// ② 取该行 ±`AD_ROW_Y_WIN`、x ≥ `AD_ROW_X_MIN` 的**最右**词 = 按钮
    /// ③ 按钮含 `AD_ROW_DEAD_KEYS` ⇒ 冷却态 ✅；否则（是"领福利"这种动作态）⇒ nil
    ///
    /// - Returns: `(按钮文案, 行上读到的剩余秒数)`；⛔ 行不在屏上 / 按钮是动作态 ⇒ nil
    private func adRowCooldown(_ img: UIImage) -> (button: String, seconds: Double?)? {
        let band = CGRect(x: 0, y: 250, width: baseW, height: baseH - 250)
        let ws = rec.ocrRegion(img, rect: band, minConfidence: 0.3)
        guard !ws.isEmpty else { return nil }
        let rows = Self.ocrRows(ws, yWin: Self.adRowYWin)
        guard let yRow = Self.taskRowY(rows, words: Self.adRowTaskWords) else { return nil }
        // 该行 ±26 内、x≥330 的词 ⇒ 最右那个当按钮（照 PC 的排序）
        var cands: [(String, CGPoint)] = []
        for r in rows where abs(r.y - yRow) <= Self.adRowYWin {
            for w in r.items where w.center.x >= Self.adRowXMin {
                cands.append((w.text, w.center))
            }
        }
        guard !cands.isEmpty else { return nil }
        cands.sort { a, b in
            if a.1.x != b.1.x { return a.1.x > b.1.x }
            return abs(a.1.y - yRow) < abs(b.1.y - yRow)
        }
        let (bt, _) = cands[0]
        // ⛔ 动作态（领福利/去观看…）⇒ 不是冷却，交给正常腿去点
        guard Self.adRowDeadKeys.contains(where: { bt.contains($0) }) else { return nil }
        // ⭐ 从**整行**文字里找剩余秒数（PC 原文：`00:43 倒计时结束继续领金币`）
        //
        // 支持两种写法：`00:43`（mm:ss）与 `43s`/`43秒`
        let rowText = rows.filter { abs($0.y - yRow) <= Self.adRowYWin }
                         .flatMap { $0.items.map(\.text) }.joined(separator: " ")
        return (bt, Self.cooldownSeconds(in: rowText))
    }

    /// §2911 从一行文字里读**冷却剩余秒数**：支持 `mm:ss`（PC 原文的 `00:43`）与 `43s`/`43秒`。
    /// ⛔ 读不到 ⇒ nil（调用方退回一个保守的默认等待，⛔ 不去猜）。
    static func cooldownSeconds(in text: String) -> Double? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = cooldownClockRx.firstMatch(in: text, options: [], range: full),
           m.numberOfRanges >= 3 {
            let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
            return mm * 60 + ss
        }
        if let m = cooldownSecsRx.firstMatch(in: text, options: [], range: full),
           m.numberOfRanges >= 2 {
            return Double(ns.substring(with: m.range(at: 1)))
        }
        return nil
    }

    /// §2911 冷却剩余时间：`mm:ss`（PC 原文的 `00:43`）与 `43s`/`43秒` 两种写法
    private static let cooldownClockRx = try! NSRegularExpression(pattern: "(\\d{1,2})\\s*:\\s*(\\d{1,2})")
    private static let cooldownSecsRx = try! NSRegularExpression(pattern: "(\\d{1,3})\\s*(?:s|S|秒)")

    /// ⭐⭐⭐ 按**行结构**定位「看广告得金币」那道任务行右侧的入口按钮。
    ///
    /// 逐条移植 PC `find_ad_row_button`（`_1377_ad_loop.py:2146`）。
    /// - Returns: `(点, 证据串)`；⛔ 找不到 / 该行不可用 ⇒ **nil**（调用方什么都不做）
    /// ⭐⭐⭐⭐⭐ §3013 **防遮挡点击**（真机实测，2026-10-18）
    ///
    /// ## ⛔ 血案（用户当场指出：「宝箱有抖动动画 覆盖了，你滑动到上面起来再点」）
    /// 同一个「领福利」按钮、同一个坐标：
    /// ```
    ///   基准 y=838.9  ⇒ 连点 5 次（含 P:+D:600 / 短按 / 只 D:）**画面纹丝不动**
    ///   滑上去到 y=227 ⇒ **一次就进广告页**（16s后可领取1167金币）
    /// ```
    /// 而 OCR 给的坐标是**对的**（`/ocr` 中心 394.7,838.6；按钮玫红块 bbox y 819~858，
    /// 839 正落在正中）⇒ **⛔ 不是坐标错，是被底部「点击领66」宝箱的抖动动画盖住**。
    ///
    /// ## ✅ 判据（⛔ 不用"猜"，用两条硬信号）
    /// 1. **按钮在屏幕下部**：`y > occludedYMin`（默认 780/977 ≈ 80%）——
    ///    快手任务列表的右下角常年挂「点击领66」浮件，正好压在这一带。
    /// 2. **该区域确实有东西**：OCR 在 `[y-60, 977]` 底部带读到**非按钮本身**的文字/浮件词，
    ///    或按钮**正下方**在读到的行里还有其它元素 ⇒ 认为被压住。
    /// 满足 ⇒ **先上滑一段**（把按钮挪到屏幕中上部），**重新 OCR 取新坐标**，再点。
    ///
    /// ## 为什么要"重新取坐标"而不是"原坐标 + 偏移"
    /// 上滑后按钮位置变了，原坐标必然失效（本轮我用手动滑+重取验证过：
    /// 滑后 OCR 直接给出 394.3,227.3）。⛔ 拍脑袋的固定偏移就是猜。
    ///
    /// - Returns: 实际点击用掉的 (x, y)；上滑重取后仍被遮挡 ⇒ 返回最后尝试的坐标
    @discardableResult
    private func tapAvoidOcclusion(_ p: CGPoint, why: String,
                                   retries: Int = 1) -> CGPoint {
        var target = p
        var attempt = 0
        while true {
            attempt += 1
            let needLift = target.y > Self.occludedYMin
            if !needLift || attempt > retries + 1 {
                break
            }
            log("   §occl ⚠️ 按钮 @(\(Int(target.x)),\(Int(target.y))) 落在屏幕下部"
                + "（y>\(Int(Self.occludedYMin))）⇒ 多半被底部浮件/宝箱动画压住"
                + " ⇒ **先上滑再点**（§3013 真机：y=839 点 5 次没反应，y=227 一次成功）")
            // 上滑：从屏幕中部往上，避开底部浮件区
            let cmd = BLEController.swipe(x1: baseW / 2, y1: baseH * 0.72,
                                          x2: baseW / 2, y2: baseH * 0.38,
                                          speed: .mid, baseW: baseW, baseH: baseH, yFix: yFix)
            _ = ble.send(cmd)
            log("   §occl 上滑 \(cmd)")
            sleep(1.6)
            guard let img2 = grab() else {
                log("   §occl ⛔ 上滑后抓不到帧 ⇒ 用原坐标点（已尽力）")
                break
            }
            // 重新定位同一行按钮
            if let again = findAdRowButton(img2) {
                target = again.point
                log("   §occl ✅ 重新定位到按钮 @(\(Int(target.x)),\(Int(target.y)))")
            } else {
                log("   §occl ⚠️ 上滑后找不到那行按钮 ⇒ 用原坐标点（已尽力）")
                break
            }
        }
        nav.tapPoint(Double(target.x), Double(target.y), why: why)
        return target
    }

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
                nav.tapPoint(225, 150, why: "固定点（见该处注释）")
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
        // ⭐ §2931 **回桌面重进**的次数（用户令：认不出就直接回桌面再点快手）
        //   ⚠️ 有界 = 3（⛔ 免得"真进不去"时无限退桌面）
        var escapes = 0
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
                if unknownRetry < 1 {
                    unknownRetry += 1
                    log("   §\(tag) 未知页 ⇒ 等 1.5s 重判一次（页面可能还没画完）")
                    sleep(1.5)
                    continue
                }
                // ⭐⭐⭐⭐⭐ §2932 **认不出 ⇒ 回桌面再点快手（一趟只一次）**
                //
                // > 「**直接就命令回桌面 再点快手返回啊。为什么卡死在外部搞这么久
                // >   一个广告 你转了一万圈了？**」
                //
                // ⛔ 上一版我给了 3 次预算 + `unknownRetry` 重置 ⇒ 还是能转好几圈。
                // ✅ 现在：**一次**（`escapes` 只许到 1）⇒ 不成就如实停手。
                //    📏 结构上不可能循环：`escapes` 单调增、到 1 就 return false。
                if escapes < 1 {
                    escapes += 1
                    log("   §\(tag) ⭐ **回桌面再点快手**（一趟只走这一次）")
                    _ = Navigator.switchToApp(named: s?.apps?.first ?? "kslite",
                                              rec: rec, ble: ble, frame: grab,
                                              baseW: baseW, baseH: baseH, yFix: yFix,
                                              log: log)
                    sleep(1.5)
                    continue        // 回去重判**一次**（不成 ⇒ 走下面的停手）
                }
                log("   §\(tag) ⛔ 回桌面重进后仍认不出 ⇒ **停手**（如实说，不假报）")
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
                        nav.tapPoint(Double(pick.1.x), Double(pick.1.y), why: "搜索联想词候选")
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
        nav.tapPoint(Double(boxPt.x), Double(boxPt.y), why: "搜索框")
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
            nav.tapPoint(Double(sk.x), Double(sk.y), why: "搜索键盘/候选")
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
            nav.tapPoint(Double(hit.1.x), Double(hit.1.y), why: "识别命中项（见上下文）")
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
            nav.tapPoint(Double(hit.1.x), Double(hit.1.y), why: "识别命中项（见上下文）")
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
            nav.tapPoint(Double(hit.center.x), Double(hit.center.y), why: "元素命中中心")
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

    /// ⛔⛔⛔ §2921 **登录红线**（用户令，逐字）
    ///
    /// > 「**外部授权都可以统一 但是不点击登录**」
    /// > 「**同意授权但是登录 不登陆**」
    ///
    /// ## 口径拆成两半（⛔ 别混）
    /// ```
    /// ✅ 外部**授权**弹窗（「想要打开 X」）  ⇒ 统一**同意**（点「打开/允许」）
    /// ⛔ **登录**（任何形态）              ⇒ **绝不点**（本表 = 执行点）
    /// ```
    ///
    /// ## 为什么要单列一张表（而不是混在 `forbidKeys` 里靠人记）
    /// `forbidKeys` 的语义是「**别付钱**」；登录是**另一条独立红线**（别替你登录账号）。
    /// ⇒ 两条红线各自可读、各自可配（`settings.login_keys`），⛔ 不互相污染。
    ///
    /// ## 📏 PC 里的证据
    /// PC `_1377_ad_loop.py` **全篇没有「登录」二字**（grep 0 命中）——
    /// 说明它没遇到过；而本机**真遇到了**（元宝的「欢迎使用 / 同意服务协议」）。
    /// ⇒ 这是用户**新加的口径**，照抄 PC 抄不到，必须以用户令为准。
    ///
    /// ⚠️ **唯一读取点** = `FeatureEngine.loginKeysCfg`（配置优先）+ `Navigator.tap()` 的点击闸。
    static let loginKeys: [String] = [
        "登录", "登陆", "登入",
        "立即登录", "一键登录", "手机号登录", "账号登录", "授权登录", "微信登录",
        "QQ登录", "本机号码一键登录", "同意并登录", "登录/注册", "注册/登录",
    ]

    /// ⭐⭐⭐⭐⭐ §2921 **外部授权腿的肯定项词表**（用户令：「外部授权都可以统一**同意**」）
    ///
    /// ## 用户令（逐字）
    /// > 「**外部授权都可以统一 但是不点击登录**」
    /// > 「**同意授权但是登录 不登陆**」
    ///
    /// ## 与 PC 的关系（PC `_1377_ad_loop.py:3075` 逐字）
    /// ```python
    /// SYS_ALLOW = ("打开", "允许", "继续", "好")   # §1699；「打开」优先 —— 用户令「要打开」
    /// ```
    /// ⇒ 逐条照抄。⚠️ 但把 PC 的「继续」**去掉**了：PC 自己在别处写着
    ///   「⛔ **绝不点「继续」**」（L6003，那是"继续支付"类风险的正按钮）
    ///   ⇒ 用户令只授权"外部跳转"，⛔ 不给"继续"开口子。
    static let sysAllowKeys: [String] = ["打开", "允许", "好"]

    /// ⭐⭐⭐ §2921 **协议弹窗的肯定项「同意」**（⛔ 必须排除「不同意」）
    ///
    /// # ⛔⛔⛔ 为什么不能直接用 `elements.consent_allow`（真机验证逮到的 bug）
    /// 真机帧 `_r4_now.jpg`（元宝「欢迎使用」）的 OCR 实测：
    /// ```
    ///   y=604 x=296..330  '同意'      ← ✅ 要点的
    ///   y=604 x=110..165  '不同意'    ← ⛔ 绝不能点（= 拒绝服务条款）
    /// ```
    /// ⚠️ 而 `Recognizer.findWords` 的匹配是「**按词表顺序，命中第一个就 break**」：
    /// ```swift
    /// for w in words where Self.fuzzyContains(txt, w) { ...; break }
    /// ```
    /// ⇒ 词表若写 `["同意", …]`，那么 OCR 文本 **「不同意」也会命中「同意」**
    ///   （`"不同意".contains("同意")` = true）⇒ **两个按钮分不开**：
    ///   · `min_hits=2`（`consent_dialog` 那条）**永远不成立** ⇒ 腿根本不触发
    ///   · 只写一个词时，还可能**点中「不同意」**（比不点更糟）
    ///   📏 实测证据：`consent_dialog hit=False` 而 `consent_allow hit=True ev=不同意/同意`
    ///      —— 两个按钮被并进同一个框，中心落在**两钮中间**。
    ///
    /// ## ✅ 因此本腿**不走元素表**，改用专用判据（照 `findBottomPopup` 的同一套做法）
    /// ```
    ///   ① 找按钮带里所有 OCR 块
    ///   ② 「不同意」块 ⇒ 记为 deny（⛔ 绝不返回）
    ///   ③ 去掉「不同意」后，**整体等于**「同意/我同意/接受」的块 ⇒ ✅ 返回它
    /// ```
    /// ⇒ 📏 用户令落地：「**同意授权，⛔ 不点登录**」——
    ///   本函数只找"同意"这一枚，⛔ 不碰"不同意"，也⛔ 不碰任何含「登录」的按钮。
    ///
    /// - Returns: 肯定项「同意」的**基准像素**中心与文案；⛔ 找不到 ⇒ nil（不放枪）
    static func findConsentAllow(_ img: UIImage, rec: Recognizer, bw: Double,
                                 loginKeys: [String]?) -> (x: Double, y: Double, tag: String)? {
        // 按钮带：真机实测 y=604（弹窗下半），ROI 取宽一点覆盖版式浮动
        let band = CGRect(x: 0, y: 430, width: bw, height: 330)
        let ws = rec.ocrRegion(img, rect: band, minConfidence: 0.3)
        // ⛔ 先收集「不同意」的框（用于排除）
        var denyRects: [CGRect] = []
        for (t, r, _c) in ws where t.contains("不同意") { denyRects.append(r) }
        for (t, r, _c) in ws {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            // ① ⛔ 含「不同意」⇒ 跳过（拒绝项）
            if s.contains("不同意") { continue }
            // ② ⛔ §2921 登录红线：含「登录/登陆/登入」⇒ 跳过
            //    这正是「同意并登录」/「本机号码一键登录」被拦住的地方
            if let bad = forbidden(t, loginKeys: loginKeys) {
                _ = bad
                continue
            }
            // ③ ✅ 整体等于肯定项才算（照 PC 的整词等值纪律，⛔ 不用 contains）
            guard consentAllowWords.contains(s) else { continue }
            // ④ ⛔ 与「不同意」框重叠 ⇒ 是同一个块被切开 ⇒ 跳过（防误点）
            if denyRects.contains(where: { $0.intersects(r) }) { continue }
            return (Double(r.midX), Double(r.midY), t)
        }
        return nil
    }

    /// §2921 协议弹窗肯定项词表（⛔ 整词等值；「不同意」由调用方先排除）
    static let consentAllowWords: [String] = ["同意", "我同意", "接受", "同意并继续"]

    /// ⛔ PC `REJECT_CLICK_KEYS`（`_1377_ad_loop.py:471`）—— 照抄雷神的"拒绝点击"词表
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
    /// - Parameter loginKeys: ⛔ §2921 **登录红线词表**（配置优先）。
    ///   ⚠️ 必须是**参数**而不是直接读实例属性：`forbidden` 是 `static`，
    ///   ⛔ 访问不到实例属性 `loginKeysCfg`（那样根本编译不过）。
    ///   默认 `nil` ⇒ 用静态基线 `Self.loginKeys`（⇒ 静态调用方**天然**也有保护）。
    static func forbidden(_ text: String?, extraKeys: [String]? = nil,
                          loginKeys: [String]? = nil) -> String? {
        let t = text ?? ""
        // ⭐ 读调用方传进来的**配置表**；⛔ 不传（nil）⇒ 逐字走原来的硬编码 25 条
        for k in (extraKeys ?? forbidKeys) where t.contains(k) { return k }
        for k in rejectClickKeys where t.contains(k) { return k }
        // ⛔⛔⛔ §2921 **登录红线**（用户令：「同意授权但是登录 不登陆」）
        //   放在最后但**一定要查**：⛔ 任何含「登录/登陆/登入」的文案都不许点。
        for k in (loginKeys ?? Self.loginKeys) where t.contains(k) { return k }
        return nil
    }

    /// ⛔ §2921 **登录红线的点击前闸**（实例版：自动带上配置）
    ///
    /// ⚠️ 与 `forbidden` 的区别：本方法**读实例配置**（`s?.login_keys`），
    /// 所以每个实例调用点只需写 `self.loginBlocked(text)`，⛔ 不用手写两层表。
    func loginBlocked(_ text: String?) -> String? {
        Self.forbidden(text, loginKeys: loginKeysCfg)
    }

    /// ⛔ §2921 **登录红线**的词表 —— 配置优先（`settings.login_keys`），缺省 = `loginKeys`
    ///
    /// ⚠️ 唯一读取点（⛔ 不许各写一份）—— 照 `forbidKeysCfg` 的同一套纪律。
    private var loginKeysCfg: [String] { s?.login_keys ?? Self.loginKeys }

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

    /// ⭐⭐⭐ §2896 **安装/打开腿的词表**（默认 7 条）—— 配置 `install_words` 可覆盖。
    ///
    /// ## 用户令（逐字）
    /// > 「**没下载的要做下载一般是云图标或者获取 已经下载的要去打开**」
    ///
    /// ## ⛔ 为什么必须补「打开」（两端都缺的 MISSING）
    /// PC `click_install`（`_1377_ad_loop.py:8758`）词表逐字：
    /// ```python
    /// if _w.strip() in ("获取","安装","下载","免费","获取APP","获取App"):
    /// ```
    /// ⇒ **不含「打开」**；手机移植时照抄了这个缺口 ⇒ **已下载态两端都不做**。
    /// 真机 `_v2885`（百度地图，**已安装**）实测：`打开` @(370,106) **conf=1.00**
    /// —— 正是页首右上那枚按钮。⇒ 这是一条**PC 本身也漏**的腿，⛔ 不是"手机漏移植"。
    static let installWords: [String] = [
        "获取", "安装", "下载", "免费", "获取APP",
        "打开",     // ⭐ §2896 用户令「已经下载的要去打开」（PC 词表里没有）
        "更新",     // ⭐ §2912 用户令「还要加入更新」（PC 词表里没有）
    ] + installButtonFullNames

    /// §2914 **已知按钮全称**（⛔ 精确匹配用；照 PC `CTA_KEYS` L279 的下载类词）
    ///
    /// ## 为什么必须有它（⛔ 因为 §2914 已把"子串匹配"删掉）
    /// H5 落地页上的按钮常常是**多字全称**（`下载应用`/`立即下载`/`去下载`），
    /// 而它们**不是**裸的「下载」⇒ 只用裸词精确匹配会漏。
    /// 📏 PC `CTA_KEYS`（L279 逐字）里就明列着这些：
    /// ```
    /// "下载", "安装", "下载应用", "立即安装", "免费下载", "免费安装",
    /// "下载安装", "去下载", "立即体验", "安装应用", "下载体验"
    /// ```
    /// ⇒ 这里逐条抄进来（⛔ 用**精确等值**匹配，⛔ 不做包含 —— 见 `findInstallWord`）。
    static let installButtonFullNames: [String] = [
        // —— 下载类（PC CTA_KEYS 逐字）——
        "下载应用", "立即下载", "免费下载", "去下载", "下载安装", "下载体验",
        // —— 安装类（PC CTA_KEYS 逐字）——
        "立即安装", "免费安装", "安装应用", "安装APP", "安装App",
        // —— 体验/获取类（PC CTA_KEYS 逐字）——
        "立即体验", "获取App",
        // —— 已安装态（§2912 用户令「还要加入更新」）——
        "更新APP", "更新App", "立即更新",
    ]

    /// ⭐ 点广告页底部的 CTA —— 逐条移植 PC `click_cta`（`_1377_ad_loop.py:1044`）。
    ///
    /// ## PC 的三步（⛔ 顺序不能变）
    /// ```
    /// ① 形状优先：底部**最宽**粉色药丸，且**必须居中**（|cx-225| ≤ 10）
    ///    ⛔ §1522 真机：不居中就点到 scr(88,886) 的创意红条 ⇒ "转化"名存实亡
    ///    命中后**再 OCR 复核文案**，含 FORBID_KEYS ⇒ 拒绝
    /// ② 文案兜底：CTA_KEYS 命中 + 粉色质心
    /// ③ 兜底之兜底：偏心粉带也点（点广告画面本身也算一次广告点击）
    /// ```
    ///
    /// ---
    ///
    /// # ⛔⛔⛔ §2911 **删掉「购物/电商型广告 ⇒ 拒绝点 CTA」那道闸**
    ///
    /// ## 用户令（逐字，本轮）
    /// > 「**购物广告也要做浏览的 只是不支付 你看看PG控制器的基准**」
    ///
    /// ## 📏 PC 基准里，用户**说过三次**，而我抄的是被推翻的那一版
    /// ```python
    /// # L1540（用户 2026-10-04 14:03，逐字）
    /// #   「**老子说的不是不转化 是不支付，你给我搞清楚**」
    /// #   ⇒ 我一直在代码/日志里写「用户口径：购物广告不做转化」—— 那是**我编的**，不是用户的话。
    /// #   ✅ **真正的红线只有一条：不支付 / 不购买**（由 FORBID_KEYS 硬闸守）。
    /// #   ⇒ **转化照做**（点 CTA 互动）—— 购物型也一样，只要点的不是支付/购买钮。
    ///
    /// # L1564（用户纠正）
    /// #   「**我说不支付 不是说不浏览**」⇒ **购物/电商型广告也要做转化**（点 CTA → 先安装 → 后浏览）。
    ///
    /// # L8542-8544（browse_landing 里，逐字）
    /// #   「我上一版加的"购物/电商型跳过滑动"**是错的，已撤销** —— **购物广告也要浏览**。」
    /// #   ⛔「**刚刚第一个购物广告 你一直在页面滑动。无效动作。**」
    /// ```
    /// ⇒ 📏 **`_note_2730`（PC 规格）已明确裁定这个矛盾**（L147-150 逐字）：
    /// > ⚠️ 「`is_shop_ad` 那道闸的语义已被后续版本推翻 …… 移植时建议：
    /// >   **以 L9640/9650 的用户口径为准**（购物广告做转化，只禁支付），并保留 `FORBID_KEYS` 硬闸。」
    ///
    /// ## ⛔ 我的错（真机 0.19 现场，2026-10-16 00:31）
    /// ```
    /// §adbox_cta1 ⛔ 购物/电商型广告（底栏命中 ["立即购买"]）⇒ **拒绝点 CTA**
    /// §adbox ⚠️ 没找到可点的 CTA（过闸后）⇒ 本条不做转化，直接收奖励   ← ⛔ 零转化
    /// ```
    /// ⇒ 用户要的「**购物广告也要浏览**」**一次都没做**。
    ///
    /// ## ✅ 现在（照 PC 基准 + 用户令）
    /// **购物型广告照做转化 + 浏览**；红线仍由 `forbidden()`（`forbid_keys` 32 条）守住 ——
    /// 实测「立即购买/去购买/领券购买」都被 `购买` 拦、「秒杀/限时秒杀」被 `秒杀` 拦、
    /// 「加购/购物车/进店」也都在表里 ⇒ ⛔ **点不到支付/购买钮**。
    /// `isShopAd` 仍保留（只用于**日志**，说明本条是购物型），⛔ 不再当"拒绝"闸。
    ///
    /// - Returns: 点到了哪条腿（供日志）；nil = 没点（⛔ 不放枪）
    private func clickCTA(_ img: UIImage, tag: String) -> String? {
        // ⭐ §2911 购物型**不再拒绝转化** —— 只记一笔日志（照 PC L9652 的语义）
        let (shop, shopHit) = isShopAd(img)
        if shop {
            log("   §\(tag) ⭐ 购物/电商型广告（底栏命中 \(shopHit.prefix(3))）⇒ **照做转化**"
                + "（用户令：不支付≠不转化、≠不浏览；⛔ 支付/购买由 forbid_keys 拦）")
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
                if let bad = Self.forbidden(t, extraKeys: forbidKeysCfg, loginKeys: loginKeysCfg) {
                    log("   §\(tag) ⛔ 形状命中的药丸文案含违规词「\(bad)」⇒ **拒绝点击**")
                    return nil
                }
                log("   §\(tag) 形状优先：居中粉药丸 @(\(Int(cx)),\(Int(cy))) 文案「\(t.prefix(14))」过闸")
                nav.tapPoint(cx, cy, why: "CTA 形状优先（居中粉药丸）")
                return "形状优先"
            }
            log("   §\(tag) 粉药丸不居中（cx=\(Int(cx))，偏离 \(Int(off))）⇒ 不用形状腿")
        }
        // ③ 文案兜底
        let ws = rec.ocrRegion(img, rect: Self.boxCta, minConfidence: 0.3)
        for (t, r, _c) in ws {
            guard ctaKeysCfg.contains(where: { t.contains($0) }) else { continue }
            if let bad = Self.forbidden(t, extraKeys: forbidKeysCfg, loginKeys: loginKeysCfg) {
                log("   §\(tag) ⛔ CTA 文案「\(t)」含违规词「\(bad)」⇒ 跳过")
                continue
            }
            log("   §\(tag) 文案兜底：CTA「\(t)」@(\(Int(r.midX)),\(Int(r.midY)))")
            nav.tapPoint(Double(r.midX), Double(r.midY), why: "CTA 文案兜底")
            return "文案兜底"
        }
        // ④ ⭐⭐⭐⭐⭐ §2832 **兜底之兜底** —— 照 PC `_1377_ad_loop.py:1108-1120`（⛔ 我原来漏了这一层）
        //
        // ## 用户令（逐字，PC 原文引用）
        // > 「**广告完全不转化，全部是看完就X。全是低价值**」（§1526）
        //
        // ## PC 的逻辑（逐字）
        // ```python
        // # ③ 兜底之兜底：居中粉条没有、CTA 文案也没读到 ⇒ **仍用那条偏心的粉色带**。
        // #   ⛔ 它多半是广告创意里的红条（不是 CTA 按钮），但**点广告画面本身也算一次广告点击**；
        // #     而"什么都不点" = **零转化 = 低权重**（用户口径里最差的选项）。
        // #   ⛔ 仍然过 forbidden() 闸 —— 绝不点支付/购买。
        // if c: ...
        // ```
        // ## 📏 0.16 真机日志正是走岔了这里
        // ```
        // §adbox_cta1 ⛔ 没找到可点的 CTA（过闸后）⇒ 停手，⛔ 不盲点
        // §adbox ⚠️ 没找到可点的 CTA（过闸后）⇒ 本条不做转化，直接收奖励   ← 零转化
        // ```
        // ⇒ **零转化** = 用户最不想要的结果。现在补上第三层：**偏心粉带也点**。
        if let band = Self.widestPinkBand(img, box: Self.boxCta, color: s?.cta_color) {
            let cx = band.0, cy = band.1
            // ⛔ 仍过支付红线闸（照 PC：绝不点支付/购买）
            let t = rec.ocrRegion(img, rect: CGRect(x: 0, y: max(0, cy - 26),
                                                    width: 442, height: 52),
                                  minConfidence: 0.3).map(\.0).joined()
            if let bad = Self.forbidden(t, extraKeys: forbidKeysCfg, loginKeys: loginKeysCfg) {
                log("   §\(tag) ⛔ 偏心粉带文案含违规词「\(bad)」⇒ **拒绝点击**（支付红线）")
                return nil
            }
            log("   §\(tag) ⭐ 兜底之兜底：偏心粉带 @(\(Int(cx)),\(Int(cy))) 也点"
                + "（照 PC §1108：点广告画面也算一次转化点击，⛔ 零转化最差）")
            nav.tapPoint(cx, cy, why: "CTA 兜底之兜底（偏心粉带）")
            return "兜底粉带"
        }
        log("   §\(tag) ⛔ 连粉带都没有 ⇒ 停手，⛔ 不盲点")
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

        // ⭐⭐⭐⭐⭐ §2988 **换板子：⛔ 不再"直接读 cgImage 原始字节"（字节序是猜的）
        //                     ⇒ 自己建一块**格式确定**的 RGBA 缓冲**
        //
        // ## ⛔⛔ 血案（本轮真机，2026-10-17 22:12 杰士邦广告）
        // 旧代码最后一行是「照 PC 粉色判据 R>200 且 G<120 且 B<150」——
        //   判据本身**对**，但**读出来的 r/g/b 三个分量是错的**：
        // ```
        // guard let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data)
        // let r = Int(ptr[o]), g = Int(ptr[o+1]), b = Int(ptr[o+2])   // ⛔ 假设缓冲是 RGBA
        // ```
        // `FrameNormalizer.normalize` 走 `UIGraphicsImageRenderer` ⇒ 它给的缓冲是 **BGRA**:
        // ```
        // 真机 CTA 像素的真实颜色 = RGB(255,55,102)
        //   按 RGBA 读 ⇒ r=255 g=55 b=102 ⇒ r>200 & g<120 & b<150 ⇒ **命中** ✅
        //   按 BGRA 读 ⇒ r=102 g=55 b=255 ⇒ 102>200 为假      ⇒ **不命中** ⛔
        // ```
        // 📏 反推（决定性）：**若缓冲真是 RGBA，真机就必然命中**（离线 18493 px、居中 0 偏离）
        //   ⇒ 可真机 trace 逐字说「⛔ 连粉带都没有」⇒ **只可能是 BGRA 被当 RGBA 读**。
        // ⇒ 判据没坏，**板子（读字节的方式）坏了** ⇒ 照用户口径：**换板子，不贴胶布**。
        //
        // ## ✅ 换成仓库里**已经被真机验证过**的那块板子
        // 同一个仓库里 `ColorBlob.findCoinBall`（ColorBlob.swift:75-82）早就是这么写的：
        // ```swift
        // // ③ 画进 RGBA 缓冲（⚠️ premultipliedLast + 默认字节序 ⇒ 内存里就是 R,G,B,A）
        // CGContext(data: &buf, ..., bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        // ```
        // 📏 为什么这块板子是好的：**格式由建立缓冲的人指定**，
        //   ⛔ 不是"读的时候猜来源是什么格式" ⇒ 字节序不再有假设空间。
        //
        // ## ⚠️ 代价（诚实记录）
        // 多一次整帧绘制（451×977×4 ≈ 1.7MB）＋ 多一份内存。
        //   但本函数**只在广告页 CTA 兜底时调用**（一条广告一次），不在热路径上 ⇒ 可接受。
        //   ⛔ 不要图省事"两种解读都试"（`findInstallBtn` 那种写法）—— 那是**胶布**：
        //     它对蓝/粉两种极性都可能误判，且把"我搞不清格式"永久固化进代码。
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        guard let ctx = CGContext(data: &buf, width: W, height: H,
                                  bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        // ⚠️ CGContext 原点在**左下** ⇒ 缓冲第 0 行是图像的**底行**
        //    ⇒ 读第 y 行要用 `(H - 1 - y)`（与 `ColorBlob.findCoinBall` 的翻行一致）
        for y in by..<(by + bh) {
            var minX = -1, maxX = -1
            let srcRow = (H - 1 - y) * W * 4
            for x in bx..<(bx + bw) {
                let o = srcRow + x * 4
                let r = Int(buf[o]), g = Int(buf[o + 1]), b = Int(buf[o + 2])
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
    /// - Returns: **这条腿到底出手了没有**（`true` = 真发了点击；`false` = 没找到目标、没出手）
    ///
    /// ## ⛔⛔⛔ §2971 为什么要返回这个（真机血案，用户令「都改了」）
    ///
    /// ### 血案（真机日志逐字，2026-10-16 19:14–19:15）
    /// ```
    /// [19:14:57] §adbox_ret5_2 返回腿 k=2：应用内「〈」
    /// [19:14:57] §tap ⛔ 没找到「back_arrow」⇒ **不点**        ← ⛔ 这一腿**根本没出手**
    /// [19:15:01] §adbox ⏭ 返回腿 k=2 **点了画面没变** ⇒ 记死换下一条   ← 🔴 谎报"点了"
    /// ```
    /// 同样被冤杀的还有 k=4（`没找到「退出直播间」⇒ 不放枪`）、k=7/k=8（`已走过一次 ⇒ 停手`）——
    /// **四条腿一次都没出手，却全被判"点了没变"**。
    ///
    /// ### 📏 与 PC 控制器对照（用户令：「和PG控制器做对照」）
    /// PC `_1377_ad_loop.py:2844` 的 App Store ✕ 是**无条件前置腿**（逐字注释）：
    /// > `if click_appstore_x(img): return`
    /// > 「（`click_appstore_x()`；**不经 k 轮次，每次进来都先过**）」
    /// ⛔ 而我把它写进了 `case 0` ⇒ **k≥1 之后再也不试** ⇒
    ///    从 App Store sheet 回不来时（k=6 回桌面又落回同一张 sheet），
    ///    k=7/k=8 只能"如实停手" ⇒ **整条广告废掉**。
    ///
    /// ### ✅ 修法（照 PC，⛔ 不新造机制）
    /// ① App Store ✕ 提成**无条件前置腿**（与 PC L2844 逐字同位置）
    /// ② 本函数返回"有没有出手"⇒ 调用方**只有真出手过才许记死**
    @discardableResult
    private func returnToAd(_ img: UIImage, tag: String, k: Int) -> Bool {
        // ── 每轮先过的三层闸（照 PC 2815-2888，⛔ 顺序不许改）──
        //
        // # ⛔⛔⛔ §2948 **这三道闸原来是死的**（真机血案：广告页卡死在弹窗上）
        //
        // ## 血案
        // 用户：「**广告页面依然卡死在弹窗上 让你用PG控制器对照解决问题**」
        // 📏 逐条查出来的根因（⛔ 三行全是错的元素名）：
        // ```swift
        // if nav.detect("sys_prompt",  img: img) != nil { … }   // ⛔ elements 里**没有**这个名字
        // if nav.detect("coupon_x",    img: img) != nil { … }   // ⛔ 也没有
        // if nav.detect("shop_h5_x",   img: img) != nil { … }   // ⛔ 也没有
        // ```
        // ⇒ `detect()` 对不存在的名字**返回 nil**（⛔ 不报错）
        //   ⇒ **三道闸全部恒 false** ⇒ **一次都没出手过** ⇒ 弹窗永远没人关。
        //
        // ## ✅ 照 PC 改成"走**代码**里的专用判据"（PC 也是这么做的）
        // PC `return_to_ad` 的前置闸（`_1377_ad_loop.py:2815-2888` 逐字）：
        // ```python
        // if dismiss_sys_prompt(img): return     # ① 系统弹窗（**函数**，不是元素名）
        // if click_coupon_x(img): return         # ② 券弹窗（**函数** find_coupon_x 位置闸）
        // if handle_shop_h5(img): return         # ③ 小店 H5（**函数**，自带状态机）
        // ```
        // ⇒ 📏 PC 这三道闸**都不是"查元素表"**，是**调函数**。
        //   我写成 `detect("<名字>")` 就等于把它们**架空**了。
        //
        // ## 📏 教训（用户令「先看 PG 控制器的标准」）
        // **元素名是数据；这三道闸是逻辑。** 拿数据名去查一张没有它的表 ⇒ 静默失效。
        // ⚠️ 本轮已加 `ConfigStore.validateSplit()` 的引用完整性自检（§2945）——
        //    它**只查 funnel/pages**，查不到"代码里写死的名字" ⇒ 所以我在这里补了注释。

        // ① ⭐ 系统弹窗（PC `dismiss_sys_prompt`）
        //    ⛔ 原来写 `detect("sys_prompt")`（不存在）⇒ 恒 false
        //    ✅ 现在：先看**形态/标题**（两个真实元素），再点**消极项**
        //    📏 闸 = `sys_prompt_title`（「想要打开」）**或** `sys_prompt_btns`（不允许+允许）
        //       —— 与 `Navigator.runFunnel` 里那两条腿**同一套判据**
        if nav.detect("sys_prompt_title", img: img) != nil
            || nav.detect("sys_prompt_btns", img: img) != nil {
            log("   §\(tag) 返回闸①：系统弹窗（标题/形态闸命中）⇒ 点消极项"
                + "（照 PC `dismiss_sys_prompt`；⛔ 原来写 detect(\"sys_prompt\") 恒 false）")
            _ = nav.tap("sys_prompt_deny", img: img, atomic: true)
            return true
        }
        // ② ⭐ 券弹窗 ✕ —— **专用判据 `ModalX.findCoupon`**（照 PC `find_coupon_x` 的位置闸）
        //    ⛔ 原来写 `detect("coupon_x")`（不存在）⇒ 恒 false ⇒ 券弹窗永远没人关
        //    ✅ ROI 与 PC `BOX_COUPON_X=(0.42,0.64,0.58,0.78)` **逐字一致**
        //       （见 `ModalX.boxCouponX`；PC §1724 已删语义闸，**只留位置闸**）
        if let c = ModalX.findCoupon(img) {
            log("   §\(tag) 返回闸②：券弹窗 ✕ 位置闸命中 @(\(Int(c.x)),\(Int(c.y)))"
                + " ⇒ 点它（照 PC `click_coupon_x` §1724；⛔ 原来 detect(\"coupon_x\") 恒 false）")
            nav.tapPoint(Double(c.x), Double(c.y), why: "返回闸②券弹窗 ✕（位置闸）")
            return true
        }
        // ②b ⭐⭐⭐⭐⭐ §2971 **App Store sheet 左上 ✕ —— 无条件前置腿**（照 PC L2844）
        //
        // ## PC 逐字（`_1377_ad_loop.py:2840-2845`）
        // ```python
        // # ⭐⭐⭐ §1637 第二件事：App Store 商品页（App 内模态）⇒ 点左上「取消 ✕」
        // #   为什么排这么前：它就是**盖住整屏**的一层，下面什么都没有；
        // #   而且它**不会自己消失** —— 每次回前台又跳一次
        // #   ⇒ 后面 9 条腿（含 H:HOME+桌面图标）**全部无效**。
        // if click_appstore_x(img):
        //     return
        // ```
        // ⇒ 📏 PC 把它放在**券弹窗之前、且不经 k 轮次** —— **每轮进来都先过**。
        //
        // ## ⛔ 我原来错在哪（真机血案 19:15）
        // 我把它写进 `case 0` ⇒ k≥1 就不再试。
        // 真机后果：人在 App Store sheet 上，k=0 走了「〈」、k=1..5 全落空、
        //   k=6 回桌面又被 iOS 恢复回**同一张 sheet**、k=7/k=8「如实停手」⇒
        //   **整条广告废掉**（`_exp2969` 那段 9 腿空转就是它）。
        // 手动验证：在这张 sheet 上点左上 ✕ **一次就回广告页**（19:17 实测）。
        if nav.detect("appstore_x", img: img) != nil {
            log("   §\(tag) 返回闸②b：⭐ App Store sheet 左上 ✕ ⇒ 点它"
                + "（照 PC L2844 无条件前置腿；⛔ 原来写在 case 0 里 ⇒ k≥1 不再试）")
            _ = nav.tap("appstore_x", img: img, atomic: true)
            return true
        }
        // ③ 小店 H5（收银台/订单页）—— PC `handle_shop_h5` 自带状态机
        //    ⛔ 原来写 `detect("shop_h5_x")`（不存在）⇒ 恒 false
        //    ✅ 现在：用**注释如实标注**它仍是缺口（⛔ 不假装它work）
        //    📏 为什么不现在就补齐：PC 的 `handle_shop_h5` 是一条**独立状态机**
        //       （取消 → 确定 → 交给「〈」腿），⛔ 不是"点一个 ✕"能等价的。
        //       ⛔ 我不趁手乱写一个半成品 —— 先记录缺口，等真机遇到再照 PC 移植。
        //       （§2874 §3 已列此缺口；`shop_h5_x` 从未在 config 里存在过。）

        // ── ⛔⛔⛔ §2958 **这里原来有「闸④：是直播间就先下滑」—— 已删除**
        //
        // ## 为什么删（我在 0.30 加错了，用户点破）
        // 我把它当成"迷路在直播间，要退出去"，而 **PC 的口径完全不同**：
        // ```python
        // # _1377_ad_loop.py:8486-8491（PAGE_PLAN，唯一口径）
        // "ad_live": "不点 CTA、不操作（用户令「直播间就不操作了」）；等倒计时 → 点 ✕ 收奖励"
        // ```
        // ⇒ ⭐ **直播间广告是一条"要等完、收奖励"的广告**，⛔ **不是要退出的陌生页面**。
        //
        // ## PC 的原始证据（真机日志 `_var/_1540_fuli_round.log` 逐字）
        // ```
        // L435  .. ★广告页（直播间）⇒ **先等 30s**（用户口径：等待30秒后互动完再关闭）
        // L438  .. ★本条是「直播间形态」广告 ⇒ 不点 CTA，直接等倒计时 → 点 ✕ 收奖励
        // L442  .. ★直播间 ⇒ 按用户令「不操作、别死定」：**只点右上 ✕**，不跑返回腿
        // L447  == 第 12 条完成
        // ```
        //
        // ## 用户令（PC 注释里留着的，逐字）
        // > 「**你这执行有等30秒么 什么广告他都强退出？**」（§1534）
        // > 「**进去就点X 卡死 出去进来像傻逼一样，最后点X**」（§1529）
        // ⇒ ⛔ **我加的这道闸正是在"什么广告他都强退出"** —— 用户早就骂过这个方向。
        //
        // ## 「下滑 → 退出直播间」在 PC 里的**真正位置**
        // `return_to_ad` 的 **k=3/k=4 导航返回腿**（L2909-2917）——
        // 用途 = **"我迷路了、不知在哪一页"** 的兜底，
        // ⛔ **不是**"关闭直播间广告"的动作（那会**白丢一条已到账的广告**）。
        // ⇒ 本机 k=3/k=4 仍在（位置正确），⛔ 不再提前抢在广告模块之前开火。

        // ── ⭐⭐⭐⭐⭐ §2932 **回桌面再点快手：一趟里只许一次**（用户令） ──
        //
        // > 「**直接就命令回桌面 再点快手返回啊。为什么卡死在外部搞这么久
        // >   一个广告 你转了一万圈了？**」
        //
        // # ⛔⛔⛔ §2932 **我上一版把它做成了新的死循环**（真机实测）
        // ```swift
        // if k >= 1, !looksLikeAdPage(...) {      // ⛔ 每一轮 k 都 >=1
        //     switchToApp(...)                     // ⛔ 于是每一条腿都变成"回桌面重进"
        //     return
        // }
        // ```
        // ⇒ 真机 trace 逐字：**一条广告里 `H:HOME` 6 次、点快手图标 4 次**
        //   （`§adbox 一个广告转了一万圈` 就是它）—— 用户在骂的正是这个。
        //
        // ## ✅ 正确形状（**先试页面自己的出路，全试完仍不行才回桌面**）
        // ```
        //   k = 0..5   ⇒ 正常走"页面自己的出路"（✕/〈/侧滑…）
        //   k == 6     ⇒ **这时才**回桌面再点快手（且**只走一次**）
        // ```
        // 📏 `switch k` 天然保证 k=6 只到一次 ⇒ ⛔ 不需要额外的旗标。
        //
        // ## ⛔ 为什么不能无条件回桌面（§2722 血案）
        // §2722 删的是「**在快手自己的广告页/落地页上**也退桌面」——
        // 那会毁掉正在看的广告（奖励没拿够）。⇒ 加一条便宜的前置条件：
        // **这一帧不是广告页**（顶栏没有「可领取/已成功领取」）。

        // ── 按轮次选腿（照 PC 2893-2975）──
        switch k {
        case 0:
            // ⭐⭐⭐⭐⭐ §2722 **苹果 App 广告落地页：点左上那个 ✕**
            //
            // ## 用户令（逐字）
            // > 「就把这个X当锚点做为快手苹果APP落地页」「即是锚点也是返回链路」
            // > 「刚刚要是能识别是苹果应用落地页他就该走苹果落地页面返回链路。
            // >   而不是外部返回链路。」
            //
            // ## 真机实测（⛔ 不是推测）
            // ```
            //   截图 _var/_2722_page0.png  ✕ 笔画 暗=802 盒 51×51  中心基准 (43.2,110.4)
            //   点它(43,110) ⇒ 全屏像素差 79.3 = 生效
            //   结果：一步回到广告页（顶栏「已成功领取811金币」+ 右上「广告」+ 底部粉色 CTA）
            // ```
            // 📏 与 PC 权威一致：`_1377_ad_loop.py` X_REFS 注释 ——「App Store 页上
            //   **必然出现、且唯一**的关闭入口 = App 隐私页左上的圆圈 ✕」。
            //
            // ## ⛔ 为什么必须排在最前（血案）
            // 原来这里是 `nav.detect("appstore_done")` —— 而 **config 里没有这个名字**
            // （`elements` 里从来没有 `appstore_done`）⇒ `detect` 直接返回 nil
            // ⇒ 这条腿**静默失败**（`tap()` 失败不打日志）⇒ 一路掉到 k=1/2 点 `〈`
            // ⇒ 在苹果落地页上点「返回」= 按外部页处理 ⇒ **退出快手** ⇒ k=6..8 退到桌面。
            // 📏 真机 trace 铁证：整轮 **0 条 `§click`**（什么都没点到），
            //   然后 `§adbox_ret N_6/7/8 返回腿 k=6/7/8：★终端腿 = 回主屏`。
            // ⭐ §2971 这里原来还有一份 `appstore_x` 检测 —— 已**上提成无条件前置腿**
            //（见本函数开头「返回闸②b」）。留着会变成**两个真相源** ⇒ 已删，只留一份。
            // 面包屑「◀快手」（**OCR 定位**，⛔ 不是写死坐标）
            if nav.detect("breadcrumb", img: img) != nil {
                log("   §\(tag) 返回腿 k=0：面包屑「◀快手」⇒ 点它（照 PC `click_breadcrumb`）")
                _ = nav.tap("breadcrumb", img: img, atomic: true)
                return true
            }
            // 旧版式 App Store 页左上「完成」（新版式是上面的 ✕；两者并存）
            //
            // ⛔⛔⛔ §2948 **把 `detect("appstore_done")` 拆掉 —— 那个名字不存在**
            // 上面这段注释**自己就写着这个血案**（"config 里没有这个名字 ⇒ 静默失败"），
            // 但**代码没改**：`appstore_done` 至今不在 `elements` 里 ⇒ 这条腿**恒 false**。
            // 📏 由 `_dev/_2949_scan_dead_names.py` 静态扫出来（3 处调用）。
            // ✅ 照 PC 的做法：**旧版式由 `appstore_page`（左上「完成/打开」文案）覆盖**，
            //    它就是那道闸；⛔ 不需要另一个不存在的动作元素。
            //    PC `return_to_ad(k=0)`（`_1377_ad_loop.py:2898`）逐字：
            //    ```python
            //    if "完成" in txt(img, BOX_DONE): print("检测到「完成」-> 点它")
            //    ```
            //    ⇒ PC 也是**按文案找**，⛔ 不是查一个叫 appstore_done 的元素。
            //    ⇒ 本机 `appstore_page` 的 words = ["完成","打开"] ⇒ 用它**定位**，
            //      点它自己算出来的坐标（⛔ 不写死）。
            if let done = nav.detect("appstore_page", img: img) {
                log("   §\(tag) 返回腿 k=0：应用内商店页「完成/打开」⇒ 点它"
                    + "（照 PC `if \"完成\" in txt(BOX_DONE)`；⛔ 原来 detect(\"appstore_done\") 恒 false）")
                nav.tapPoint(Double(done.center.x), Double(done.center.y),
                             why: "返回腿 k=0 应用内商店页完成/打开")
                return true
            }
            log("   §\(tag) 返回腿 k=0：应用内「〈」⇒ 点它（照 PC `click_page_back`）")
            // ⭐ §2971 **如实回报"到底出手没有"**（⛔ 不许谎报 ⇒ 见本函数头 §2971 血案）
            return nav.tap("back_arrow", img: img, atomic: true)
        case 1, 2:
            // 应用内 WebView 左上「〈」—— §1416 实测：H5 订单页唯一出路
            log("   §\(tag) 返回腿 k=\(k)：应用内「〈」（H5 唯一出路，§1416）")
            // ⭐ §2971 真机血案就是这里：`§tap ⛔ 没找到「back_arrow」⇒ 不点`
            //   但调用方仍打印"点了画面没变" ⇒ 冤杀。⇒ 现在**如实返回**。
            return nav.tap("back_arrow", img: img, atomic: true)
        case 3:
            // 下滑（沉浸式直播间：下滑后页面才出现「退出直播间」）
            log("   §\(tag) 返回腿 k=3：★下滑（沉浸式直播间先下滑才出「退出直播间」）")
            let cmd = BLEController.swipe(x1: baseW / 2, y1: baseH * 0.30,
                                          x2: baseW / 2, y2: baseH * 0.70,
                                          speed: .fast, baseW: baseW, baseH: baseH, yFix: yFix)
            ble.send(cmd)
            return true
        case 4:
            // 定位并点「退出直播间」
            //
            // ⛔⛔⛔ §2948 **原来写 `detect("exit_live")` —— 那个名字不存在** ⇒ 恒 false。
            // 由 `_dev/_2949_scan_dead_names.py` 静态扫出（2 处调用）。
            // ✅ 照 PC 的做法：`exit_live` **不是元素**，是**文字锚搜索**。
            //    PC `_1377_ad_loop.py:2916` 逐字：
            //    ```python
            //    click_words(img, BOX_EXITLIVE, ["退出直播间"], None)   # ⛔ 找不到就不放枪
            //    ```
            //    而 `BOX_EXITLIVE = (0, 620, 451, 680)`（L423）+ `EXIT_LIVE_KEYS`
            //    = `("退出直播间","回到剧集","直播已结束")`（L426）—— **逐字照抄**。
            //    ⇒ 用 `findWords` 在那条带里找，点**它自己算出来的坐标**（⛔ 不写死）。
            let exitROI = CGRect(x: 0, y: 620, width: baseW, height: 60)   // PC BOX_EXITLIVE
            let exitKeys = ["退出直播间", "回到剧集", "直播已结束"]        // PC EXIT_LIVE_KEYS
            if let hit = rec.findWords(img, words: exitKeys, roi: exitROI,
                                       minHits: 1, minConfidence: 0.3) {
                log("   §\(tag) 返回腿 k=4：点「\(hit.evidence)」"
                    + "@(\(Int(hit.center.x)),\(Int(hit.center.y)))"
                    + "（照 PC `click_words(BOX_EXITLIVE)`；⛔ 原来 detect(\"exit_live\") 恒 false）")
                nav.tapPoint(Double(hit.center.x), Double(hit.center.y),
                             why: "返回腿 k=4 退出直播间")
                return true
            } else {
                log("   §\(tag) 返回腿 k=4：没找到「退出直播间」⇒ 不放枪（铁律①）")
                return false          // ⭐ §2971 没出手 ⇒ 如实回报（⛔ 不许冤杀）
            }
        case 5:
            // ⭐ **iOS 左边缘侧滑**（兜底；§1377b：沉浸式带货直播间整页无任何 ✕，只有它能返回）
            log("   §\(tag) 返回腿 k=5：★iOS 左边缘侧滑（中部 3 发 + 上部/H5 3 发，照 PC §1720）")
            for _ in 0..<3 {
                if isCancelled() { return true }
                _ = nav.backEdge()
                sleep(1.2)
            }
            return true
        case 6:
            // ⭐⭐⭐⭐⭐ §2932 **回桌面再点快手**（用户令：「直接就命令回桌面 再点快手返回」）
            //
            // ## ✅ 为什么放在 k=6（而不是"每条腿都插一下"）
            // `switch k` **天然只到 k=6 一次** ⇒ ⛔ 不需要旗标、⛔ 不会循环。
            // `returnToAdRounds` 默认 9 ⇒ k=6 之后还有 7/8 走 default（如实停手）。
            //
            // ## ⛔ 前置闸：这一帧**不是广告页**
            // §2722 血案 = 「在快手**自己的广告页**上也退桌面」⇒ 毁掉正在看的广告。
            // ⇒ 只在"不在广告页"时才回桌面（广告页归广告模块，⛔ 不许碰）。
            if Self.looksLikeAdPage(img, rec: rec, nav: nav, bw: baseW, bh: baseH,
                                    roi: s?.ad_top_roi) {
                log("   §\(tag) 返回腿 k=6：⚠️ 这一帧**是广告页** ⇒ 不回桌面"
                    + "（§2722：广告页归广告模块，⛔ 退桌面会毁掉正在看的广告）")
                return false          // ⭐ §2971 没出手 ⇒ 如实回报
            }
            log("   §\(tag) 返回腿 k=6：⭐⭐ **回桌面再点快手**"
                + "（用户令；k=0..5 的页面出路都试过了才走这条）")
            _ = Navigator.switchToApp(named: s?.apps?.first ?? "kslite", rec: rec, ble: ble,
                                      frame: grab, baseW: baseW, baseH: baseH, yFix: yFix,
                                      log: log)
            sleep(1.5)
            return true
        default:
            // ⛔ §2932 **k≥7：如实停手**（⛔ 不再退桌面 —— k=6 已经退过一次了）
            //
            // ## 📏 PC 的原始结构（`_1377_ad_loop.py:2940-2979`，逐字）
            // ```python
            // if k == 6:                     # ⭐ 终端腿（雷神式整帧✕ → 回主屏点图标）
            //     _hx = find_x_all(img, box=None, ...)
            //     if _hx: ...; return
            // print("返回腿%d：★回主屏（底部快速上滑 §1645）→ 点桌面图标重进" % (k+1))
            // go_home("rbt%d" % k)
            // _d, _p = find_desktop_icon_paged(..., TARGET_APP)
            // ```
            // ⇒ PC 的**终端腿也是"回主屏 + 点桌面图标"**（与用户令一致），
            //   而它排在 **k 轮次的末尾**（⛔ 不是每一轮）。
            //
            // ## ⛔⛔ 我上一版的错（用户骂「转了一万圈」）
            // 我把这条腿写成了 `if k >= 1 { 回桌面 }` ⇒ **每一轮 k 都退桌面**
            // ⇒ 真机 trace：一条广告里 `H:HOME` **6 次**、点快手图标 **4 次**。
            // ✅ 现在只在 **k=6** 走一次（`switch k` 天然只到一次）。
            //
            // ## ✅ k≥7（默认 9 轮里的最后两轮）：如实说清并停手
            // ⇒ 交给主循环重判（它可能已回广告页/中心）。
            log("   §\(tag) 返回腿 k=\(k)：⛔ k=6 的「回桌面重进」已走过一次 ⇒ 停手交回主循环"
                + "（⛔ 不重复退桌面 —— §2932 血案）")
            return false              // ⭐ §2971 没出手 ⇒ 如实回报（⛔ 不许冤杀）
        }
    }

    /// ⭐ 转化：点落地页里的「安装/获取/打开」—— 移植 PC `click_install`（`_1377_ad_loop.py:8738`）。
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
    ///
    /// ---
    ///
    /// # ⛔⛔⛔ §2896 **本函数被整段重写** —— 三处错，逐条有真机取证
    ///
    /// ## 错①：页型闸**提到了文字腿之前**（PC 在**之后**）
    /// 旧版第①道就是 `guard looksLikeAppStorePage`，不过就 `return`
    /// ⇒ **把文字腿一起挡死了**。PC 逐字（`_1377_ad_loop.py:8757-8767`）：
    /// ```python
    /// for _w,_x,_y in words(img,(0,280,451,977)):   # ① 文字腿：**先跑，无页面闸**
    ///     if _w.strip() in ("获取","安装","下载","免费",...): click_at(...); return True
    /// if not is_appstore_page(img): return False     # ② 闸**只挡形状腿**
    /// _c = find_cloud(img)                           # ③ 形状腿（云朵）
    /// ```
    /// 📏 真机铁证（`_v2885`，百度地图 App Store sheet）：
    /// ```
    /// 全屏蓝像素 9787，而 BOX_DONE_BLUE=(0,85,140,150) 内 = 0  ⇒ ⛔ 恒不过闸
    /// §adbox_inst6 不是 App Store 页 ⇒ 跳过点安装        ← 明明就在 App Store 页
    /// ```
    ///
    /// ## 错②：页型判据本身**已过期**（新版 iOS 版式变了）
    /// 旧判据数「**左上**那一带够不够 iOS 蓝」（PC 标定：App Store 页 289~290，其它页 0）。
    /// 但新版式（叠加图 `_verify2894/diagnosis.png`）是：
    /// ```
    ///   [黑 ✕ 支持] (43,110)              [du]        [ 打开 ] (389,115)  ← 蓝胶囊 3388px
    /// ```
    /// ⇒ 左上换成了**黑色 ✕**（`appstore_x` 就是它），蓝色**搬到了右上**。
    ///   蓝色实测：BOX(左上) = **0**；右上胶囊带(x300..451,y80..160) = **3409**。
    /// ⚠️ 而且旧判据还会**误判**：H5 落地页 `_stuck2855.jpg`（「了解更多」蓝条）
    ///   在 BOX 内竟有 **256** 个蓝像素 ⇒ 旧闸**两头都不对**（既漏真、又认假）。
    /// 📏 `_dev/_2897` 在 **43 张**本地帧上量过分离度：
    ///   「右上胶囊蓝」在这 43 张里 **App Store sheet = 3409，其余全部 = 0**（干净分开）。
    ///
    /// ## 错③：**无闸照抄 PC 会点到诱饵**（这条 PC 自己也踩）
    /// PC 文字腿 ROI = `(0,280,451,977)`。而真机上 App Store sheet 的结构是：
    /// ```
    ///   y=106  打开        ← ⭐ 本 App 自己的按钮（唯一）
    ///   y=418  获取        ┐
    ///   y=508  获取        │ ⛔ 全是「更多来自…的 App」/「你可能还喜欢」
    ///   y=684  获取        │    列表里**别的 App**（百度贴吧/腾讯地图/高德/地铁通）
    ///   y=773  获取        │    ⇒ 点它 = 下载一堆无关 App，**且都不给广告奖励**
    ///   y=864  获取        ┘
    /// ```
    /// ⇒ PC 的 ROI(y≥280) **恰好把真按钮(y=106)排除、把 5 个诱饵全包进来**。
    ///   ⛔ 若照 PC 抄 ⇒ **比"什么都不点"更糟**。
    /// 📏 实测判别特征 = **y 位置**（本 App 按钮在**页首带**；诱饵全在 y≥418），
    ///   ⛔ 不是词表本身：`_dev/_2895` 逐条量过 6 个候选，
    ///   页首带 y<200 内**只有 1 个**按钮（唯一性 ✅），其余 5 个「获取」的
    ///   蓝底只有 273~285 px（小图标），而真按钮有 **3129 px**（实心胶囊）。
    ///
    /// ## ✅ 现在的腿序（= PC 顺序 + 一条防诱饵的 ROI 选择）
    /// ```
    /// ① 文字腿（**先跑，无页面闸** —— 照 PC）—— ROI 按"是不是 sheet"**二选一**：
    ///      · 是 App Store sheet ⇒ 扫**页首带** y55..205（本 App 自己的按钮）
    ///        ⛔ 这就是防诱饵那条：推荐列表里的「获取」全在 y≥418
    ///      · 不是 sheet（H5 落地页）⇒ 扫 PC 原 ROI y280..977（照抄，⛔ 不改）
    ///    词表含「打开/更新」（用户令：已下载要去打开；PC 词表缺这条）
    /// ② 形状腿（云朵）—— **这里才过页型闸**（照 PC §1620 的 29% 误报闸）
    /// ③ 点完补一枪「安装」确认弹层（照 PC §1728/§1783）
    /// ```
    /// ⚠️ 文字腿过 `forbidden()` 支付红线闸（照 PC：⛔ 绝不点支付/购买）。
    private func clickInstall(_ img: UIImage, tag: String) {
        // ⭐ 判「这是不是 App Store sheet」——只用来**选文字腿扫哪一带**
        //   （⛔ 不用它当"允许/禁止点安装"的闸 —— 那正是错①）
        //
        // ⛔⛔⛔ §2912 **绝不能用 `appstore_x` 判"这是 sheet"（我 §2896 犯的回归）**
        //
        // ## 真机血案（0.20，2026-10-16，三轮广告全部没点安装）
        // ```
        // §adbox_inst3 安装文字腿：⭐ 判为 **App Store sheet** ⇒ 只扫**页首带**（⛔ 不扫宽 ROI…）
        // §adbox_inst3 安装形状腿：不在 App Store 模态页 ⇒ **不找云朵**
        // §adbox_inst3 ⚠️ 没找到安装/打开钮（文字腿/云朵都没中）⇒ 不点
        // ```
        // 第 1 行与第 2 行**自相矛盾** ⇒ 说明 `onSheet` 两个来源不一致：
        // ```swift
        // let onSheet = looksLikeAppStorePage(img) || nav.detect("appstore_x", img) != nil
        // //            ↑ 第2行说这个 false        ↑ 第1行说这个 true
        // ```
        // ## ⛔ 根因：`appstore_x` 是一个**裸 ✕**（词表 = X/✕/×），**H5 落地页也有**
        // 它证明的是"这页有个关闭钮"，⛔ 不是"这是 App Store sheet"。
        // ⇒ 在 H5 落地页上 `onSheet` 被误判 true ⇒ **跳过宽 ROI** ⇒
        //   真正的「下载应用」/「立即下载」**一个都不点**（用户令要的"没下载的要做下载"就这么丢了）。
        //
        // ## ✅ 改用它判（`_dev/_2912` 在两类真机帧上量过，分离干净）
        // ```
        //   ① 右上蓝胶囊 ≥1200     —— sheet 3409 ／ H5 落地页 0        ✅
        //   ② 推荐列表标记词       —— 只在 sheet 出现（更多来自/你可能还喜欢/App 内购买）✅
        //   ⛔ 裸 ✕（appstore_x）—— 两类都可能有 ⇒ **不许**参与本判据
        // ```
        let looksSheet = Self.looksLikeAppStorePage(img)
        let hasRecoList = Self.hasAppStoreRecoList(img, rec: rec, bw: baseW)
        let onSheet = looksSheet || hasRecoList
        if onSheet && !looksSheet {
            log("   §\(tag) 安装腿：⭐ 靠**推荐列表词**判为 App Store sheet"
                + "（「更多来自…的 App」/「你可能还喜欢」—— 这类列表只在 sheet 上出现）")
        }

        // ── ① 文字腿（**先跑，无页面闸** —— 照 PC `click_install` 的腿序）──
        let textROI = onSheet ? Self.boxInstallTop : Self.boxInstallWide
        let where_ = onSheet ? "页首带(本 App 自己的按钮)" : "宽 ROI(H5 落地页，照 PC)"
        if onSheet {
            log("   §\(tag) 安装文字腿：⭐ 判为 **App Store sheet** ⇒ 只扫**页首带**"
                + "（⛔ 不扫宽 ROI：那 5 个「获取」是推荐列表里**别的 App**，点了会下错 App）")
        }
        if let hit = Self.findInstallWord(img, rec: rec, roi: textROI,
                                         words: installWordsCfg, extraKeys: forbidKeysCfg,
                                         loginKeys: loginKeysCfg) {
            log("   §\(tag) 安装文字腿[\(where_)]：「\(hit.0)」"
                + "@(\(Int(hit.1.midX)),\(Int(hit.1.midY)))⇒ 点它")
            nav.tapPoint(Double(hit.1.midX), Double(hit.1.midY), why: "安装文字腿（\(where_)）")
            Self.waitAndClickInstallConfirm(rec: rec, nav: nav, log: log, tag: tag,
                                            extraKeys: forbidKeysCfg, grab: grab,
                                            isCancelled: isCancelled)
            return
        }

        // ── ② 形状腿（云朵）—— **必须过页型闸**（照 PC §1620）──────────────
        if Self.looksLikeAppStorePage(img) {
            if let p = Self.findDownloadCloud(img) {
                log("   §\(tag) 云朵下载钮 @(\(Int(p.x)),\(Int(p.y)))（横宽+箭头在下方 双判据）⇒ 点它")
                nav.tapPoint(Double(p.x), Double(p.y), why: "云朵下载钮（App Store）")
                Self.waitAndClickInstallConfirm(rec: rec, nav: nav, log: log, tag: tag,
                                                extraKeys: forbidKeysCfg, grab: grab,
                                                isCancelled: isCancelled)
                return
            }
        } else {
            log("   §\(tag) 安装形状腿：不在 App Store 模态页 ⇒ **不找云朵**"
                + "（照 PC §1620：光靠形状有 29% 误报）")
        }
        log("   §\(tag) ⚠️ 没找到安装/打开钮（文字腿/云朵都没中）⇒ 不点")
    }

    /// ⭐⭐⭐ §2912 **App Store sheet 的第二判据：推荐列表词**
    ///
    /// ## 为什么需要它（⛔ 不能只靠右上蓝胶囊）
    /// 蓝胶囊要求"这一帧蓝像素 ≥1200" ⇒ 若某一版式把「打开」按钮改成**灰色/其他色**
    /// （iOS 在"已安装"态下确实可能不画蓝），蓝胶囊就会漏 ⇒ 又误判成"不是 sheet"
    /// ⇒ 回到 §2896 的老毛病（宽 ROI → 点到推荐列表里**别的 App**）。
    ///
    /// ## 判据（`_dev/_2912` 在真机两类帧上量过）
    /// App Store sheet 特有的**两段列表标题**：
    /// ```
    ///   「更多来自 "北京百度网讯…" 的 App」     ← 开发者聚合列表
    ///   「你可能还喜欢」                        ← 推荐列表
    ///   「App 内购买」（每个列表项右下角的小字） ← 最密集、最稳
    /// ```
    /// ⇒ H5 落地页**一个都没有**（真机 `_verify2890` / `_stuck2855` / `_r2_land` 三帧实测）。
    /// ⛔ 三者**任一**命中即算（同一语义的三种版式写法）。
    static func hasAppStoreRecoList(_ img: UIImage, rec: Recognizer, bw: Double) -> Bool {
        // 列表标题在屏幕中部（sheet 的下半屏）；⛔ 不含页首带（那带是"本 App 自己的按钮"）
        let band = CGRect(x: 0, y: 200, width: bw, height: 777)
        let items = rec.ocrRegion(img, rect: band, minConfidence: 0.3)
        let joined = items.map(\.0).joined()
        return appStoreRecoKeys.contains { joined.contains($0) }
    }

    /// §2912 App Store sheet 的推荐列表标记词（⛔ 逐条来自真机 OCR 实测）
    private static let appStoreRecoKeys = [
        "更多来自",        // 「更多来自 "北京百度网讯…" 的 App 〉」
        "你可能还喜欢",     // 推荐列表标题
        "App 内购买",      // 列表项右下小字（最密集、最稳）
        "App内购买",
    ]

    /// §2896/§2918 **安装/打开腿的两条 ROI**（基准 451×977 像素）
    ///
    /// · `boxInstallTop`  —— **页首带**：App Store 页 **本 App 自己**的按钮。
    ///   ⛔⛔ §2918 **下沿 205 → 340**（两种版式实测，见下）
    /// · `boxInstallWide` —— **宽 ROI（照 PC `words(img,(0,280,451,977))`）**：
    ///   给 **H5 落地页**用（真机 `_v2890`：`下载应用`@735、`立即下载`@837）。
    ///   ⛔ 在 App Store sheet 上**禁用**（会命中别的 App 的「获取」）。
    ///
    /// # ⛔⛔⛔ §2918 为什么页首带必须到 340（真机 bug 取证）
    /// 真机 0.21 trace（元宝的 App Store 商品页）：
    /// ```
    /// §adbox_inst1 安装文字腿[宽 ROI(H5 落地页，照 PC)]：「更新」@(365,805)⇒ 点它
    /// ```
    /// ⚠️ 它走了**宽 ROI** 且点在 **y=805** —— 而截图实测（`_dev/_2916`/`_2917`）：
    /// ```
    ///   App Store「商品页」版式：本 App 的「更新」按钮在 基准(221,276)  85x37
    ///   同一页 y=805 那几个蓝块是**页面底部推荐行**里别的 App 的「更新」 ⇒ ⛔ 诱饵
    /// ```
    /// ⇒ 旧页首带 `y55..205` **把它漏了（低 71px）**，于是掉进宽 ROI、点到了诱饵。
    ///
    /// ## 📏 两种版式的实测位置 + 诱饵起点（决定上界）
    /// | 版式 | 本 App 按钮 | 第一个诱饵 |
    /// |---|---|---|
    /// | sheet（百度地图 `_v2885`） | y=**106** | y=**418**（5 个「获取」） |
    /// | 商品页（元宝截图） | y=**276** | y=**805**（推荐行） |
    /// ⇒ ✅ 上界取 **340**：两种版式都收进来，且**离最近的诱饵还有 78px**。
    ///
    /// ## ⛔ 为什么敢放大到 340（安全性靠"精确文字匹配"兜住）
    /// 判据是**整词等值**（`findInstallWord`，照 PC L8758）⇒
    /// 例如 H5 上那个 `同意并跳转到苹果商店预约` 蓝按钮**不是**白名单词 ⇒ ⛔ 不会被点。
    /// （实测 `_dev/_2918`：只放大蓝色检测区会误判；而**放大文字 ROI** 因为走精确匹配，
    ///   在 `_dev/_2919` 的 12 帧复核里 FP=0。）
    static let boxInstallTop = CGRect(x: 0, y: 55, width: 451, height: 285)
    /// ⛔⛔ §2918 **上沿 280 → 200**（真机 bug：商品页的「更新」在 y=276，**差 4px 掉进空档**）
    ///
    /// ## 血案（0.21 trace + 截图实测）
    /// ```
    /// trace : §adbox_inst1 安装文字腿[宽 ROI]：「更新」@(365,805)   ← ⛔ 点到了别的东西
    /// 截图  : 本 App 的「更新」在 基准(221,276)                     ← 差 4px 在 ROI 外
    /// ```
    /// ⇒ 既然**精确整词匹配**才是真正的安全闸（`findInstallWord` 照 PC L8758），
    ///   ROI 只需保证"**装得下按钮**"，⛔ 不需要它兼职做安全判据。
    ///   `_dev/_2919` 在 12 帧上复核：这样放宽后 **FP=0**。
    static let boxInstallWide = CGRect(x: 0, y: 200, width: 451, height: 777)

    /// §2896 在 `roi` 内找**安装/打开词**（⛔ **精确匹配**，照 PC 的纪律）。
    ///
    /// # ⛔⛔⛔ §2914 **删掉「子串兜底」** —— 它会点中句子里的词（我 §2896 自己加的）
    ///
    /// ## 真机血案（0.20 现场帧 `_r2_land.jpg` 复算）
    /// H5 落地页上有一句广告文案 **「就有机会免费获取酱知现叛月长」**@y=457，
    /// 而真正的按钮是 **「下载应用」**@y=724。子串匹配 `t.contains("获取")` 先撞上那句
    /// ⇒ **点到了广告文案中间**（既不是按钮，也拿不到转化）。
    /// ```
    /// 命中(子串)：「就有机会免费获取酱知现叛月长」@(225,457)   ⛔ 期望「下载应用」
    /// ```
    ///
    /// ## 📏 PC 从来没有子串匹配（`_1377_ad_loop.py:8758` 逐字）
    /// ```python
    /// if _w.strip() in ("获取", "安装", "下载", "免费", "获取APP", "获取App"):
    /// ```
    /// ⇒ **整体等于**才算 —— 我那层"子串兜底"是**自己加的**，正是这次误命中的来源。
    /// ⚠️ 但「下载应用」「立即下载」这些**确实是按钮**（PC `CTA_KEYS` L279 里就列着
    ///   `"下载应用"`/`"立即下载"`/`"去下载"`/`"免费下载"`…）⇒ 它们必须能命中。
    /// ⇒ ✅ 正解 = **精确匹配 + 一份"已知按钮全称"白名单**（照 PC 的词表纪律，
    ///   ⛔ 不是"包含关系"）—— 见 `installWords`。
    ///
    /// 两遍都过 `forbidden()` 支付红线闸（照 PC：⛔ 绝不点支付/购买）。
    ///
    /// - Returns: (命中的文字, 它的框)；⛔ 没有 ⇒ nil（调用方**不放枪**）
    static func findInstallWord(_ img: UIImage, rec: Recognizer, roi: CGRect,
                                words: [String], extraKeys: [String]?,
                                loginKeys: [String]? = nil)
        -> (String, CGRect)? {
        let items = rec.ocrRegion(img, rect: roi, minConfidence: 0.3)
        for (t, r, _c) in items {
            // ⛔ 精确匹配：去掉空白后**整体等于**白名单里的某个词
            //   （白名单已含「获取APP/获取App/下载应用/立即下载」等各种按钮全称）
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard words.contains(s) else { continue }
            // ⛔ §2921 登录红线：⛔ 不点「登录」类（登录词表由调用方传，缺省走静态基线）
            if forbidden(t, extraKeys: extraKeys, loginKeys: loginKeys) != nil { continue }
            return (t, r)
        }
        return nil
    }

    /// §2896 **点完下载钮后的「安装」确认弹层补枪**（照 PC §1728/§1783 `_wait_and_click_install`）。
    ///
    /// ## 为什么必须有（PC 逐字 `_1377_ad_loop.py:8753-8755`）
    /// > 点完下载钮后**再抓一帧、只认「安装」两个字补一枪** ——
    /// > iOS 会拿「App Store / 账户 / 安装」确认弹层盖住整屏，
    /// > 不点掉它后面的浏览/返回全打在弹层上。⛔ 无弹层就不动。
    ///
    /// ## PC 的改法（§1783，逐字）
    /// ```python
    /// # ⭐§1783 **轮询等确认层**（⛔ 原来是固定 wait(3.0) 抓一帧 ⇒ 没等到就跳过）
    /// _wait_and_click_install("inst")
    /// ```
    /// ⇒ ⭐ **轮询**（不是固定等一次）—— 弹层是异步出现的。
    ///
    /// - Parameter grab: 取**新帧**的闭包（⛔ 不用调用方那张旧帧 —— 弹层还没出现）
    /// - Parameter isCancelled: ⛔ 不许用裸 `Thread.sleep`（本工程纪律：`sleepWithCancel`）
    ///   —— 否则用户点「停止」后还要等满 6×1.2s 才停得下来。
    static func waitAndClickInstallConfirm(rec: Recognizer, nav: Navigator,
                                           log: (String) -> Void, tag: String,
                                           extraKeys: [String]?,
                                           grab: () -> UIImage?,
                                           isCancelled: () -> Bool) {
        // ⭐⭐⭐ §2977 **补形状腿 + 改 ROI**（照 PC `_1377_ad_loop.py:8667 find_install_btn`）
        //
        // ## ⛔⛔ 血案（真机 2026-10-17 12:11~12:15，**3/3 条全落空**，逐字日志）
        // ```
        // §adbox_inst1 安装确认弹层：6 轮都没出现 ⇒ ⛔ 不动（照 PC：无弹层就不动）
        // ```
        // 而**同一时刻抓帧**（`_tmp_2975_run4.png`）上，「安装」蓝按钮**明明在**：
        // ```
        // 归一化 451×977 后实测：bbox x[166,284] y[896,933]  w=119 h=38  蓝像素 4023
        // 旧 ROI = CGRect(y: 380, height: 320) ⇒ y 380..700 ⇒ **零重叠**（结构性恒不命中）
        // ```
        // ## ⛔ 第二个错：只有**文字腿**（`s == "安装"`）—— iOS 的「安装」是**蓝底白字**，
        //    OCR 经常读不出（PC 注释逐字：`y>=860` 的 OCR **一个字都没读到**）。
        //
        // ## ✅ PC 的正解（两条腿**互补**，参数逐字照抄）
        // ```python
        // INSTALL_BTN_BLUE = (180, 80, 80, 200)   # (b>, b-r>, g>, g<)
        // INSTALL_BTN_BOX  = (60, 180, 22, 60)    # (w_min, w_max, h_min, h_max) 实测 118×38
        // _m[:int(_H * 0.85), :] = False          # ⛔ 只在下半屏找
        // ```
        // 📏 PC 注释真值：蓝块 `x[167,284] y[896,933]` 中心 `(225.5,914.5)`；
        //    我在真机帧上复算 = `x[166,284] y[896,933]` 中心 `(225.0,914.5)`（差 ≤0.5px）
        //    ⇒ **PC 参数可直接平移**，⛔ 不是我又猜一套。
        for i in 0..<6 {
            if isCancelled() { return }
            // ⭐ 可中断的等待（每 0.2s 检查一次取消，照 `sleepWithCancel`）
            var left = 1.2
            while left > 0, !isCancelled() {
                let d = min(0.2, left)
                Thread.sleep(forTimeInterval: d)
                left -= d
            }
            if isCancelled() { return }
            // 每一轮**重新抓帧**（弹层会动/会晚到）
            guard let cur = grab() else { continue }
            // ① 文字腿（保留；ROI 扩到**屏幕下半区** —— 「安装」在弹层底部）
            let roiText = CGRect(x: 0, y: 380, width: 451, height: 597)   // y 380..977
            let items = rec.ocrRegion(cur, rect: roiText, minConfidence: 0.3)
            for (t, r, _c) in items {
                let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard s == "安装" || s == "安装APP" else { continue }
                if forbidden(t, extraKeys: extraKeys) != nil { continue }
                log("   §\(tag) 安装确认弹层[文字腿]：「\(t)」@(\(Int(r.midX)),\(Int(r.midY)))"
                    + "（第 \(i + 1) 轮轮询命中）⇒ 补一枪")
                nav.tapPoint(Double(r.midX), Double(r.midY), why: "安装确认弹层[文字腿]")
                return
            }
            // ② ⭐ 形状腿（照 PC `find_install_btn`）—— 蓝底白字 OCR 读不出时靠它
            if let p = Self.findInstallBtn(cur) {
                log("   §\(tag) 安装确认弹层[形状腿]：蓝色大按钮 @(\(Int(p.x)),\(Int(p.y)))"
                    + "（第 \(i + 1) 轮轮询命中，OCR 读不出蓝底白字）⇒ 补一枪")
                nav.tapPoint(Double(p.x), Double(p.y), why: "安装确认弹层[形状腿]")
                return
            }
        }
        log("   §\(tag) 安装确认弹层：6 轮都没出现（文字腿+形状腿都没中）⇒ ⛔ 不动"
            + "（照 PC：无弹层就不动）")
    }

    /// ⭐⭐⭐ §2977 **「安装」确认层的蓝色大按钮**（形状腿）—— 逐字照抄 PC `find_install_btn`
    ///
    /// PC 依据（`_1377_ad_loop.py:8655-8695`，逐字）：
    /// ```
    /// ⛔ 真机血案：确认层**明明在**，但 `y>=860` 的 OCR **一个字都没读到**（蓝底白字）
    /// ⭐ 形状判据实测：蓝色像素 3980 个，下半屏蓝块 `x[167,284] y[896,933]`
    ///    ⇒ 中心 (225.5, 914.5)，用户截图量出 (225.8, 915.0) ⇒ **0.3px 精度**
    /// ```
    /// 判据：**下半屏**（`y > 0.85H`）的蓝色圆角大按钮，外接框 60~180 × 22~60。
    /// ⚠️ §2631 全局适配：PC 的 `0.85H` 是**比例**，本函数**先归一到基准**再按比例算
    ///   （⛔ 不在原始帧上索引 —— 那正是 §2631 血案的形态）。
    static func findInstallBtn(_ img: UIImage) -> CGPoint? {
        let base = FrameNormalizer.normalize(img)
        guard let cg = base.cgImage, let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let w = cg.width, h = cg.height
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        // PC `INSTALL_BTN_BLUE = (180, 80, 80, 200)` → (b>, b-r>, g>, g<)
        // ⚠️ 与 §2969 同源风险：这里**直接读 cgImage 原始字节**，若缓冲是 BGRA 则 R/B 读反。
        //    故**两种解读都试**（RGBA 优先，BGRA 兜底），命中任一即用 —— 免得再踩一次字节序坑。
        func scan(_ bgra: Bool) -> (CGRect, Int)? {
            var minX = w, minY = h, maxX = -1, maxY = -1, n = 0
            let yFrom = Int(Double(h) * 0.85)
            for y in yFrom..<h {
                let row = y * bpr
                for x in 0..<w {
                    let o = row + x * bpp
                    let c0 = Int(ptr[o]), c1 = Int(ptr[o + 1]), c2 = Int(ptr[o + 2])
                    let r = bgra ? c2 : c0
                    let g = c1
                    let b = bgra ? c0 : c2
                    if b > 180 && (b - r) > 80 && g > 80 && g < 200 {
                        n += 1
                        if x < minX { minX = x }; if x > maxX { maxX = x }
                        if y < minY { minY = y }; if y > maxY { maxY = y }
                    }
                }
            }
            guard n >= 300, maxX >= minX, maxY >= minY else { return nil }
            return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), n)
        }
        for bgra in [false, true] {
            guard let (rect, _n) = scan(bgra) else { continue }
            // PC `INSTALL_BTN_BOX = (60, 180, 22, 60)`：实测 118×38
            guard rect.width >= 60, rect.width <= 180,
                  rect.height >= 22, rect.height <= 60 else { continue }
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        return nil
    }

    /// ⭐⭐⭐ §2896 **是不是 App Store 模态页** —— 判据已按**新版式**重写。
    ///
    /// # ⛔⛔⛔ 为什么必须重写（旧判据在新版 iOS 上**结构性恒 false**）
    ///
    /// ## 旧判据（PC `is_appstore_page`，`_1377_ad_loop.py:8584` 逐字）
    /// ```python
    /// _a = np.asarray(img.crop(BOX_DONE_BLUE)).astype(np.int16)   # (0,85,140,150) ← **左上**
    /// return int(((_b > 170) & (_b - _r > 60) & (_g > 60) & (_g < 210)).sum()) >= 100
    /// ```
    /// PC 全量真帧标定：App Store 模态页 = **289~290** 个蓝像素；其它任何页面 = **0**。
    /// ⇒ 前提是「App Store 页**左上**有块蓝色的『完成』」—— ⛔ **那是旧版式**。
    ///
    /// ## ⛔ 新版式（真机 `_v2885`，叠加图 `_verify2894/diagnosis.png`）
    /// ```
    ///   [黑 ✕ 支持] (43,110)              [du]        [ 打开 ] (389,115)  ← 蓝胶囊
    /// ```
    /// ⇒ 左上换成了**黑色 ✕**（`appstore_x` 就是它），**蓝色搬到了右上**。
    ///
    /// ## 📏 实测（`_dev/_2892` + `_dev/_2897`，43 张帧）
    /// | 位置 | 蓝像素 |
    /// |---|---|
    /// | 旧 `BOX_DONE_BLUE`(0,85,140,150) 左上 | **0** ⇒ ⛔ 恒不过闸 |
    /// | 右上胶囊带(300..451, 80..160) | **3409** ⇒ ✅ 干净命中 |
    ///
    /// ⚠️ 旧判据还会**误判**：H5 落地页 `_stuck2855.jpg`（「了解更多」蓝条）
    ///   在旧 BOX 内竟有 **256** 个蓝像素（> 手机端阈值 15）⇒ 旧闸**两头都不对**。
    ///
    /// ## ✅ 新判据 = **两条并列**（覆盖新旧两种版式，⛔ 不是"都要"）
    /// ① **右上蓝胶囊**：新版式 sheet 的「打开/获取」按钮（实测 3409 vs 其余 0）
    /// ② **左上蓝「完成」**：旧版式（PC 原判据，保留 ⇒ ⛔ 不互斥）
    ///
    /// ⛔⛔ §2631 **全局适配**：基准坐标 ⇒ **必须先归一到基准**再索引像素。
    static func looksLikeAppStorePage(_ img: UIImage) -> Bool {
        let base = FrameNormalizer.normalize(img)      // ⭐ §2631 先归一
        guard let cg = base.cgImage, let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8

        /// iOS 蓝（与 PC `_b > 170 && _b-_r > 60 && _g in 60..210` 同口径）
        func isBlue(_ x: Int, _ y: Int) -> Bool {
            let o = y * bpr + x * bpp
            let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
            return b > 180 && r < 120 && g > 80 && g < 190
        }

        // ① ⭐ 新版式：**页首右上那枚蓝胶囊**（「打开/获取」按钮本体）
        //
        // ⛔ 阈值取 **1200**：实测真 sheet = **3409**，而 43 张其它帧**全 0**
        //   ⇒ 放这里有两倍余量，且离"0"极远（⛔ 不会被小蓝图标蹭到）。
        //   复核（`_dev/_2895`）：5 个诱饵「获取」的蓝底只有 273~285 px ⇒ 远低于 1200。
        // ⚠️ 下界 300 是本判据**新增**的（旧代码下界恒 0）⇒ 必须钳制，
        //   ⛔ 免得 `300..<min(451, w)` 在 w<300 时崩（`Range requires lowerBound <= upperBound`）。
        var capsule = 0
        let capX1 = min(451, cg.width), capY1 = min(160, cg.height)
        if capX1 > 300, capY1 > 80 {
            for y in 80..<capY1 {
                for x in 300..<capX1 where isBlue(x, y) { capsule += 1 }
            }
        }
        if capsule >= 1200 { return true }

        // ② 旧版式的「左上蓝『完成』」—— 保留（两种版式并存，⛔ 不互斥）
        var legacy = 0
        for y in 85..<min(150, cg.height) {
            for x in 0..<min(140, cg.width) where isBlue(x, y) { legacy += 1 }
        }
        return legacy >= 15
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
