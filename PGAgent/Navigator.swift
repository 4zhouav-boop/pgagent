import Foundation
import UIKit

/// ⭐ 导航引擎 —— **配置驱动**（判据/页面图/漏斗全部来自 config.json）。
///
/// 三层结构（照 Alas `ui_goto` + `_1765_nav.py`）：
///   ① 到目的地了吗？
///   ② **恢复漏斗**（弹窗/盖屏优先 —— 弹窗盖屏时底下什么都点不到）
///   ③ 页面图上「前进一跳」
///   ④ 都失败 ⇒ 停手（⛔ 不盲点）
///
/// ⛔ 铁律：**先找到再点**。⛔ 广告页**放行**（用户令：「都是跑循环广告」）。
final class Navigator {

    let cfg: PGConfig
    let rec: Recognizer
    let ble: BLEController
    let log: (String) -> Void

    private var funnelLast: [String: Date] = [:]

    init(cfg: PGConfig, rec: Recognizer, ble: BLEController, log: @escaping (String) -> Void) {
        self.cfg = cfg
        self.rec = rec
        self.ble = ble
        self.log = log
    }

    // MARK: - 基准坐标

    var baseW: Double { cfg.settings?.base_w ?? 451 }
    var baseH: Double { cfg.settings?.base_h ?? 977 }
    var yFix: Double { cfg.settings?.y_fix ?? 4 }
    var tplThr: Double { cfg.settings?.template_threshold ?? 0.80 }

    /// ROI 支持两种写法：绝对像素 `[x0,y0,x1,y1]`，或全 0..1 的**比例**
    /// ⭐ 元素的 roi 直接内联（数组），也兼容 `rois` 表里的 key 字符串。
    func roi(_ inline: [Double]?) -> CGRect? {
        guard let a = inline, a.count == 4 else { return nil }
        return rect4(a)
    }

    /// 从 `rois` 表按 key 取（元素想复用时用）
    func roiKey(_ key: String?) -> CGRect? {
        guard let key = key, let a = cfg.rois?[key], a.count == 4 else { return nil }
        return rect4(a)
    }

    private func rect4(_ a: [Double]) -> CGRect {
        let frac = a.allSatisfy { $0 >= 0 && $0 <= 1 }
        if frac {
            return CGRect(x: a[0] * baseW, y: a[1] * baseH,
                          width: (a[2] - a[0]) * baseW, height: (a[3] - a[1]) * baseH)
        }
        return CGRect(x: a[0], y: a[1], width: a[2] - a[0], height: a[3] - a[1])
    }

    // MARK: - 检测一个元素

    /// 返回元素命中框（基准像素）或 nil
    func detect(_ name: String, img: UIImage) -> Recognizer.Hit? {
        guard let e = cfg.elements[name] else { return nil }
        // ⭐ 元素的 roi 直接内联；若为 null 则不过滤（全帧）
        let r = roi(e.roi)
        switch e.match {
        case "ocr":
            let words = e.words ?? []
            // ⭐ §2304 本元素可自带阈值（见 `Element.min_conf` 的血案）：
            //   直播间锚点「说点什么」可靠 Vision 只给 0.3 ⇒ 用全局 0.5 会被误杀。
            let minConf = e.min_conf ?? cfg.settings?.ocr_min_confidence ?? 0.5
            let h = rec.findWords(img, words: words, roi: r,
                                  minHits: e.min_hits ?? 1,
                                  minConfidence: minConf)
            // ⭐ §2307 **否定词闸**（见 `Element.not_words`）
            if var hh = h {
                let ev = hh.evidence
                if let bad = e.not_words, !bad.isEmpty,
                   bad.contains(where: { ev.contains($0) }) {
                    return nil
                }
                hh.name = name
                return hh
            }
            return nil
        case "template":
            let names = e.templates ?? []
            guard !names.isEmpty else { return nil }
            if let (rect, score, used) = rec.poolMatch(img, tplNames: names, roi: r,
                                                       threshold: e.threshold ?? tplThr,
                                                       mask: e.mask) {
                return Recognizer.Hit(name: name, rect: rect, score: score,
                                      evidence: used)
            }
            return nil
        // ⭐⭐⭐⭐⭐ §2621 **色彩判据元素**（`match: "color"`）——
        //    目前只有一种：`coin_ball`（红包/金币悬浮球）。
        //
        // ## ⛔ 为什么必须补这一种（用户令逐字）
        // > 「**你移植一个一个移植吧。怎么总是卡死要自己制造方案。
        // >   就调用PG控制器的方案就行了啊。**」
        //
        // 我原来把 `coin_ball` **只写在漏斗里**（当"恢复腿"），
        // 而**页型判据里用不了它** ⇒ 于是 `feed.check` 只能拿**底栏「首页」**凑合
        // ⇒ **消息页底栏也有「首页」** ⇒ 页型误判成 feed ⇒ 死循环（见 §2621 血案）。
        //
        // ✅ PC 的做法（`_1377_ad_loop.py:5655 ks_is_feed_home`）**逐字**：
        // ```python
        // if feed_judge(img):                       # ⭐ 红包球（零 OCR）**优先**
        //     return True
        // return all(k in txt(img, KS_BAND_TOP) for k in KS_TOP_HOME)   # 或 顶栏 同城+商城
        // ```
        //   而 `feed_judge` = `find_coin_entry(img) is not None`（L4622）
        //   ⇒ **PC 判 feed 靠"红包球"或"顶栏同城+商城"，⛔ 从来不用底栏「首页」**。
        // ⇒ 所以本 `color` 类型就是那条 `feed_judge` 的落地。
        //
        // ⚠️ 判据全部内联在 `ColorBlob`（PC `find_coin_entry` 的逐行移植，含
        //    尺寸闸 `[20,55]` 与 fill 闸 `[0.68,0.88]`）——
        //    真机离线复算：真 feed ✅ `(52.1,156.6) fill=0.742`；
        //    **消息页 ❌ None**；任务中心 ❌（大号金币数字 `w=80` 被尺寸闸挡）；搜索页 ❌。
        case "color":
            guard e.color == "coin_ball" else { return nil }
            guard let c = ColorBlob.findCoinBall(img) else { return nil }
            return Recognizer.Hit(name: name,
                                  rect: CGRect(x: c.x - 15, y: c.y - 15,
                                               width: 30, height: 30),
                                  score: 1.0, evidence: "color/coin_ball")
        // ⭐⭐⭐⭐⭐ §2985 **顶栏胶囊 ✕ 的 OCR 兜底定位**（`match: "ocr_tail_x"`）
        //
        // ## ⛔ 为什么必须有这一种（真机实证，2026-10-17，⛔ 不是推测）
        // 真机 `_tmp_stuck_after.jpg` 的 `/recogdiag` 原始输出：
        // ```
        // pill_x      {"hit": false}                        ← ⛔ 模板**不命中**
        // ad_capsule  {"hit": true, "ev":"已成功领取814金币×", "x":52,"y":81}
        // ```
        // 而 `pill_x` 是**收奖励的唯一入口**（`FeatureEngine.swift:1320`）⇒
        // 模板 miss ⇒ 一次都没点 ⇒ 日志刷 42 次
        // 「⛔ 点了也离不开广告页 ⇒ 本条不计入完成」⇒ 收奖励条数不涨
        // ⇒ **无进展闸触发停手**（`run_trace.log` 统计：无进展 73 次最多）。
        //
        // ## 为什么模板会 miss —— 根因
        // iOS Vision 把这个 ✕ **合并进了文本词元**：
        // ```
        // 『已成功领取814金币 ×』  x=52.5 w=163.1 ⇒ 右边缘 = 215.6, 中心 y = 89.5
        // ```
        // ⇒ 那不是一个独立图形，而是**文本的尾字符** ⇒ 任何模板都匹配不到它。
        //
        // ## PC 的权威依据（`_1377_ad_loop.py`，逐字）
        // ```python
        // L3973: def find_toast_x(img, roi=(10, 84, 300, 124))    ← 限定带
        // L1565-1570 真机验证过的真实 ✕: (210.5,88.5) (213.5,88.5) (214,89)
        // L1885: ⛔ 全屏搜有 26 帧假阳（倒计时文案里的 × 与关闭 ✕ 同形）
        //        ⇒ **必须限定带**；限定带后 0 假阳
        // ```
        //
        // ## 离线复算定标（`_dev/_2985_claimx_verify.py`，346 帧全量）
        // ```
        // 真机 ✕ 实测分布：x ∈ [212.7, 228.5]   y ∈ [88.8, 91.6]
        // 判据 = roi 带内 ∧ 词元含 ✕ 类字符 ∧ 点落窗口 ∧ 顶栏含「已成功领取」
        //   POS 广告页 89/111 = 80.2%
        //   NEG 非广告页 0/235 = 0.0%     ← 收紧前是 24 张假阳（y≈111 的 H5 角标 + x≈254 的新广告）
        // ```
        // ⛔ 三条闸的缺省值 = 上面**复算通过**的那组，⛔ 不是猜的。
        case "ocr_tail_x":
            let items = rec.ocr(img, minConfidence: e.min_conf ?? cfg.settings?.ocr_min_confidence ?? 0.5)
            let band = r                                    // PC `find_toast_x` 的限定带
            let xr = e.x_range.flatMap { $0.count >= 2 ? ($0[0], $0[1]) : nil } ?? (200.0, 240.0)
            let yr = e.y_range.flatMap { $0.count >= 2 ? ($0[0], $0[1]) : nil } ?? (86.0, 96.0)
            let crosses = Set(e.cross_chars ?? ["×", "✕", "╳", "x", "X"])
            // ① 到账闸：必须读到 `require_words` 里任一词（缺省「已成功领取」）
            let req = e.require_words ?? ["已成功领取"]
            if !req.isEmpty {
                let bandText = items.reduce(into: "") { acc, it in
                    let c = CGRect(x: it.1.origin.x + it.1.width / 2,
                                   y: it.1.origin.y + it.1.height / 2,
                                   width: 1, height: 1)
                    if let b = band, b.contains(c) { acc += it.0 }
                }
                let compact = bandText.replacingOccurrences(of: " ", with: "")
                if !req.contains(where: { compact.contains($0) }) { return nil }
            }
            // ② 在带内找含 ✕ 类字符的词元，取**该字符的右边缘**作点击点
            var best: (x: Double, y: Double, ev: String)? = nil
            for it in items {
                let text = it.0, box = it.1
                // ⚠️ 词元**中心**必须落在带内（PC 的 `txt(img, box)` 口径）
                let center = CGPoint(x: box.origin.x + box.width / 2,
                                     y: box.origin.y + box.height / 2)
                if let b = band, !b.contains(center) { continue }
                // 取词元里**最后一个** ✕ 类字符
                var lastIdx: Int? = nil
                for (i, ch) in text.enumerated() where crosses.contains(String(ch)) { lastIdx = i }
                guard let li = lastIdx else { continue }
                let frac = Double(li + 1) / Double(max(1, text.count))
                let px = box.origin.x + box.width * frac
                let py = box.origin.y + box.height / 2
                // ③ 坐标窗口闸（离线复算定的，⛔ 不能省）
                if !(xr.0...xr.1).contains(px) || !(yr.0...yr.1).contains(py) { continue }
                if best == nil || px > best!.x {
                    best = (px, py, "ocr_tail_x『\(text)』→(\(Int(px)),\(Int(py)))")
                }
            }
            guard let b2 = best else { return nil }
            return Recognizer.Hit(name: name,
                                  rect: CGRect(x: b2.x - 12, y: b2.y - 12, width: 24, height: 24),
                                  score: 1.0, evidence: b2.ev)
        default:
            return nil
        }
    }

    /// ⭐⭐⭐ **页型判定顺序**（§2247 —— 这是必须显式写死的一条）
    ///
    /// ## 为什么不能靠字典顺序（真机会不稳）
    /// Swift 的 `Dictionary` **无序**（每次遍历顺序还可能不同），
    /// 而 PC 的 `PAGES` 是 Python dict —— **有序**，它靠**插入顺序**做优先级：
    /// ```
    /// PC 的 PAGES 顺序：center → feed → featured → mall → msg → deeppage → darkpage → … → ad_video
    /// 📏 PC 原文：「**⛔⛔ 必须先判商城**」
    ///    「商城页也有底栏\"首页\" ⇒ 只靠 tab_home 会误判成 feed」
    /// ```
    /// ⇒ 在 Swift 里**必须显式排序**，否则：
    /// · `deeppage`（只要求 `back_arrow`，很宽）可能抢在 `feed`/`mall` 前命中
    /// · `mall` 可能被 `feed` 抢（两者都有底栏「首页」）
    ///
    /// ## 排序规则（严格程度：**具体 → 宽泛**）
    /// ```
    /// ① center      —— 最具体（顶栏多个金币锚点）
    /// ② ext_landing —— ⭐ 外部落地页：靠"京东试用/试用频道"等**独有词** ⇒ 必须在 feed 前
    /// ③ mall        —— ⭐ 必须在 feed 前（PC 血案）
    /// ④ featured / feed / msg —— 底栏各 tab
    /// ⑤ deeppage / darkpage   —— 只靠一个返回键，**最宽泛 ⇒ 最后**
    /// ```
    /// ⭐ §2307 **真机血案：装了 ext_landing 后第一次验证就被 feed 抢了**
    ///   手机停在京东试用落地页，而那页的底部分类栏**也有「首页」字样**
    ///   ⇒ `feed`（`check:[tab_home]`）抢在前面命中 ⇒ 判成 `feed` ⇒ 走 `coin_ball`
    ///   ⇒ 在外部页上找红包球（当然找不到）⇒ 卡死。
    ///   ⛔ 这与 §2247 记的是**同一类**（当时是 mall 被 feed 抢："商城页也有底栏首页"）。
    ///   📏 一句话：**底栏信号对"我在哪"没有区分度**
    ///      ⇒ 凡靠"页面独有识别性"的页型，必须排在**只靠底栏**的页型之前。
    /// ⚠️ §2979：`ad_video` 仍是 `island:true`，但 **`pageHere(includeIslands: true)` 会判它**。
    ///    “导航不碰广告页”由**调用方传默认值 `false`** 保证（默认零回归），
    ///    ⛔ 不是靠识别层假装看不见（那正是四套判据互相否定的根因）。
    static let pageOrder: [String] = [
        "center",
        "ext_landing",   // ⭐ 必须在 feed 之前（外部页底部也有「首页」）
        "game_page",     // ⭐ 内置小游戏页：靠“规则介绍/牌型学习/战战训练”等独有词（§2311）
        "mall",          // ⭐ 必须在 feed 之前
        "featured",
        "feed",
        "msg",
        "deeppage",
        "darkpage",
        "draft",
        "live",
        "ad_video",      // 孤岛（会被跳过）
    ]

    /// 页面判定（支持 `not` 反向）
    ///
    /// ⭐ 按 `pageOrder` 排序遍历（⛔ 不靠字典顺序，见 `pageOrder` 的说明）
    ///
    /// # ⭐⭐⭐⭐⭐ §2979 **`includeIslands` —— 把“识别”与“导航”两件事分开**
    ///
    /// ## ⛔⛔ 血案（真机 2026-10-17，本轮逐字日志）
    /// ```
    /// 13:41:47  已回广告页（第 1 次检查）⇒ 继续等倒计时
    /// 13:41:50  顶栏还有倒计时 ⇒ 不点胶囊 ✕（连拒 6 轮）
    /// 13:42:01  ⛔ 点了也离不开广告页 ⇒ 本条不计入完成
    /// 13:42:02  ✅ 已回广告页（第 1 次检查）      ← 同一时刻两个判据结论相反
    /// ```
    /// 根因：`ad_video` 带 `island:true` ⇒ 本函数 `continue` 跳过它 ⇒ **广告页永远 `unknown`**。
    /// 而元素识别层明明 100% 命中（同帧 `/recogdiag` 原始输出）：
    /// ```
    /// ad_capsule {"hit":true,"score":1,"ev":"已成功领取591金币×","x":52,"y":81}
    /// ad_mark    {"hit":true,"score":1,"ev":"广告","x":348,"y":83}
    /// 而 page = "(unknown)"
    /// ```
    /// ⇒ 于是项目里长出**四套并行判据**（`pageHere` / `looksLikeAdPage`×21 处 /
    ///   `cfg.pages["ad_video"].check` 直读 / `Runner:377` 死分支），互相否定。
    ///
    /// ## ✅ 正解：`island` 的**本意**是“导航不要碰广告页”，⛔ 不是“识别层假装看不见”
    /// PC 早就是这么分的（`_dev/anchors/registry.json`）：**18 个页型全部参与判序**，
    /// `ad_video` 是 **order=7 的正常页型**；“不碰它”由**消费侧**（`PAGE_PLAN`）表达。
    /// ```python
    /// PAGE_PLAN["ad_video"] = "等倒计时(30~60 随机) → 点 CTA 做转化 → 点 ✕ 收奖励"
    /// ```
    ///
    /// ⇒ 本函数拆成两个语义：
    ///   · `includeIslands: false`（默认）—— **导航用**：孤岛页不参与“我在哪” ⇒ 行为与以前**完全一致**
    ///   · `includeIslands: true`  —— **识别用**：孤岛页正常参与判序 ⇒ 广告页能判成 `ad_video`
    ///     ⛔ 调用方拿到 `ad_video` 后自己决定“不碰”（这才是 `PAGE_PLAN` 的语义）
    ///
    /// ⛔ 为什么不直接把 `island` 删掉：那会让**所有**导航分支突然“认得”广告页 ⇒
    ///   行为面过大（advisor 提醒正确）。用参数控制 ⇒ **默认零回归**，只有需要判断广告页的地方显式开启。
    ///
    /// - Parameter includeIslands: 是否让孤岛页（如 `ad_video`）参与判序。见上方说明。
    func pageHere(_ img: UIImage, includeIslands: Bool = false) -> String? {
        // ① 先按显式优先级排；② 没在优先级表里的页型**排到最后**（新加的页型不会抢占）
        let names = cfg.pages.keys.sorted { a, b in
            let ia = Self.pageOrder.firstIndex(of: a) ?? Int.max
            let ib = Self.pageOrder.firstIndex(of: b) ?? Int.max
            return ia < ib
        }
        for pname in names {
            guard let p = cfg.pages[pname] else { continue }
            // ⭐ §2979：默认跳过孤岛页（导航语义）；`includeIslands=true` 时正常判（识别语义）
            if p.island == true, !includeIslands { continue }
            guard let checks = p.check else { continue }
            var ok = true
            for c in checks where detect(c, img: img) == nil { ok = false; break }
            // ⭐⭐ §2275 **并列判据 `also_ok`**（任一命中即算本页型）——
            //    用于**抗 OCR 错字**（见 `ConfigStore.Page.also_ok` 的说明）。
            //    真机血案：`ad_video` 只认 `ad_capsule`，而真机胶囊 OCR 读不出
            //    ⇒ 判 `unknown` ⇒ **「广告页放行」失效** ⇒ 空转到停手。
            //    ✅ 补 `ad_mark`（词「广告」，实测命中）当并列判据。
            if !ok, let alts = p.also_ok, !alts.isEmpty {
                ok = alts.contains { detect($0, img: img) != nil }
            }
            if !ok { continue }
            if let nots = p.not {
                for n in nots where detect(n, img: img) != nil { ok = false; break }
            }
            if ok { return pname }
        }
        return nil
    }

    // MARK: - ⭐⭐⭐⭐⭐ §2364 回主桌面 → 进快手（**真机逐条验过的序列**）

    /// 把前台切到快手 / 快手极速版。
    ///
    /// ## ⭐ 这段是**真机一条一条试出来的**（§2360~§2363），⛔ 不是我猜的
    /// 命令表（全部走 ESP32 → BLE HID，⛔ 无开发者命令）：
    /// | 起点 | 命令 | 实测结果 |
    /// |---|---|---|
    /// | 快手 App 内 | `H:HOME` | ✅ 回主桌面 |
    /// | **副桌面** | `H:HOME` | ❌ **什么都不做**（帧文字一模一样） |
    /// | **副桌面** | 底部快速上滑 ×1 | ⚠️ 只挪一格，没回主桌面 |
    /// | **副桌面** | 底部快速上滑 ×2 | ✅ **回到主桌面**（快手图标出现） |
    /// | 主桌面 | 点图标 | ✅ **进入快手**（页型 = feed） |
    ///
    /// ⇒ **结论：回主桌面不是"一条命令"，是「上滑到看见快手为止」，而实测 2 条就到。**
    ///   PG 控制台里写的 `H:HOME`（⌘H）在**副桌面上完全无效** —— 这正是
    ///   「连快手都进不去」卡了两天的真正原因。
    ///
    /// ## ⚡ 命令预算（用户令：「**我都是最多 2 个命令回到主桌面**」）
    /// ```
    ///   本来就在主桌面（最常见） ： 0 上滑 + 1 OCR + 1 点         ← 最快
    ///   停在副桌面（H:HOME 之后） ： 2 上滑 + 1 OCR + 1 点         ← 用户口径
    ///   极端靠后                 ： 最多 +2 上滑（兜底）
    /// ```
    /// ⛔ **上滑之间不插 OCR** —— v0.10.59 写成"滑一次 OCR 一次"的循环，
    ///    最坏 4 次全屏 OCR + 4×2.5s ⇒ 白耗 15~20 秒，用户当场指出「效率极度低下」。
    ///
    /// ## ⛔ 明确不做的事（都是错的，已删）
    /// · **左右翻页找图标** —— 用户令：「**我要的是直接用上滑进入主页面 而不是傻逼左右翻找**」
    /// · 用 `H:HOME` 当主腿 —— 副桌面上无效（上表第 2 行）
    /// · 判「像不像桌面」来决定走哪条腿 —— 上滑本身就是"直到看见快手"的循环，
    ///   不需要额外的桌面判据（那判据还会因为帧延迟误判，§2344 血案）
    ///
    /// - Returns: true = 已发出「点图标」命令（⛔ 不代表真的切过去了）
    @discardableResult
    static func switchToApp(named which: String, rec: Recognizer, ble: BLEController,
                            frame: () -> UIImage?,
                            baseW: Double, baseH: Double, yFix: Double,
                            log: @escaping (String) -> Void) -> Bool {
        func hid(_ cmds: [String], gapUS: UInt32 = 130_000) {
            for c in cmds { _ = ble.send(c); usleep(gapUS) }
        }
        /// 底部快速上滑（照 PC `HOME_FLING`：起点 y=971 贴进 Home Indicator 区；必须快，120ms）
        let homeFling = BLEController.swipe(x1: 225, y1: 971, x2: 225, y2: 300,
                                            speed: .homeFling, baseW: baseW, baseH: baseH, yFix: yFix)

        /// ⭐⭐⭐⭐⭐ §2822 **等"画面稳住"再点** —— 修「乱点别的 APP」的真根因
        ///
        /// ## 血案（真机日志 2026-10-15 17:47:22，用户报「**乱点别的APP**」）
        /// ```
        ///   ① H:HOME 退出当前 App
        ///   ② 底部快速上滑，把桌面补到第 1 页
        ///   ✅ 2 条命令后命中「快手极速版」⇒ 点 (161,670)      ← ⛔ 点错了 App
        /// ```
        /// **裁图**（`_var/_A_apptapped161.jpg`）证明 **(161,670) 落在「keke 语音」** 上；
        /// 而「快手极速版」在 **(277,680)** —— 差 **116px ≈ 一整列**（列距 ≈113）。
        ///
        /// ## 根因：点到的是**翻页动画中途**那一帧的坐标
        /// ① 逐页枚举（`_dev/_2820_pages.py`）：桌面**只有第 1 页**有「快手极速版」，
        ///    稳定位置 **cx=278**；**任何一页都不在 161**
        ///    ⇒ 那一帧只能是**动画中的画面**，⛔ 不是任何一页的真实布局。
        ///
        /// ② 逐帧抓取（`_dev/_2821_burst.py`，抓 App 会收到的**每一帧**）实测：
        /// ```
        ///   t=0.56s  frames=322  帧龄=0.04s  cx=272.3   ← 动画中途，但**帧非常新鲜**
        ///   t=2.64s  frames=323  帧龄=0.07s  cx=278.0   ← 已定住
        /// ```
        /// ⇒ ⛔ **「等新鲜帧」挡不住这个错 —— 动画帧本身就很新鲜。**
        ///    而 `grabSync()` 的收帧闸是「帧龄 ≤ 6.0s」，
        ///    旧代码 `sleep(2.0)` 后**只抓一帧就点**，恰好可能落在动画窗口里。
        ///
        /// ## 修法：同一位姿必须**持续 ≥ `holdS` 秒**才认
        /// ```
        ///   读到图标位姿 ⇒ |x − 记录值| ≤ 6px 就一直等
        ///                  一旦超差（画面在动）⇒ 重新计时
        ///   持续满 2.5s（> 录屏一个节拍 2s）⇒ 稳了 ⇒ 才点
        ///   超时仍不稳 ⇒ **不放枪**（铁律①：宁可不动，⛔ 不点隔壁 App）
        /// ```
        /// 📏 为什么用「时间」而不是「帧指纹」：静止画面时录屏会产出**逐字节相同**的帧，
        ///    用指纹判"新帧"会永远判不出 ⇒ 正常情况反而点不下去。
        ///    而动画只持续 <1s ⇒ **没有任何位移能撑满 2.5s**，这个判据既够强又不误杀。
        /// 📏 容差 6px：定住后实测 277.97 / 278.00（抖动 <1px）；动画偏差是 116px 量级。
        func findAndTap(_ tag: String) -> Bool {
            let holdS = 2.5          // 同一位置要持续这么久（> 录屏节拍 2s）
            let tolPx = 6.0          // 位置容差
            let deadline = Date().addingTimeInterval(14.0)

            var heldX: Double?
            var heldSince: Date?
            var heldLabel = ""

            while Date() < deadline {
                guard let img = frame() else {
                    Thread.sleep(forTimeInterval: 0.4)
                    continue
                }
                guard let (pt, label) = findDesktopIcon(img, which: which, rec: rec,
                                                        baseW: baseW, baseH: baseH) else {
                    heldX = nil; heldSince = nil; heldLabel = ""    // 没看到 ⇒ 重新计时
                    Thread.sleep(forTimeInterval: 0.4)
                    continue
                }
                let x = Double(pt.x)
                if let hx0 = heldX, abs(x - hx0) <= tolPx {
                    if let t0 = heldSince, Date().timeIntervalSince(t0) >= holdS {
                        log("   ✅ \(tag)画面已稳住（同一位置持续 \(String(format: "%.1f", holdS))s，"
                            + "x≈\(Int(x))）命中「\(label)」⇒ 点 (\(Int(pt.x)),\(Int(pt.y)))")
                        hid(BLEController.moveAndClick(x: Double(pt.x), y: Double(pt.y),
                                                       baseW: baseW, baseH: baseH, yFix: yFix))
                        Thread.sleep(forTimeInterval: 6.0)      // 照 PC `wait(6.5)`
                        return true
                    }
                } else {
                    // 位置变了（或第一次）⇒ 重新开始计时
                    if let hx0 = heldX, abs(x - hx0) > tolPx {
                        log("   ⏳ \(tag)画面还在动（x \(Int(hx0)) → \(Int(x))）⇒ 继续等稳住")
                    }
                    heldX = x; heldSince = Date(); heldLabel = label
                }
                Thread.sleep(forTimeInterval: 0.4)
            }
            if let hx0 = heldX {
                log("   ⚠️ \(tag)等不到稳定画面（最后 x≈\(Int(hx0))「\(heldLabel)」）"
                    + "⇒ **不放枪**（铁律①：⛔ 不点可能已经移位的位置）")
            }
            return false
        }

        // ⭐⭐⭐⭐⭐ §2366 **回主桌面 = 2 条命令**（用户口径，⛔ 不再循环 OCR）
        //
        // ## 用户令（逐字）
        // > 「**你为什么还是在用滑动命令 虽然实现了 但是效率极度低下**」
        // > 「**我都是最多 2 个命令回到主桌面**」
        //
        // ## 这 2 条命令是什么（照我已实测出来的行为表）
        // ```
        //   ① H:HOME     —— 在 App 内有效（§2362 B 步实测：快手内 → 主桌面 ✅）
        //                    真身是 ⌘H（固件 src/main.cpp:113）；副桌面上无效，
        //                    但那不重要 —— 第 ② 条会把页补到第 1 页。
        //   ② 底部快速上滑 —— 把"桌面第 N 页"推到第 1 页
        //                    （§2363 帧证：副桌面 + 上滑 ×2 ⇒ 主桌面）
        // ```
        // ⇒ 一条"退出 App" + 一条"补页"，**2 条命令后必定在主桌面**。
        //
        // ## ⛔ 我上一版错在哪（v0.10.59，用户当场指出「效率极度低下」）
        // ```
        //   for round in 1...4 { 全屏 OCR → 上滑 → sleep 2.5s }
        // ```
        // 最坏 = 4 次全屏 OCR + 4 次上滑 + 10 秒空等 ⇒ 切个 App 白耗 15~20 秒。
        // **上滑之间根本不需要 OCR** —— 因为 2 条命令后位置是确定的（主桌面）。
        log("   ① H:HOME 退出当前 App")
        hid(["H:HOME\n"])
        Thread.sleep(forTimeInterval: 1.5)
        log("   ② 底部快速上滑，把桌面补到第 1 页")
        hid([homeFling])
        // ⭐ 录屏 ~1fps ⇒ 睡够让**新帧**落盘，⛔ 不是立刻抓（§2284 血案）
        // ⚠️ §2822：这里**不再**指望"睡够就行" —— 上滑有翻页动画，
        //    动画帧本身也很"新鲜"（实测 age=0.04s），睡 2.0s 抓一帧仍可能落在动画里
        //    ⇒ 真正把关的是 `findAndTap` 内部的「同一位置持续 2.5s」闸。
        Thread.sleep(forTimeInterval: 2.0)

        // 现在必定在主桌面 ⇒ 找图标 + **等稳住** + 点
        if findAndTap("2 条命令后") { return true }

        // ⭐ 兜底：只在"2 条命令后仍没看到图标"时才补 1 条上滑 + 1 次 OCR（最多 2 轮）
        for extra in 1...2 {
            log("   ⚠️ 第 ② 条后没看到图标 ⇒ 补 1 条上滑（兜底 \(extra)/2）")
            hid([homeFling])
            Thread.sleep(forTimeInterval: 2.0)
            if findAndTap("兜底 \(extra)") { return true }
        }
        log("   ⛔ 仍没看到「\(which)」图标 ⇒ **不放枪**（铁律②）")
        return false
    }

    /// 像不像 iOS 桌面/资源库 —— 照 PC `is_homescreen`（L7921）的**安全闸**
    static func looksLikeDesktop(_ img: UIImage, rec: Recognizer,
                                 baseW: Double, baseH: Double) -> Bool {
        let a = rec.ocrRegion(img, rect: CGRect(x: 150, y: 780, width: 170, height: 80),
                              minConfidence: 0.3)
        if a.contains(where: { $0.0.contains("搜索") }) { return true }
        let b = rec.ocrRegion(img, rect: CGRect(x: 0, y: 60, width: baseW, height: 80),
                              minConfidence: 0.3)
        return b.contains(where: { $0.0.contains("资源库") })
    }

    /// ⭐⭐⭐⭐⭐ §2631 **录屏节拍 + 等新帧的时长**（⛔ 必须成对，见 `switchToApp` 的血案）
    ///
    /// ⚠️ `outFpsInterval` **必须与 `Runner.outFpsInterval` 和
    ///    `PGShot/SampleHandler.fps` 的倒数一致**（2s/帧）——
    ///    Swift 跨 target 没法共享常量，所以这里再声明一次，
    ///    而 `Runner` 的**开机自检**会把不一致当场报出来。
    static let outFpsInterval: Double = 2.0
    /// 等一帧新图要多久 = 节拍 + 2s 余量（⛔ 不是固定 2 秒 —— 那是旧节拍的写法）
    static var frameWaitS: Double { outFpsInterval + 2.0 }

    /// ⭐ OCR 找「快手 / 快手极速版」图标标签，返回**图标落点**（标签上方 0.055 屏高）。
    ///
    /// 三条**排除闸**照 PC `_1377_ad_loop.py:7874`（⛔ 不照抄会把弹窗句子当图标）：
    /// 真机血案 `_var/_1755_stab_{1..4}.log`：iOS 弹「"快手"想访问相机。」（整句含"快手"）
    /// ⇒ 旧判据把它当图标 ⇒ **点了 8 次弹窗、4/4 全废**。
    ///
    /// - Parameters:
    ///   - img: 当前帧（已归一化到基准 451×977）
    ///   - which: `kslite` 要含「极速」；`ks` 要**不含**「极速」（否则会认成极速版）
    static func findDesktopIcon(_ img: UIImage, which: String,
                                rec: Recognizer,
                                baseW: Double, baseH: Double) -> (CGPoint, String)? {
        let ws = rec.ocrRegion(img, rect: CGRect(x: 0, y: 60, width: baseW, height: baseH - 60),
                               minConfidence: 0.3)
        var cands: [(CGPoint, String)] = []
        for (t, r, _c) in ws {
            let s = t.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || !s.contains("快手") { continue }
            if s.count > 6 { continue }                                  // ① 图标名短
            if s.contains(where: { "“”。？！，,".contains($0) }) { continue }  // ② 带标点=句子
            if ["想访问", "允许", "用于", "录制", "拍照", "直播"]
                .contains(where: { s.contains($0) }) { continue }         // ③ 弹窗语义词
            if which == "kslite" {
                if s.contains("极速") { cands.append((CGPoint(x: r.midX, y: r.midY), s)) }
            } else {
                if !s.contains("极速") { cands.append((CGPoint(x: r.midX, y: r.midY), s)) }
            }
        }
        guard !cands.isEmpty else { return nil }
        // 取**最上、再最左**（照 PC `sorted(key=(round(y/40), x))`）
        let pick = cands.sorted {
            let ra = (Double($0.0.y) / 40.0).rounded(), rb = (Double($1.0.y) / 40.0).rounded()
            return ra != rb ? ra < rb : $0.0.x < $1.0.x
        }[0]
        // ⭐ 图标在**标签上方 0.055 屏高**（PC `FH(0.055)`）
        //    真机实测：标签 (278,726) ⇒ 落点 (278,680) ⇒ 点进去页型 = feed ✅
        return (CGPoint(x: pick.0.x, y: pick.0.y - baseH * 0.055), pick.1)
    }

    // MARK: - 动作

    /// ⭐⭐ 点击时序（照电脑端 `ks_io.py::tap` 的**实测值**）
    ///
    /// ```python
    /// # ks_io.py:198
    /// def tap(x, y, wait=1.2):
    ///     cmd(plog(x, y), wait=0.15)   # ⭐ 移动后只等 0.15s
    ///     cmd("C:L", wait=wait)        # ⭐ 点击后等 1.2s
    /// ```
    /// 📏 **为什么必须等**（§2253 对齐）：我原来 `for cmd in cmds { ble.send(cmd) }`
    ///    两条命令**瞬间连发**（BLE 写不等）⇒ 板子可能把 `P:` 和 `C:L` 挤在一起处理，
    ///    甚至指针还没到位就按下了 ⇒ **点空**。
    /// ⇒ 现在显式对齐电脑端的节奏。
    static let tapMoveSettle: Double = 0.15
    static let tapAfterSettle: Double = 1.2

    /// 点击一个元素（⛔ 必须先找到 ⇒ 坐标是识别结果，不是盲点坐标）
    ///
    /// ⭐ 参数 `atomic`：`true` ⇒ 走固件**原子通道** `Q:x,y`（移+按+放一条 HID 序列）。
    ///    给**时序敏感**的场景用（系统弹窗）—— 照电脑端 `_ext_q`。
    /// ⛔ §2921 **需要过「登录红线闸」的元素** —— 只列**肯定项/动作按钮**。
    ///
    /// ## ⛔ 为什么必须是"白名单"而不是"所有元素"
    /// `tap()` 也用于**页面锚点**，而锚点的 `evidence` 是**整个 ROI 的 OCR 拼接**，例如：
    /// ```
    ///   center_marker ev = "＜任务中心/瓜分百亿/话费充值/金币商城 规则"
    /// ```
    /// ⇒ 若对所有元素无条件查「登录」，那么**未登录态**下快手顶栏出现「登录」时，
    ///   所有锚点点击会被一起拒掉 ⇒ **App 一步都走不动**。
    /// ⇒ ✅ 只对"这些元素本来就是**去点一个按钮**"的收口查登录。
    ///
    /// ## 📏 其它动作路径**已经**被覆盖（⛔ 别以为只有这里在管）
    /// ```
    ///   CTA        clickCTA  → forbidden(t, extraKeys:)   ← 内已含 login_keys ✅
    ///   安装/打开   findInstallWord → forbidden(...)       ← 内已含 login_keys ✅
    ///   坐标点击    tapPoint 只有坐标、没有文案 ⇒ 由上面两条腿在**选点前**就拦住
    /// ```
    static let loginGuardedElements: Set<String> = [
        "sys_prompt_allow",   // 外部授权「打开/允许」
        "consent_allow",      // 协议弹窗「同意」（⛔ 可能是「同意并登录」）
        "stay_panel_btn",     // 挽留面板「继续观看/领取奖励」
        "chest_cta",          // 宝箱面板 CTA
        "ad_task_btn",        // 任务行按钮
        "rec_stopped_ok",     // 录屏弹窗「好」
    ]

    /// ⚠️ §2925 **`@discardableResult` 必须紧贴函数声明** ——
    /// 我上次把 `loginGuardedElements` 插在它和 `func tap` **之间**，
    /// 编译器报 `'@discardableResult' attribute cannot be applied to this declaration`
    /// （属性挂到了注释/属性上）⇒ ⛔ 注释块与属性**都**要写在 `@discardableResult` **之前**。
    @discardableResult
    func tap(_ name: String, img: UIImage, atomic: Bool = false) -> Bool {
        // ⭐⭐⭐⭐⭐ §2841 **每次点击尝试都必须有日志**（用户令：逐字）
        //
        // > 「**这本来就是需要做的 每次操作都要有日志**」
        //
        // ## ⛔ 血案：这条日志的**缺失**直接导致一次定位失败
        // 用户报「误点了顶部的话费充值」，而我在日志里**找不到任何"点它"的记录** ——
        // 因为旧版这里是：
        // ```swift
        // guard let h = detect(name, img: img) else { return false }   // ⛔ 静默返回
        // ```
        // ⇒ **"点了但找不到元素"这个事实被吞掉了** ⇒ 我最后只能靠"配置+代码路径"推断，
        //   ⛔ 拿不到"到底点了什么"的直接证据（见 `_note_2838` §4）。
        //
        // ## ✅ 现在的规矩（照 PC `cmd()` 的做法 —— 它把**每一条**串口命令都打出来）
        // ```
        //   找不到元素 ⇒ 打 `⛔ 没找到「<名字>」⇒ 不点`        （含 ROI/match，便于排查）
        //   找到了     ⇒ 打 `★点「<名字>」@(x,y) score=… ev=…`（点击**之前**就打）
        //   发不出去   ⇒ 打 `⛔ BLE 未连接`（照 `ble.send` 的返回值）
        // ```
        // ⇒ 📏 **先打日志再点**（⛔ 不是点完才打）：万一点击卡住，日志也已经落盘。
        guard let h = detect(name, img: img) else {
            let e = cfg.elements[name]
            let roi = e?.roi.map { $0.map { String(format: "%.0f", $0) }.joined(separator: ",") } ?? "nil"
            log("   §tap ⛔ 没找到「\(name)」⇒ **不点**"
                + "（match=\(e?.match ?? "?") roi=[\(roi)]"
                + " words=\((e?.words ?? []).prefix(3)) tpl=\((e?.templates ?? []).prefix(2))）")
            return false
        }
        let c = h.center
        // ⛔⛔⛔ §2921 **登录红线闸** —— 用户令，逐字：
        //
        // > 「**外部授权都可以统一 但是不点击登录**」
        // > 「**同意授权但是登录 不登陆**」
        //
        // ## 为什么装在这里（`tap()` 是所有"按元素名点击"的收口）
        // 漏斗/导航/页面图**全走 `tap()`** ⇒ 装在这里，新加的腿**自动**受保护
        // （⛔ 不靠"记得在每个新腿里加一遍"）。
        //
        // ## ⛔⛔ 但**只对"动作按钮"生效** —— 为什么必须限定范围（血案预防）
        // `tap()` 也用于**页面锚点**（`center_marker`/`ad_task_btn`/`pill_x`…），
        // 而锚点的 `evidence` 是**整个 ROI 的 OCR 拼接**，例如实测：
        // ```
        //   center_marker ev = "＜任务中心/瓜分百亿/话费充值/金币商城 规则"
        // ```
        // ⇒ 若对该字符串**无条件**查「登录」，那么当快手顶栏恰好出现「登录」
        //   （**未登录态就是这么显示**）⇒ **所有锚点点击全被拒** ⇒ App 一步都走不动。
        // ⇒ ✅ 正解：**登录闸只作用于"肯定项/动作按钮"**（登录按钮只可能出现在这里）。
        //   页面锚点走别的防线（页面识别本身就不会把「登录」当锚点）。
        //
        // ## 📏 与授权腿**不冲突**（这正是用户口径的落地）
        // ```
        //   「想要打开 X」 / 「同意」/「打开」/「允许」 ⇒ 不含「登录」 ⇒ 照点 ✅
        //   「同意并登录」/「一键登录」/「本机号码一键登录」 ⇒ 含「登录」 ⇒ 拦 ⛔
        // ```
        if Self.loginGuardedElements.contains(name),
           let bad = FeatureEngine.forbidden(h.evidence,
                                             loginKeys: cfg.settings?.login_keys) {
            log("   §tap ⛔ **拒绝点击「\(name)」**：文案「\(h.evidence.prefix(24))」"
                + "命中红线词「\(bad)」（§2921 用户令：同意授权，⛔ 不点登录）")
            return false
        }
        if atomic {
            let cmd = BLEController.atomicClickCmd(x: Double(c.x), y: Double(c.y),
                                                   baseW: baseW, baseH: baseH, yFix: yFix)
            log("   §tap ★点「\(name)」@(\(Int(c.x)),\(Int(c.y))) score=\(String(format: "%.3f", h.score))"
                + " ev=\(h.evidence.prefix(28)) ⇒ \(cmd)")
            let ok = ble.send(cmd)
            if !ok { log("   §tap ⛔ BLE 发送失败：\(ble.lastError)") }
            Thread.sleep(forTimeInterval: Self.tapAfterSettle)
            // ⭐⭐⭐ §2972 **如实返回 BLE 的结果**（⛔ 不再无条件 true）
            //   照 MaaFW `Actuator::click()`：`success = controller()->click()` —— **原样透传**，⛔ 不吞。
            //   ⛔ 原来 `return true` ⇒ BLE 丢包时腿**实际没出手**却报"出手了"
            //      ⇒ 调用方（返回梯 §2971）判"出手了但画面没变" ⇒ **冤杀这条腿**。
            return ok
        }
        // ⭐⭐⭐ §2600 **两步式**：`P:` + `D:`（原地长按 600ms）
        //
        // ## ⛔⛔ 原来是 `P:` + `C:L`，**点不动**（用户当场看到的现象）
        // > 「看你哪个失败的点击命令 就是**圆点一直显示在那里**。这就是和别的点击命令最大的区别。」
        // ⇒ 圆点不消失 = HID 的**抬起事件被 iOS 丢弃** = 手指还按着 ⇒ 按钮只高亮不触发。
        // 📏 库源码 `clickAbs` 的注释亲口说：`同坐标的重复报告会被 iOS 整个丢弃`
        //   而 `C:L` 的按下帧与抬起帧**坐标完全相同** ⇒ 抬起被丢。
        // ✅ 改用 `D:`（`swipeAbs`）—— 按下后保持 14 帧插值移动 ⇒ 抬起帧形态不同 ⇒ 被消费。
        //
        // ⚠️ 时序：`moveAndClick` 返回 `["P:…", "D:…,600"]`。第 1 条后要等库内 8 帧插值走完（~48ms，
        //    这里给 0.15s）；第 2 条是 600ms 按压 ⇒ 等 0.9s 再往下走。
        let cmds = BLEController.moveAndClick(x: Double(c.x), y: Double(c.y),
                                              baseW: baseW, baseH: baseH, yFix: yFix)
        log("   §tap ★点「\(name)」@(\(Int(c.x)),\(Int(c.y))) score=\(String(format: "%.3f", h.score))"
            + " ev=\(h.evidence.prefix(28)) ⇒ \(cmds.joined(separator: " + "))")
        var allOk = true     // ⭐ §2972 见下（两步式：两条都发出去了才算"出手"）
        for (i, cmd) in cmds.enumerated() {
            let ok = ble.send(cmd)
            if !ok { log("   §tap ⛔ BLE 发送失败（\(cmd)）：\(ble.lastError)") }
            allOk = allOk && ok
            Thread.sleep(forTimeInterval: i == 0 ? Self.tapMoveSettle : 0.9)
        }
        // ⭐⭐⭐ §2972 如实返回（两步式要**两条都发出去**才算出手）—— 见上面 atomic 分支的说明
        return allOk
    }

    /// ⭐ **按坐标直接点**（坐标来自别处，如 OCR 词中心）
    /// ⭐⭐ **按坐标直接点**（坐标来自识别结果，如 OCR 词中心）
    ///
    /// # ⛔⛔⛔ §2600 **这里就是「领福利点不动」的现场**
    /// 用户当场抓到的现象（逐字）：
    /// > 「**看你哪个失败的点击命令 就是圆点一直显示在那里。**」
    /// > 「**别的都能点击 就你这个不行。**」
    /// ⇒ 圆点 = iOS 的蓝牙鼠标光标，**一直停着不消失** = HID 的**抬起没被消费** =
    ///   iOS 认为手指还按着 ⇒ 按钮**只高亮、从不触发**。
    ///
    /// 📏 修法见 `BLEController.moveAndClick` 的 §2600 注释（已从 `C:L` 改成 `D:` 长按）。
    /// ⚠️ 时序：第 1 条 `P:` 后等 0.15s（库内 8 帧插值 ≈48ms），第 2 条 `D:` 是 600ms 按压 ⇒ 等 0.9s。
    @discardableResult
    func tapPoint(_ x: Double, _ y: Double, atomic: Bool = false, why: String = "") -> Bool {
        // ⭐⭐⭐⭐⭐ §2841 **按坐标点也必须打日志**（用户令：「每次操作都要有日志」）
        //   坐标来自识别结果（OCR 词中心 / 色彩块），⛔ 没有"元素名"可打 ⇒
        //   所以带一个 `why` 标签，把"为什么点这里"写进去（⛔ 否则事后无法追溯）。
        let tag = why.isEmpty ? "" : "（\(why)）"
        if atomic {
            let cmd = BLEController.atomicClickCmd(x: x, y: y,
                                                   baseW: baseW, baseH: baseH, yFix: yFix)
            log("   §tapPoint ★点坐标\(tag) @(\(Int(x)),\(Int(y))) ⇒ \(cmd)")
            let ok = ble.send(cmd)
            if !ok { log("   §tapPoint ⛔ BLE 发送失败：\(ble.lastError)") }
            Thread.sleep(forTimeInterval: Self.tapAfterSettle)
            // ⭐⭐⭐ §2972 如实返回 BLE 结果（与 `tap` 同一口径）—— 见 `tap` 里的说明
            return ok
        }
        let cmds = BLEController.moveAndClick(x: x, y: y,
                                              baseW: baseW, baseH: baseH, yFix: yFix)
        log("   §tapPoint ★点坐标\(tag) @(\(Int(x)),\(Int(y))) ⇒ \(cmds.joined(separator: " + "))")
        var allOk = true
        for (i, cmd) in cmds.enumerated() {
            let ok = ble.send(cmd)
            if !ok { log("   §tapPoint ⛔ BLE 发送失败（\(cmd)）：\(ble.lastError)") }
            allOk = allOk && ok
            Thread.sleep(forTimeInterval: i == 0 ? Self.tapMoveSettle : 0.9)
        }
        return allOk
    }

    /// ⭐⭐ **iOS 左边缘右滑返回**（`B:` 固件专用命令）—— 沉浸式页面唯一出路
    ///
    /// ## 为什么必须有（§2253 对齐电脑端）
    /// 固件 `B[:y]` 源码注释（`_1377_ad_loop.py` 里也引过）：
    /// > 「★新增(§1372)：iOS **返回手势**(左边缘右滑)、广告转化浏览滑动、
    /// >   直播间换间都要用它」
    ///
    /// 📏 血案（电脑端 `_note_1377b`）：**沉浸式直播间/全屏视频整页没有 `〈`、没有 `✕`**
    ///    —— 点任何按钮都没用，**只有这条系统手势能出来**。
    ///
    /// ⛔ 与 `back_arrow` 的区别：
    ///   · `back_arrow` = **点**左上角那个 `〈` 图（需要它存在）
    ///   · `back_edge`  = **滑**（系统手势，不依赖任何可见按钮）
    @discardableResult
    func backEdge() -> Bool {
        let cmd = BLEController.backGestureCmd()
        // ⭐ §2841 先打日志再发（照 `cmd()`：每条命令都要留痕）
        log("   §gesture ★左边缘右滑返回 ⇒ \(cmd)")
        let ok = ble.send(cmd)
        if !ok { log("   §gesture ⛔ BLE 发送失败：\(ble.lastError)") }
        Thread.sleep(forTimeInterval: 1.0)
        // ⭐⭐⭐ §2972 如实返回 BLE 结果（与 `tap` 同一口径）
        //   ⛔ 原来 `return true` ⇒ k=5 那条腿 BLE 断了也报"出手了"
        //      ⇒ 调用方判"出手了但画面没变" ⇒ 冤杀（§2971 血案的同族）
        return ok
    }

    /// ⭐⭐⭐ **点「红包/金币」悬浮球**（回金币中心的**唯一入口**）
    ///
    /// ## 为什么必须有它（§2256 实测卡点）
    /// 手机端跑到 adbox 第一步「回金币中心」就卡死（trace 铁证）：
    /// ```
    /// §adbox_boot ⚠️ 在 unknown 找不到回中心的路（第 1 步）…（8 步全废）
    /// ```
    /// **根因**：悬浮球是**纯图形、没有文字** ⇒ **OCR 认不出**。
    ///
    /// ✅ 用 PC 的**色彩判据**（`find_coin_entry`，全量 1706 帧验证：
    ///    POS 12/12 命中、NEG 1694 帧 0 命中）。
    ///
    /// ⛔ 铁律②：**找不到就不点**（返回 false，调用方什么都不做）。
    @discardableResult
    func tapCoinBall(img: UIImage) -> Bool {
        guard let c = ColorBlob.findCoinBall(img) else {
            log("   §coin 没找到红包悬浮球（⛔ 不盲点）")
            return false
        }
        log("   §coin 找到红包球 @(\(Int(c.x)),\(Int(c.y))) ⇒ 点击")
        tapPoint(Double(c.x), Double(c.y), why: "红包悬浮球（色彩判据）")
        return true
    }

    // MARK: - 漏斗（② 步）

    func runFunnel(_ img: UIImage) -> Bool {
        guard let items = cfg.funnel else { return false }
        let now = Date()
        for it in items {
            if let last = funnelLast[it.element],
               now.timeIntervalSince(last) < (it.interval ?? 1.0) { continue }
            // ⭐⭐ **前置闸**（§2247）：必须**同时命中** `require` 才允许点 `element`
            //
            // 为什么（照抄 PC `dismiss_sys_prompt` 的两级设计）：
            //   「点哪个」与「凭什么认为是弹窗」是**两件事**。
            //   · 系统弹窗的**形态判据** = 按钮行同时有「不允许」+「允许」
            //   · 命中后才去点**消极项**（不允许/取消/拒绝/以后）
            // ⛔ 若只看 `element`：普通页面出现「取消」二字就会**误点**。
            if let req = it.require, detect(req, img: img) == nil {
                continue
            }

            // ⭐⭐⭐ **色彩判据类恢复腿**（`coin_ball`）—— ⛔ 它不是 OCR/模板元素
            //
            // 照 PC `_1377_ad_loop.py:2479`：PC 把 `coin_ball` 当**恢复腿**用
            // （「走 coin_ball ⇒ 兜底『切首页』」）。
            // 它由 `ColorBlob.findCoinBall` 的**红色块判据**决定，
            // 所以**不能**走 `detect()`（那查的是 `elements` 表）。
            if it.element == "coin_ball" {
                if let c = ColorBlob.findCoinBall(img) {
                    funnelLast[it.element] = now
                    log("   §funnel coin_ball（\(it.desc ?? "")）@(\(Int(c.x)),\(Int(c.y)))")
                    tapPoint(Double(c.x), Double(c.y), why: "漏斗 coin_ball")
                    return true
                }
                continue
            }

            // ⭐⭐⭐⭐⭐ §2314 **通用模态弹窗 ✕（`ModalX`）—— 它一直是死代码，现在接上**
            //
            // ## ⛔ 真机审计发现的漏洞（本轮）
            // `ModalX.swift` 逐字移植了 PC 的 `find_gray_x`（暖灰圆钮 ✕，
            // 阈值与紧凑度闸都是 PC 真机标定的），
            // **但全项目 0 个引用** —— 它从来没被调用过。
            // 而 PC 把这条判据当**主路**（`B2C_LEGS` 里的 `modal_x`，`_1377:3489`），
            // 用它提代了一堆每弹窗一块 png 的打补丁做法（用户原话：
            // 「**加你麻痹的补丁 闸口**」）。
            // ⇒ iOS 缺这条腿，意味着**没有任何“通用”的弹窗出路**，
            //   只能靠一个个命名模板 ⇒ 换版式就卡死。
            //
            // ⛔ 安全性：原地方只在**前置闸命中时**才跑（即 `require` 非空且命中），
            //   所以不会在普通页面上乱点 ✕；且仍然只认“暖灰圆钮”这一个形态。
            if it.element == "modal_x" {
                if let c = ModalX.find(img) {
                    funnelLast[it.element] = now
                    log("   §funnel modal_x（通用暖灰圆钮 ✕）@(\(Int(c.x)),\(Int(c.y)))")
                    tapPoint(Double(c.x), Double(c.y), why: "漏斗 modal_x 暖灰圆钮")
                    return true
                }
                continue
            }
            // ⭐⭐⭐⭐⭐ §2316 **底部弹窗（亮度闸 + 消极项按钮 OCR）—— 用户令**
            //
            // ## 用户原话（逐字）
            // > 「**这种页面弹窗你就点击一下就行了啊 看弹窗亮度分析就行了**」
            //
            // ## ⛔ PC 记下的两次失败（⛔ 别再犯）
            // v1「下半屏连续全宽纯白」 ⇒ **误判 4/6**（草稿箱/商城/结果页本来就是白底）
            // v2「白卡片顶边一行跃变」 ⇒ **误判 5/6**
            // ⇒ 根因：**“白”不是弹窗的特征**（快手很多页本来就白底）
            // ✅ 本机实测双信号区分度 **6/6 零误判**：
            //    ① 亮度闸（下半屏中段有 12+ 行纯白 >=240）
            //    ② OCR 闸（底部出现**消极项**文案：我知道了/取消/以后再说…）
            //    两者 **AND** ⇒ 误报率相乘。点哪里：用 **OCR 给的坐标**（比亮度推算准）。
            // ⛔ 铁律④：**只点消极项**，⛔ 不点右侧主按钮（词表故意只收消极项）。
            if it.element == "bottom_popup" {
                if let hit = Self.findBottomPopup(img, rec: rec, bw: baseW) {
                    funnelLast[it.element] = now
                    log("   §funnel bottom_popup（底部弹窗 “\(hit.tag)”）@(\(Int(hit.x)),\(Int(hit.y)))")
                    tapPoint(Double(hit.x), Double(hit.y), why: "漏斗 bottom_popup 消极项「\(hit.tag)」")
                    return true
                }
                continue
            }
            // ⭐⭐⭐⭐⭐ §2442 **App Store 安装页左上的 ✕**（移植 PC `find_appstore_x`）
            //
            // ## ⛔ 手机端原来**没有这条腿**（`_dev/_2440_port_diff.py` 对照出来的差集）
            // 点广告 CTA「立即下载」后 iOS 会弹 **App Store 商品 sheet**
            // （真机 `_var/_stuck2.png`：上面有「打开 / 获取 / 更多来自…的 App」）。
            // ⛔ 那不是快手的页面 ⇒ `pageHere` 判 unknown ⇒ 旧行为反复点 `〈`(26,61)
            //   **点不中**（那页的 ✕ 在 (43,110)）⇒ 空转十几步（我实测过）。
            //
            // ## PC 的判据（`_1377_ad_loop.py:1507 find_appstore_x`，**逐字读出来的**）
            // ```python
            // def find_appstore_x(img):
            //     # ① X_REFS 模板块逐像素 MAE 比对（§1638，MAE ≤ X_MAE）
            //     for _name, _fx, _fy, _desc in X_REFS: ...
            //     if not hits:
            //         # ② §1718 暗色交叉字形兜底（§1689 的几何判据，极性翻成暗色）
            //         _d = _find_cross_x(img, roi=_roi, thr=100, dark=True)
            //         if _d: return _d
            //         return None
            // ```
            //
            // ⛔⛔⛔ §2624 **删掉 `looksLikeAppStorePage` 这道闸 —— 它是我自造的组合，PC 里没有**
            //
            // ## 用户令（逐字）
            // > 「**你搞的什么狗屎代码 还是一样 会乱点**」
            //
            // ## ⛔ 血案（真机 trace + 像素实测，本轮）
            // 我在漏斗里写成 `if looksLikeAppStorePage(img) && findDarkCross(img)`，
            // 而 **PC 的 `find_appstore_x` 根本不用蓝像素闸**。
            // ⇒ 消息页**左上有蓝色头像**（离线实测：`BOX_DONE_BLUE` 那一带
            //    **603 个蓝像素**，远超阈值 100）⇒ 闸门恒真
            // ⇒ 再叠上 `findDarkCross` 的宽松几何判据 ⇒ 在消息页上点 `(31,82)`
            // ⇒ trace 逐字：`§funnel appstore_x @(31,82)` **连点 6 次**
            //    （用户看到的「乱点」）。
            //
            // 📏 真机两帧对照（`_dev` 离线复算）：
            // ``` 
            //   消息页 _2624_live.jpg  ⇒ 蓝像素 603 ⇒ 旧写法过闸 ⛔（就是乱点根源）
            //   真 feed _2613_s3_feed.jpg ⇒ 蓝像素 0   ⇒ 不过闸
            // ```
            // ⚠️ PC 的 `is_appstore_page`（蓝像素）**只用在安装链路**（L8767：
            //    「形状腿**必须有页面闸**」——防 `find_cloud` 的形状判据误报 29%），
            //    **⛔ 不是用来"关 ✕"的**。把两处混用就是我这个 bug。
            //
            // ✅ 现在 = PC 的口径：**只用 `findDarkCross`**（它本身内含 PC §1689 的
            //    几何判据：近正方 / 尺寸 8~30 / 孤立 / 每行段数≤2 / 填充率 0.15~0.75），
            //    ⛔ 不再叠加蓝像素闸。
            if it.element == "appstore_x" {
                if let p = Self.findDarkCross(img) {
                    funnelLast[it.element] = now
                    log("   §funnel appstore_x（App Store 页左上暗色 ✕）@(\(Int(p.x)),\(Int(p.y)))")
                    tapPoint(Double(p.x), Double(p.y), why: "漏斗 appstore_x 暗色 ✕")
                    return true
                }
                continue
            }
            // ⭐ 券弹窗 ✕（PC `find_coupon_x`，ROI 在屏幕中下）—— 同一个判据换 ROI
            if it.element == "coupon_x" {
                if let c = ModalX.findCoupon(img) {
                    funnelLast[it.element] = now
                    log("   §funnel coupon_x（券弹窗 ✕）@(\(Int(c.x)),\(Int(c.y)))")
                    tapPoint(Double(c.x), Double(c.y), why: "漏斗 coupon_x 券弹窗 ✕")
                    return true
                }
                continue
            }

            // ⭐⭐⭐⭐⭐ §2921 **协议同意腿**（用户令：「同意授权但是登录 不登陆」）
            //
            // ## ⛔ 为什么不能走元素表（真机验证逮到的 bug）
            // 元宝那帧的 OCR 是两个块：`'同意'@(296..330)` 与 `'不同意'@(110..165)`。
            // 而 `findWords` 的匹配是「按词表顺序，命中第一个就 break」⇒
            //   `"不同意".contains("同意")` = **true** ⇒ 两块被**并成一个框**，
            //   中心落在**两钮中间**；且 `min_hits=2` 永远不成立 ⇒ 腿不触发。
            // 📏 实测：`consent_dialog hit=False` 而 `consent_allow hit=True ev=不同意/同意`。
            // ⇒ ✅ 改用专用判据 `findConsentAllow`（照 `findBottomPopup` 的同一套做法）：
            //    先排除「不同意」，再找**整词等于**「同意/我同意/接受」的那一枚。
            //
            // ## ⛔ 闸 = `consent_dialog`（「同意」+「不同意」同现）
            // ⇒ 只在**协议弹窗**上出手；⛔ 不碰权限弹窗（那走 `sys_prompt_deny` 点消极项）。
            if it.element == "consent_allow" {
                if detect("consent_dialog", img: img) != nil,
                   let hit = FeatureEngine.findConsentAllow(img, rec: rec, bw: baseW,
                                                            loginKeys: cfg.settings?.login_keys) {
                    funnelLast[it.element] = now
                    log("   §funnel consent_allow（协议弹窗 ⇒ **同意**）「\(hit.tag)」"
                        + "@(\(Int(hit.x)),\(Int(hit.y)))（用户令：同意授权，⛔ 登录不点）")
                    tapPoint(hit.x, hit.y, why: "协议弹窗肯定项「\(hit.tag)」")
                    return true
                }
                continue
            }

            if detect(it.element, img: img) != nil {
                funnelLast[it.element] = now
                // ⭐⭐ **漏斗一律用原子点击**（`Q:x,y`）—— 照电脑端 `_ext_q` 的语义
                //
                // 为什么：漏斗处理的都是**弹窗/盖屏**（系统权限框、券弹窗、挽留面板…），
                //   这类东西**时序敏感**：`P:` 与 `C:L` 之间若被抢断，指针可能已不在按钮上。
                //   原子序列「移+按+放」一条发出 ⇒ **不可能被拆开**。
                let isSys = it.element.hasPrefix("sys_prompt")
                log("   §funnel \(it.element)（\(it.desc ?? "")）"
                    + (it.require != nil ? " [闸:\(it.require!)]" : "")
                    + (isSys ? " [系统弹窗 ⇒ 原子点击]" : ""))
                return tap(it.element, img: img, atomic: true)
            }
        }
        return false
    }


    // MARK: - ⭐⭐ 底部弹窗（亮度闸 + 消极项按钮 OCR）

    /// ⭐⭐⭐ 底部弹窗两级判据 —— 逐字照 PC `find_bottom_popup`（`_1377_ad_loop.py:5391）。
    ///
    /// ## 为什么是“亮度 + OCR”两级（而不是只看亮度）
    /// PC 注释里记了它自己的两次失败：
    /// ```
    ///   v1「下半屏连续全宽纯白」 ⇒ 误判 4/6（草稿箱/商城/结果页本来就白底）
    ///   v2「白卡片顶边一行跃变」 ⇒ 误判 5/6
    /// ```
    /// ⇒ 根因：**“白”不是弹窗的特征**。只能当“宽泛闸”。
    /// ✅ 双信号 **AND** ⇒ 区分度 6/6 零误判（PC 本机实测）。
    ///
    /// - Returns: 命中则返回消极项按钮的**基准像素**中心与文案；否则 nil（⛔ 不放枪）。
    static func findBottomPopup(_ img: UIImage, rec: Recognizer, bw: Double)
        -> (x: Double, y: Double, tag: String)? {
        // ── ① 亮度闸（宽泛）：下半屏**中段**存在“白卡片” ──
        //    ⛔ 只看中段 x ∈ [0.35W, 0.65W]（避开左右边缘的圆角/阴影）
        let base = FrameNormalizer.normalize(img)
        guard let g = rec.gray(base) else { return nil }
        let H = g.h, W = g.w
        let x0 = Int(Double(W) * 0.35), x1 = Int(Double(W) * 0.65)
        guard x1 > x0, H > 10 else { return nil }
        var whiteRows = 0
        let yFrom = Int(Double(H) * 0.45)
        for y in yFrom..<H {
            var sum = 0
            for x in x0..<x1 { sum += Int(g.p[y * W + x]) }
            let mean = Double(sum) / Double(max(1, x1 - x0))
            if mean >= 240 { whiteRows += 1 }      // PC POPUP_WHITE = 240
        }
        if whiteRows < 12 { return nil }           // PC POPUP_MIN_ROWS = 12
        // ── ② OCR 闸（严）：底部出现**消极项**文案 ──
        //    PC 只认下半屏 y >= 0.82H 那一带
        let band = CGRect(x: 0, y: Double(H) * 0.82, width: bw, height: Double(H) * 0.18)
        let ws = rec.ocrRegion(base, rect: band, minConfidence: 0.3)
        var best: (Double, Double, String)?
        for (t, r, _c) in ws {
            let s = t.trimmingCharacters(in: .whitespaces)
            // ⛔ 词表故意**只收消极项**（照 PC POPUP_BTN_KEYS）：
            //    “设置提示音/立即开通/去开启”这类**主按钮绝不能进来**
            let keys = ["我知道了", "知道了", "取消", "以后再说", "暂不", "暂不开启",
                        "跳过", "下次再说", "不再提示", "关闭"]
            if keys.contains(where: { s.contains($0) }) {
                // 取**最靠下**那个（弹窗按钮在最底部）
                if best == nil || r.midY > best!.1 {
                    best = (Double(r.midX), Double(r.midY), s)
                }
            }
        }
        guard let b = best else { return nil }
        return (b.0, b.1, b.2)
    }

    // MARK: - 到目的地（①②③④ 主循环）

    /// ⭐⭐⭐ **本轮的「记死」集合**（§2247 移植 PC `_dead` 机制）。
    ///
    /// ## 为什么必须有（真机实测的死循环）
    /// 配置里 `feed.go = "tab_home"`，而 **feed 页本身就等于首页** ⇒
    /// 点它**没有任何效果** ⇒ 下一帧还是 feed ⇒ 再点 ⇒ **原地打转**。
    /// 真机 trace 铁证（`run_trace.log`）：
    /// ```
    /// §click tab_home @(45,911) score=1.000 ev=首页
    /// §click tab_home @(44,911) score=1.000 ev=首页     ← 连续 6 次，同一个点
    /// …（每 2 秒一次，无限）
    /// ```
    ///
    /// ## 为什么「卡死检测」拦不住
    /// `Runner` 用 16×32 灰度指纹比画面 —— 但**快手信息流有视频在播**，
    /// 每帧指纹都不同 ⇒ `stall` 永远不涨 ⇒ 卡死检测**对动画页失效**。
    ///
    /// ## PC 的解法（照抄，`_1377_ad_loop.py::_nav_to_center`）
    /// ```
    /// _dead = set()                      # 记死「(页, 出路)」组合
    /// …
    /// _pre = grab()
    /// if _nav_act(_go):
    ///     _post = grab()
    ///     if not did_screen_change(_pre, _post, roi=(0,55,451,300)):
    ///         _dead.add((_here, _go))     # ⭐ 点了画面没变 ⇒ 这条腿无效 ⇒ 记死
    /// ```
    /// ⇒ 关键两点：
    ///   ① 比的是**「点前 vs 点后」**（ROI 只看上半屏，避开视频区）
    ///   ② 记死的是 **(页型, 出路)** 组合 ⇒ 换一页还能用同一条腿
    private var dead: Set<String> = []

    /// 记死一条腿（key = "页型|出路"）
    private func markDead(_ page: String, _ go: String) {
        dead.insert("\(page)|\(go)")
    }
    private func isDead(_ page: String, _ go: String) -> Bool {
        dead.contains("\(page)|\(go)")
    }
    /// 清空记死（换目标/重开一轮时调用）
    func resetDead() { dead.removeAll() }

    /// ⭐ 画面有没有变（只看**上半屏 ROI**，避开视频区）
    ///
    /// ⚠️ 为什么限定 ROI（PC 原文）：
    /// > 抄 MaaFW `wait_freezes`：画面没变 ⇒ 这条腿无效 ⇒ 记死
    /// 全屏比会**因为视频帧变化而永远\"有变化\"** ⇒ 必须只看页面结构区。
    func screenChanged(_ a: UIImage, _ b: UIImage,
                       roi: CGRect? = nil) -> Bool {
        let r = roi ?? CGRect(x: 0, y: 0, width: baseW, height: baseH * 0.5)
        let t1 = thumb(a, roi: r), t2 = thumb(b, roi: r)
        guard let x = t1, let y = t2, x.count == y.count else { return true }
        var diff = 0
        for i in 0..<x.count where abs(Int(x[i]) - Int(y[i])) > 18 { diff += 1 }
        // >2% 像素明显变化 ⇒ 认为变了（阈值抄 PC 的 did_screen_change 语义）
        return Double(diff) / Double(x.count) > 0.02
    }

    /// 取 ROI 的 24×24 灰度缩略图（判「变没变」够用）
    private func thumb(_ img: UIImage, roi: CGRect) -> [UInt8]? {
        let W = 24, H = 24
        guard let cg = img.cgImage else { return nil }
        var buf = [UInt8](repeating: 0, count: W * H)
        guard let ctx = CGContext(data: &buf, width: W, height: H,
                                  bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // 把 ROI 映射到图像像素
        let sc = CGFloat(cg.width) / max(baseW, 1)
        let rect = CGRect(x: roi.minX * sc, y: roi.minY * sc,
                          width: roi.width * sc, height: roi.height * sc)
        guard let sub = cg.cropping(to: rect) else { return nil }
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: W, height: H))
        return buf
    }

    /// ⭐⭐ **走一步**（移植 PC `_nav_act` 的语义）：
    /// 从当前页按 `go` → `alts` 顺序选一条**没记死**的出路，
    /// 点完**再抓一帧**比一比；没变就**记死这条腿**。
    ///
    /// # ⛔⛔⛔ §2636 **每条腿都必须看"新帧"**（真机血案，本轮）
    ///
    /// ## 血案（真机日志，逐字）
    /// ```
    /// 23:25:13.775  §coin 没找到红包悬浮球 ⇒ 记死 coin_ball
    /// 23:25:13.812  §nav 想点 tab_featured 但没找到 ⇒ 记死
    /// 23:25:13.813  §adbox_boot ⛔ 在 feed 的出路全试过且无效 ⇒ **停手**
    /// ```
    /// ⇒ **37 毫秒内把两条腿全部记死** —— 因为它们判的是**同一张帧**。
    ///   而那一刻页面**可能只是还没画完**（转场中/球被遮挡/加载中）
    ///   ⇒ 一次误判就把本页的**所有出路**封死 ⇒ 直接停手（用户看到的"卡住"）。
    ///
    /// ## ✅ PC 的做法（`_1377_ad_loop.py:2690-2692`，逐字）
    /// ```python
    /// for k in range(steps):
    ///     # ⭐ 每轮**重新抓帧**（抄 Airtest：「每轮重新截图」—— 快手是视频流，画面一直在变）
    ///     if k > 0:
    ///         img = grab("%s_%d" % (tag, k))
    /// ```
    /// 📏 PC 的注释直接点明理由：**「快手是视频流，画面一直在变」**
    ///   ⇒ 用同一张帧去试所有腿，**结构上就是错的**（后试的腿看的是过期画面）。
    ///
    /// ⇒ 本函数现在**每条腿前都抓一张新帧**（`grab()` 由调用方注入；拿不到就退回入参那张）。
    ///   ⚠️ 这也让「记死」的语义回到 PC 的口径：记死的是"**这条腿在这张帧上没找到**"，
    ///      ⛔ 而不是"这条腿永远不行"。
    ///
    /// - Returns: (是否点了, 点了哪条腿, 画面是否真的变了)
    @discardableResult
    func step(from page: String, img: UIImage,
              grab: () -> UIImage?) -> (acted: Bool, go: String?, changed: Bool) {
        guard let p = cfg.pages[page] else { return (false, nil, false) }
        // ⭐ 主出路 + 备用出路（PC: `[go] + alts`）
        var cands: [String] = []
        if let g = p.go, g != "stop" { cands.append(g) }
        cands += (p.alts ?? [])

        for g in cands where !isDead(page, g) {
            // ① ⭐⭐⭐ §2636 **点之前抓一张"新帧"**（照 PC「每轮重新抓帧」）
            //    ⛔ 不是复用入参 `img` —— 那是**上一轮**的帧，用它试后面所有腿等于
            //      "拿过期画面判当前页面"（§2636 血案：37ms 内把两条腿全记死）。
            //    ⚠️ `grab()` 是新帧（它内部等 `lastFrameAge <= maxFrameAge`）；
            //      拿不到就退回入参那张（⛔ 不因此整页放弃）。
            let fresh = grab() ?? img
            let pre = fresh
            // ⭐ **手势/色彩类出路**（⛔ 不是"找到元素再点"，而是专门的动作）
            //    · `back_edge` = 左边缘右滑返回（B:）—— 沉浸式页面唯一出路
            //    · `coin_ball` = 点红包悬浮球（**色彩判据**，OCR 认不出它）
            let acted: Bool
            if g == "back_edge" {
                acted = backEdge()
            } else if g == "coin_ball" {
                acted = tapCoinBall(img: fresh)
            } else {
                acted = tap(g, img: fresh)
            }

            // ⭐⭐⭐⭐⭐ §2306 **直播间/视频类页面：「画面变了」不能当成功的判据**
            //
            // ## 真机血案（v0.10.43 实测 trace）
            // ```
            //   §gesture 左边缘右滑返回（B:）
            //   §nav 在 live ⇒ back_edge **有效**（画面已变）   ← ⛔ 反复了 20+ 次
            // ```
            // 而手机**始终停在直播间**。根因：
            //   直播间本身在**放视频** ⇒ 两帧永远不同
            //   ⇒ `screenChanged()` **恒 true** ⇒ 每条腿都被认为“有效” ⇒ **永远不会换下一条/不会判失败**
            //   ⇒ 卡死。
            // 📏 这正是 PC 记过的同一类坑（`_1377_ad_loop.py:9474`：
            //   “用连续两帧一模一样判页面渲染完”在动态画面上**不成立**）。
            //
            // ✅ 正解：对这类页型，判据要看“**目标页型是否真的消失了**”，
            //   ⛔ 不是看“画面有没有变”。
            let isMotionPage = (page == "live")
            if isMotionPage {
                let deadline2 = Date().addingTimeInterval(4.0)
                var leftPage = false
                while Date() < deadline2 {
                    Thread.sleep(forTimeInterval: 0.6)
                    guard let q = grab() else { break }
                    if detect("live_marker", img: q) == nil { leftPage = true; break }
                }
                if leftPage {
                    log("   §nav 在 \(page) ⇒ \(g) **有效**（已离开直播间）")
                    return (true, g, true)
                }
                log("   §nav 在 \(page) ⇒ \(g) **没离开**（仍命中 live_marker）⇒ 记死这条腿（⛔ 不重复）")
                markDead(page, g)
                continue
            }
            guard acted else {
                log("   §nav 在 \(page) 想点 \(g) 但**没找到** ⇒ 记死这条腿")
                markDead(page, g)
                continue
            }
            // ② 点之后再抓一帧，比「有没有变」
            //
            // ⛔⛔ §2265 **必须"等一帧新的"，⛔ 不是固定睡 1.2s 就去比**。
            //
            // ## 为什么（这是与写盘节拍**成对**的一条，漏了就必炸）
            // 为了活过 iOS 的写入预算，扩展的写盘节拍从 2fps 降到 **1帧/4s**（§2265）。
            // 而 `grab()` 在 4 秒窗口内返回的是**同一张帧** ⇒
            // `screenChanged(pre, post)` 等于**拿一张图跟自己比** ⇒ 恒 false
            // ⇒ 每条腿都被误判"做了画面没变" ⇒ **全被记死** ⇒ 一步都走不动。
            // 📏 这正是"改了 A 忘了 B"的典型 —— **节拍与判据必须成对调**。
            //
            // ✅ 修法：**轮询等一张真的不同的帧**（最多 `changeWait` 秒）。
            //   · 画面**真变了** ⇒ 新帧到了，比较立刻成立 ⇒ 早退（⛔ 不白等）
            //   · 画面**真没变** ⇒ 等满预算才判"没变"（结论仍正确）
            //   ⚠️ 这也让 2fps 的老配置照常工作：新帧 ~0.5s 就到，早退。
            let changeWait = max(1.2, (cfg.settings?.loop_frame_max_age ?? 7.0) + 1.5)
            let deadline = Date().addingTimeInterval(changeWait)
            let preSig = pre
            var changed = false
            var post: UIImage? = nil
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                guard let p = grab() else { break }
                post = p
                if screenChanged(preSig, p) { changed = true; break }
            }
            guard let finalPost = post else { return (true, g, true) }
            _ = finalPost
            if changed {
                log("   §nav 在 \(page) ⇒ \(g) **有效**（画面已变）")
                return (true, g, true)
            }
            log("   §nav 在 \(page) ⇒ \(g) **做了画面没变** ⇒ 记死（⛔ 不再重复）")
            markDead(page, g)
            // ⭐ 换下一条腿继续试（⛔ 不是整页放弃）
        }
        return (false, nil, false)
    }

    /// 走到目标页。`dest` = config 里的 page key；`img` 为当前帧。
    ///
    /// ⚠️ 本函数是**单帧**版（给 `/nav` 这类一次性调用用）。
    ///    真正的自主循环（会重抓帧 + 记死）在 `Runner` 里。
    @discardableResult
    func go(to dest: String, img: UIImage) -> Bool {
        let steps = cfg.settings?.max_steps ?? 12
        var cur = img
        for k in 0..<steps {
            // ① 到目的地了吗？
            if pageHere(cur) == dest {
                log("   §nav ✅ 已在 \(dest)（第 \(k + 1) 步）")
                return true
            }
            // ⛔ 广告页放行（用户令）
            if let ad = cfg.pages["ad_video"], let c = ad.check,
               c.allSatisfy({ detect($0, img: cur) != nil }) {
                log("   §nav ⛔ 这是广告页 ⇒ 放行（不碰，交给广告模块）")
                return false
            }
            // ② 恢复漏斗（弹窗盖屏优先）
            if runFunnel(cur) { return true }   // 处理一层就重抓（调用方循环）
            // ③ 页面图上前进一跳（⭐ 带记死）
            if let here = pageHere(cur) {
                let r = step(from: here, img: cur, grab: { cur })
                if r.acted { return true }
                log("   §nav 在 \(here) 的出路**全被记死** ⇒ 这一页没招了")
            }
            // ④ 停手（⛔ 不盲点）
            let here = pageHere(cur) ?? "unknown"
            log("   §nav ⛔ 认不出出路（\(here)）⇒ 停手（第 \(k + 1) 步）")
            return false
        }
        return false
    }

    // MARK: - ⭐⭐⭐ §2442 App Store 安装页的 ✕（移植 PC `find_appstore_x`）

    /// 照 PC `is_appstore_page`：左上「完成/打开」那一带是否够 **iOS 蓝**。
    ///
    /// PC 全量真帧标定（5071 帧）：App Store 模态页 = **289~290** 个蓝像素；**其它任何页面 = 0**。
    /// ⇒ 阈值取 **100**（两侧各留 ~3 倍余量）。
    /// ⚠️ 真机实测（`_dev/_2423_appstore_page.py`）：本机新版 iOS 只有 **25** 个蓝像素
    ///   ⇒ 100 会**漏判** ⇒ 这里放宽到 **15**。
    static func looksLikeAppStorePage(_ img: UIImage) -> Bool {
        guard let cg = img.cgImage, let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        // PC `BOX_DONE_BLUE = (0, 85, 140, 150)`
        let sx = Double(cg.width) / 451.0, sy = Double(cg.height) / 977.0
        let x1 = min(cg.width, Int(140 * sx)), y1 = min(cg.height, Int(150 * sy))
        let y0 = max(0, Int(85 * sy))
        var n = 0
        for y in y0..<y1 {
            for x in 0..<x1 {
                let o = y * bpr + x * bpp
                let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
                if b > 180 && r < 120 && g > 80 && g < 190 { n += 1 }
            }
        }
        return n >= 15
    }

    /// ⭐⭐⭐ 在左上一带找 App Store 页的**暗色交叉字形 ✕**。
    ///
    /// ## 逐条移植 PC `_find_cross_x(img, roi, thr=100, dark=True)`（`_1377_ad_loop.py:3825`）
    /// PC 的极性说明（必须照抄，⛔ 不能想当然）：
    /// > App Store 页左上的关闭 ✕ 是**黑色笔画 + 白色底**，与广告胶囊的**白色 ✕ + 暗底**
    /// > **极性完全相反** ⇒ 默认 `thr=225`（取亮像素）在这页上**一个亮像素都取不到** ⇒ 恒 None。
    /// > ✅ `dark=True` ⇒ 取**暗**像素，其余几何判据**一条不动**。
    ///
    /// ## 几何判据（PC §1689 逐像素量出的真值，⛔ 不是"觉得差不多"）
    /// ```
    ///   · 近正方：宽高比 0.6 ~ 1.7
    ///   · 尺寸 8~30 px
    ///   · 孤立：左右各空 ≥5 px
    ///   · 每行暗像素段数 ≤2（汉字有长横 ⇒ 被挡）
    ///   · 填充率 0.15 ~ 0.75
    /// ```
    /// ## 真机实测（`_dev/_2423_appstore_page.py`）
    /// 4 个锚点里 3 个命中同一位置 **(43,110)**，点它一击退出。
    static func findDarkCross(_ img: UIImage, thr: Int = 100) -> CGPoint? {
        // 照 PC `X_REFS` 的锚点（归一化），⛔ 不写死一个绝对坐标
        let anchors: [(Double, Double)] = [(0.093, 0.11), (0.093, 0.14),
                                           (0.093, 0.085), (0.10, 0.16)]
        for (fx, fy) in anchors {
            let cx0 = Int(fx * 451), cy0 = Int(fy * 977)
            let r = 30
            let roi = CGRect(x: max(0, cx0 - r), y: max(0, cy0 - r),
                             width: 2 * r, height: 2 * r)
            if let p = _findCrossIn(img, roi: roi, thr: thr) { return p }
        }
        return nil
    }

    private static func _findCrossIn(_ img: UIImage, roi: CGRect, thr: Int) -> CGPoint? {
        guard let cg = img.cgImage, let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        let sx = Double(cg.width) / 451.0, sy = Double(cg.height) / 977.0
        let x0 = max(0, Int(roi.minX * sx)), y0 = max(0, Int(roi.minY * sy))
        let x1 = min(cg.width, Int(roi.maxX * sx)), y1 = min(cg.height, Int(roi.maxY * sy))
        let W = x1 - x0, H = y1 - y0
        guard W > 10, H > 10 else { return nil }
        var seen = [Bool](repeating: false, count: W * H)
        func dark(_ x: Int, _ y: Int) -> Bool {
            let o = y * bpr + x * bpp
            let r = Int(ptr[o]), g = Int(ptr[o + 1]), b = Int(ptr[o + 2])
            return (299 * r + 587 * g + 114 * b) / 1000 <= thr
        }
        var best: (Int, Double, Double)?
        for yy in 0..<H {
            for xx in 0..<W where dark(x0 + xx, y0 + yy) && !seen[yy * W + xx] {
                var stack = [(xx, yy)]
                seen[yy * W + xx] = true
                var pix: [(Int, Int)] = []
                var minX = xx, maxX = xx, minY = yy, maxY = yy
                while let (cx, cy) = stack.popLast() {
                    pix.append((cx, cy))
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = cx + dx, ny = cy + dy
                            guard nx >= 0, nx < W, ny >= 0, ny < H,
                                  !seen[ny * W + nx], dark(x0 + nx, y0 + ny) else { continue }
                            seen[ny * W + nx] = true
                            stack.append((nx, ny))
                        }
                    }
                }
                guard pix.count >= 20 else { continue }
                let bw = maxX - minX + 1, bh = maxY - minY + 1
                guard bw >= 8, bw <= 30, bh >= 8, bh <= 30 else { continue }
                let ar = Double(bw) / Double(bh)
                guard ar >= 0.6, ar <= 1.7 else { continue }
                var ok = true
                for row in minY...maxY {
                    let xs = pix.filter { $0.1 == row }.map { $0.0 }.sorted()
                    if xs.isEmpty { continue }
                    var runs = 1
                    for i in 1..<xs.count where xs[i] != xs[i - 1] + 1 { runs += 1 }
                    if runs > 2 { ok = false; break }
                }
                guard ok else { continue }
                guard minX >= 5, (W - maxX) >= 5 else { continue }
                let fill = Double(pix.count) / Double(bw * bh)
                guard fill >= 0.15, fill <= 0.75 else { continue }
                let score = bw * bh
                if best == nil || score > best!.0 {
                    let bx = (Double(x0) + Double(minX + maxX) / 2.0) / sx
                    let by = (Double(y0) + Double(minY + maxY) / 2.0) / sy
                    best = (score, bx, by)
                }
            }
        }
        guard let b = best else { return nil }
        return CGPoint(x: b.1, y: b.2)
    }
}
