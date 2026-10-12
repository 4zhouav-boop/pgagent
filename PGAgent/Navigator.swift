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
    /// ⚠️ `ad_video` 是**孤岛**（`island:true`）⇒ 不参与"我在哪"（见下）
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
    func pageHere(_ img: UIImage) -> String? {
        // ① 先按显式优先级排；② 没在优先级表里的页型**排到最后**（新加的页型不会抢占）
        let names = cfg.pages.keys.sorted { a, b in
            let ia = Self.pageOrder.firstIndex(of: a) ?? Int.max
            let ib = Self.pageOrder.firstIndex(of: b) ?? Int.max
            return ia < ib
        }
        for pname in names {
            guard let p = cfg.pages[pname] else { continue }
            if p.island == true { continue }              // 孤岛页不参与"我在哪"
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

    // MARK: - ⭐⭐⭐⭐⭐ §2282 切到目标 App（**App 自己做**，全程 ESP32）

    /// 把前台切到 `kslite` / `ks` —— 照 PC `ensure_app`（`_1377_ad_loop.py:8508`）**逐字**。
    ///
    /// ## ⛔⛔ 为什么必须由 App 自己做（用户令）
    /// > 「**脚本启动都不会自动回桌面 自动进快手。**」
    /// > 「**我手动启动会打开录屏，然后点击启动后 他需要自动回桌面，然后自己进快手。**」
    ///
    /// 手机端录屏录的是**当前前台** ⇒ 点「开始跑」时前台是 PGAgent 自己 ⇒
    /// 录到控制台 ⇒ 全 `unknown`（真机并排 `_var/_d1_side.png` 铁证）。
    ///
    /// ## 两步（照 PC，⛔ 不用 `UIApplication.open`）
    /// ```
    /// ① 回主屏 = **底部快速上滑**（起点 y=971；120ms）
    ///     ⛔ `H:HOME` 是 ⌘H 键盘组合，**会被前台 App 吃掉**（PC 实测 0 像素）⇒ 只当兜底
    /// ② 点图标 = OCR 找标签 ⇒ 点**标签上方 0.055 屏高**（PC `FH(0.055)`）
    ///     ⛔ 一键不写死坐标（PC 换版式踩过坑）
    /// ```
    @discardableResult
    static func switchToApp(named which: String, rec: Recognizer, ble: BLEController,
                            frame: () -> UIImage?,
                            baseW: Double, baseH: Double, yFix: Double,
                            log: @escaping (String) -> Void) -> Bool {
        func hid(_ cmds: [String], gapUS: UInt32 = 130_000) {
            for c in cmds { _ = ble.send(c); usleep(gapUS) }
        }
        // ① ⭐⭐⭐ 回主屏 —— **逐字照抄 PC `go_home`（`_1377_ad_loop.py:7982`）**
        //
        // PC 原文：
        // ```
        //   cmd(dlog(HOME_FLING))        # 底部快速上滑 225,971 -> 225,300 / 120ms
        //   wait(1.4)
        //   img = grab()
        //   if is_homescreen(img): return True, img      # ⭐ 到了就返回，**不再补任何东西**
        //   cmd("H:HOME"); wait(1.8)                     # ⭐ 只有"不像桌面"才补 ⌘H
        // ```
        //
        // ## ⛔⛔ §2340 血案：我把 `H:HOME` 写成了**无条件**，这就是"进不去快手"的元凶
        // 我原来写的是：
        //     上滑 → sleep(2.0) → **无条件** hid(["H:HOME"]) → sleep(1.5) → 才抓帧
        // 后果（真机帧证，一帧一帧都对过）：
        //   · 上滑本身**已经**落到主桌面 —— `_var/_pg_L0.png` 上 OCR 亲测读到
        //       「快手极速版」base=(242,726) 点图标=(242,672)
        //       「快手」    base=(366,724) 点图标=(366,671)
        //     ⇒ **目标页就是这一页**，根本不需要翻页。
        //   · 紧跟的 ⌘H 又把它推走 ⇒ 变成**副桌面**
        //       `_var/_ks2_p3.png`：Soul / 头条 / 新氧 / 番茄小说 … **一个快手都没有**
        //   · 然后在**错的页面**上翻 4 页找 ⇒ 必然走到
        //       「⛔ 翻页也没找到 ⇒ 不放枪（铁律②）」
        // ⇒ 修法不是"少等一会儿"，而是**照 PC 把 ⌘H 变成条件分支**。
        log("   ① 回主屏（底部快速上滑 y=971 / 120ms，照 PC `go_home`）")
        hid([BLEController.swipe(x1: 225, y1: 971, x2: 225, y2: 300,
                                 speed: .fast, baseW: baseW, baseH: baseH, yFix: yFix)])
        Thread.sleep(forTimeInterval: 1.4)                     // PC `wait(1.4)`
        var deskImg = frame()                                  // ⭐ 上滑后**先拿新帧**
        if let im = deskImg, looksLikeDesktop(im, rec: rec, baseW: baseW, baseH: baseH) {
            log("   ★回主屏：**底部快速上滑**生效（已落到桌面）⇒ 就在这一帧上找图标")
        } else {
            log("   ①b 上滑后**不像桌面** ⇒ 补一发 `H:HOME`（⌘H 兜底，可能被 App 吃）")
            hid(["H:HOME\n"])
            Thread.sleep(forTimeInterval: 1.8)                 // PC `wait(1.8)`
            deskImg = frame()
        }

        // ⛔ §2284 **"等新帧"要按"时间"等，⛔ 不能按"画面变化"等**
        //
        // ## 真机血案（v0.10.42 实测）
        // ```
        //   15:46:18 ② 在桌面上找「kslite」图标
        //   15:46:19 ⚠️ 第一页没找到（或拿不到帧）⇒ 左滑翻页再找
        //   15:47:24 ⛔ 翻页也没找到        ← ⛔ **卡了 65 秒**（4 轮 × 8s 等待 + 翻页）
        // ```
        // ## 根因（我自己造的）
        // 我写的 `waitFresh` 等的是「**画面与参考帧不同**」——
        // ⛔ 可**桌面本来就是静止的**（没有视频、没有动效）⇒ 两帧当然一样
        // ⇒ `waitFresh` **每轮都等到 8 秒超时** ⇒ 4 轮 = 32 秒 + 翻页 ⇒ 全废。
        // 📏 这正是 PC 记过的坑（`_1377_ad_loop.py:9474`）：
        // > 本来想用「连续两帧一模一样」判"页面渲染完了"，但**实测不成立** ——
        // > 投屏流是**有损压缩** + 页面自带**动效** ⇒ 两者**量级重叠**。
        // > ⇒ 老实承认它等价于"**固定多等 3.2s 让页面渲染**"。
        //
        // ✅ 正解：**按时间等**（固定睡一会儿让新帧写进来），⛔ 不按"变化"等。
        func waitFrame(maxSec: Double = 3) -> UIImage? {
            let t0 = Date()
            var im: UIImage?
            while Date().timeIntervalSince(t0) < maxSec {
                if let f = frame() { im = f; break }
                Thread.sleep(forTimeInterval: 0.4)
            }
            // 再睡半拍，让"动作产生的新帧"写进来（录屏 1fps）
            Thread.sleep(forTimeInterval: 1.2)
            return frame() ?? im
        }

        // ② ⭐ OCR 找图标标签 ⇒ 点标签上方
        //    照 PC `find_desktop_icon`（L7856）的三条**排除闸**（⛔ 不照抄会把弹窗句子当图标）
        //    真机血案 `_var/_1755_stab_{1..4}.log`：iOS 弹「"快手"想访问相机。」（整句含"快手"）
        //      ⇒ 旧判据把它当图标 ⇒ **点了 8 次弹窗、4/4 全废**。
        func findIcon(_ img: UIImage) -> (CGPoint, String)? {
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
            return (CGPoint(x: pick.0.x, y: pick.0.y - baseH * 0.055), pick.1)
        }

        log("   ② 在桌面上找「\(which)」图标（OCR 标签 → 点标签上方 0.055 屏高）")
        // ⭐⭐⭐ 照 PC `find_desktop_icon_paged`（L8001）的**顺序**：
        // ```
        //   img = grab("..._desk0")            # ⭐ 拿"回主屏之后"那一帧
        //   p = find_desktop_icon(img, which)  # ⭐ 先在**这一帧**上找（快手就在第 1 页）
        //   if p: return img, p                #    找到就用它自己算的坐标
        //   ... 找不到才翻页（先右滑 6 次，再左滑 8 次）
        // ```
        // ⛔ §2340 血案：我原来「当页找不到 ⇒ 直接左滑翻页」，而翻的是 **⌘H 推走后的错页**。
        // ✅ 现在**在回主屏那一帧上直接找**：真机帧 `_var/_pg_L0.png` 上 OCR 亲测就有
        //    「快手极速版」(242,726) / 「快手」(366,724) ⇒ 命中即点，**根本不翻页**。
        let page0 = deskImg ?? waitFrame()
        if let img = page0, let (pt, label) = findIcon(img) {
            log("      ✅ 回主屏当页命中「\(label)」⇒ 点 (\(Int(pt.x)),\(Int(pt.y)))")
            hid(BLEController.moveAndClick(x: Double(pt.x), y: Double(pt.y),
                                           baseW: baseW, baseH: baseH, yFix: yFix))
            Thread.sleep(forTimeInterval: 6.0)      // 照 PC `wait(6.5)`
            return true
        }
        // ⛔ 安全闸（照 PC）：不像桌面就**不翻页**（否则会在 App 里乱滑）
        if let img = page0 ?? frame(), !looksLikeDesktop(img, rec: rec, baseW: baseW, baseH: baseH) {
            log("      ⛔ 这一页**不像 iOS 桌面** ⇒ **不翻页**（照 PC，免得在 App 里乱滑）")
            return false
        }
        log("      ⚠️ 当页没找到 ⇒ 才开始翻页（照 PC：**先右滑 6 次回退，再左滑 8 次前进**）")
        // ③ **先右滑回退**（第 1 页在最左端；照 PC `for k in range(back)`，back=6）
        var tried = 0
        for k in 1...6 {
            hid([BLEController.swipe(x1: 60, y1: 500, x2: 380, y2: 500,
                                     speed: .mid, baseW: baseW, baseH: baseH, yFix: yFix)])
            Thread.sleep(forTimeInterval: 1.2)                 // 照 PC `wait(1.2)`
            tried += 1
            if let img = waitFrame(), let (pt, label) = findIcon(img) {
                log("      ✅ 右滑第 \(k) 次命中「\(label)」⇒ 点 (\(Int(pt.x)),\(Int(pt.y)))")
                hid(BLEController.moveAndClick(x: Double(pt.x), y: Double(pt.y),
                                               baseW: baseW, baseH: baseH, yFix: yFix))
                Thread.sleep(forTimeInterval: 6.0)
                return true
            }
        }
        // ④ **再左滑前进**（照 PC `for k in range(fwd)`，fwd=8）
        for k in 1...8 {
            hid([BLEController.swipe(x1: 380, y1: 500, x2: 60, y2: 500,
                                     speed: .mid, baseW: baseW, baseH: baseH, yFix: yFix)])
            Thread.sleep(forTimeInterval: 1.2)
            tried += 1
            if let img = waitFrame(), let (pt, label) = findIcon(img) {
                log("      ✅ 左滑第 \(k) 次命中「\(label)」⇒ 点 (\(Int(pt.x)),\(Int(pt.y)))")
                hid(BLEController.moveAndClick(x: Double(pt.x), y: Double(pt.y),
                                               baseW: baseW, baseH: baseH, yFix: yFix))
                Thread.sleep(forTimeInterval: 6.0)
                return true
            }
        }
        log("      ⛔ 翻了 \(tried) 页都没找到「\(which)」⇒ **不放枪**（铁律②）")
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
    @discardableResult
    func tap(_ name: String, img: UIImage, atomic: Bool = false) -> Bool {
        guard let h = detect(name, img: img) else { return false }
        let c = h.center
        if atomic {
            let cmd = BLEController.atomicClickCmd(x: Double(c.x), y: Double(c.y),
                                                   baseW: baseW, baseH: baseH, yFix: yFix)
            ble.send(cmd)
            Thread.sleep(forTimeInterval: Self.tapAfterSettle)
            log("   §click \(name) ATOMIC Q @(\(Int(c.x)),\(Int(c.y))) score=\(String(format: "%.3f", h.score)) ev=\(h.evidence)")
            return true
        }
        // ⭐ 两步式（`P:` + `C:L`）—— 与电脑端 `click_at` 一致，**并按电脑端节奏等待**
        let cmds = BLEController.moveAndClick(x: Double(c.x), y: Double(c.y),
                                              baseW: baseW, baseH: baseH, yFix: yFix)
        for (i, cmd) in cmds.enumerated() {
            ble.send(cmd)
            Thread.sleep(forTimeInterval: i == 0 ? Self.tapMoveSettle : Self.tapAfterSettle)
        }
        log("   §click \(name) @(\(Int(c.x)),\(Int(c.y))) score=\(String(format: "%.3f", h.score)) ev=\(h.evidence)")
        return true
    }

    /// ⭐ **按坐标直接点**（坐标来自别处，如 OCR 词中心）
    /// 同样遵守电脑端的点击节奏。
    @discardableResult
    func tapPoint(_ x: Double, _ y: Double, atomic: Bool = false) -> Bool {
        if atomic {
            ble.send(BLEController.atomicClickCmd(x: x, y: y,
                                                  baseW: baseW, baseH: baseH, yFix: yFix))
            Thread.sleep(forTimeInterval: Self.tapAfterSettle)
            return true
        }
        let cmds = BLEController.moveAndClick(x: x, y: y,
                                              baseW: baseW, baseH: baseH, yFix: yFix)
        for (i, cmd) in cmds.enumerated() {
            ble.send(cmd)
            Thread.sleep(forTimeInterval: i == 0 ? Self.tapMoveSettle : Self.tapAfterSettle)
        }
        return true
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
        ble.send(BLEController.backGestureCmd())
        Thread.sleep(forTimeInterval: 1.0)
        log("   §gesture 左边缘右滑返回（B:）")
        return true
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
        tapPoint(Double(c.x), Double(c.y))
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
                    tapPoint(Double(c.x), Double(c.y))
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
                    tapPoint(Double(c.x), Double(c.y))
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
                    tapPoint(Double(hit.x), Double(hit.y))
                    return true
                }
                continue
            }
            // ⭐ 券弹窗 ✕（PC `find_coupon_x`，ROI 在屏幕中下）—— 同一个判据换 ROI
            if it.element == "coupon_x" {
                if let c = ModalX.findCoupon(img) {
                    funnelLast[it.element] = now
                    log("   §funnel coupon_x（券弹窗 ✕）@(\(Int(c.x)),\(Int(c.y)))")
                    tapPoint(Double(c.x), Double(c.y))
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
            // ① 点之前抓一帧
            let pre = img
            // ⭐ **手势/色彩类出路**（⛔ 不是"找到元素再点"，而是专门的动作）
            //    · `back_edge` = 左边缘右滑返回（B:）—— 沉浸式页面唯一出路
            //    · `coin_ball` = 点红包悬浮球（**色彩判据**，OCR 认不出它）
            let acted: Bool
            if g == "back_edge" {
                acted = backEdge()
            } else if g == "coin_ball" {
                acted = tapCoinBall(img: img)
            } else {
                acted = tap(g, img: img)
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
}
