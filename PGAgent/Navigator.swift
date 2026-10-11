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
            let h = rec.findWords(img, words: words, roi: r,
                                  minHits: e.min_hits ?? 1,
                                  minConfidence: cfg.settings?.ocr_min_confidence ?? 0.5)
            if var hh = h { hh.name = name; return hh }
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
    /// ② mall        —— ⭐ 必须在 feed 前（PC 血案）
    /// ③ featured / feed / msg —— 底栏各 tab
    /// ④ deeppage / darkpage   —— 只靠一个返回键，**最宽泛 ⇒ 最后**
    /// ```
    /// ⚠️ `ad_video` 是**孤岛**（`island:true`）⇒ 不参与"我在哪"（见下）
    static let pageOrder: [String] = [
        "center",
        "mall",          // ⭐ 必须在 feed 之前
        "featured",
        "feed",
        "msg",
        "deeppage",
        "darkpage",
        "ext_landing",
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
            if !ok { continue }
            if let nots = p.not {
                for n in nots where detect(n, img: img) != nil { ok = false; break }
            }
            if ok { return pname }
        }
        return nil
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
            // ⭐ **手势类出路**（不是"找到再点"，而是直接发一条手势命令）
            //    `back_edge` = 左边缘右滑返回（B:）—— 沉浸式页面唯一出路
            let acted: Bool
            if g == "back_edge" {
                acted = backEdge()
            } else {
                acted = tap(g, img: img)
            }
            guard acted else {
                log("   §nav 在 \(page) 想点 \(g) 但**没找到** ⇒ 记死这条腿")
                markDead(page, g)
                continue
            }
            // ② 点之后再抓一帧，比「有没有变」
            Thread.sleep(forTimeInterval: 1.2)
            guard let post = grab() else { return (true, g, true) }
            if screenChanged(pre, post) {
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
