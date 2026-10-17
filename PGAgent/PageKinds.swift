import CoreGraphics
import Foundation
import UIKit

/// ⭐⭐⭐⭐⭐ §2979 **统一页型识别层** —— 全项目**唯一**的“我在哪”判据来源。
///
/// # 为什么必须重造（第一性原理，⛔ 不是打补丁）
///
/// 本文件之前的实际状况（本轮真机取证 + 源码核对）：
///
/// | 判据 | 位置 | 行为 |
/// |---|---|---|
/// | `pageHere()` | `Navigator` | `ad_video` 带 `island:true` ⇒ **被 `continue` 跳过** ⇒ 广告页永远 `unknown` |
/// | `looksLikeAdPage()` | `FeatureEngine` | 独立 OCR 判据，**21 处调用** |
/// | `cfg.pages["ad_video"].check` | `Navigator:1166` | 又一套“绕开 pageHere”的直读 |
/// | `page == "ad_video"` | `Runner:377` | **永远走不到的死分支** |
///
/// ⇒ 四套判据、互不通信。真机后果（本轮日志逐字）：
/// ```
/// 13:41:47  已回广告页（第 1 次检查）⇒ 继续等倒计时
/// 13:41:50  顶栏还有倒计时 ⇒ 不点胶囊 ✕（连拒 6 轮）
/// 13:42:01  ⛔ 点了也离不开广告页 ⇒ 本条不计入完成
/// 13:42:02  ✅ 已回广告页（第 1 次检查）      ← 同一时刻两个判据结论相反
/// ```
///
/// # PC 的答案（`_dev/_1377_ad_loop.py` 逐字，⛔ 不是 iOS 注释）
///
/// ```python
/// def page_kind(img, top=None):
///     """⭐⭐ 统一页面识别入口（§1699 表驱动）—— 每类页面用**它自己的锚点**认。
///     ⛔ **启动链路与主循环必须共用这一份**（旧代码两处各写一套 ⇒ 判据漂移 §1683）。
///     ⛔ 不许在分支里再各写一套判据 —— 那正是 §1683 之前的病。"""
///     for entry in _ANCHORS.ordered():          # order 升序 == 原 if 链顺序
///         hit, _ev = entry.matches(ctx)
///         if hit: return (entry.page_kind, top, _ev)
///     return "unknown", top, "无锚点命中"
/// ```
///
/// 判据本体在 `_dev/_1377_ad_loop.py:8230-8409`（`_pred_*`），
/// 页型声明在 `_dev/anchors/registry.json`（**18 个 active 页型**，`ad_video` 是 **order=7**）。
///
/// # 本文件的两条铁律
///
/// 1. **⛔ 没有 `island` 概念。** PC 的 `ad_video` 正常参与判序，不排除。
///    “导航不要碰广告页”这个**语义**改由**消费侧**表达（调用方拿到 `.ad_video` 自己决定不碰），
///    ⛔ 不是让识别层假装看不见 —— 那正是四个死循环的源头。
/// 2. **⛔ 每类页面只有一条判据**，且必须能离线复算（拿真帧跑 `/dbg/pagekind`）。
///    任何地方想“再加一套保险判据”，答案都是改这里，⛔ 不是另写一个 `looksLikeXxx`。
///
/// # 数据来源
/// 页型表 = `pgconfig/pagekinds.json`（由 `_dev/anchors/registry.json` **逐字生成**，
/// 见 `_dev/_2979_build_pagekinds.py`）。换版式 = **改表 + 丢模板**，识别代码零改动。
enum PageKinds {

    // MARK: - 结果类型

    /// 一次识别的结果（**带证据串**，照 PC `page_kind()` 的三元组）。
    ///
    /// ⛔ 证据串不是装饰：排查时必须能回答“它凭什么判成这个页型”。
    ///    PC 的每次判定都带 `_ev`，iOS 以前只返回一个字符串 ⇒ 日志里全是 `page=unknown`，
    ///    根本看不出是哪条判据没中。
    struct Result: Equatable {
        var kind: Kind
        var evidence: String
        /// 该页型在注册表里的 order（= 判序）。`unknown` 为 `Int.max`。
        var order: Int
    }

    /// 页型枚举 —— 与 `registry.json` 的 18 个 active 页型**一一对应**。
    ///
    /// ⚠️ `ad_video` 出现一次、`ad_live` 出现两次（order 8 `ad_live_bot` / order 12 `is_live_now`）——
    ///    后者是 PC 原样保留的两条独立证据链，⛔ 不要合并（合并会改变判序语义）。
    enum Kind: String, CaseIterable {
        case home
        case center
        case mall
        case draft
        case feed
        case stay
        case adVideo = "ad_video"
        case adLive = "ad_live"
        case appstore
        case landing
        case extLanding = "ext_landing"
        case homeLibrary = "home_library"
        case homeToday = "home_today"
        case homeMain = "home_main"
        case homeSub = "home_sub"
        case searchResult = "search_result"
        case goodsDetail = "goods_detail"
        case unknown
    }

    // MARK: - ROI 常量（**逐字移植** PC `_dev/_1377_ad_loop.py:8128-8178`）

    /// PC `BASE_W, BASE_H = 451.0, 977.0` —— 标定基准帧（坐标系基准，⛔ 不是写死的窗口尺寸）
    static let baseW: Double = 451
    static let baseH: Double = 977

    /// PC `B_APP_TOP = (0, 62, 451, 140)` —— App 导航顶栏
    static let bAppTop = CGRect(x: 0, y: 62, width: 451, height: 78)
    /// PC `B_APP_BOT = (0, 880, 451, 977)` —— App 导航底栏
    static let bAppBot = CGRect(x: 0, y: 880, width: 451, height: 97)
    /// PC `B_CAPSULE = (0, 55, 451, 160)` —— **广告胶囊**带
    ///
    /// ⛔ PC 为什么用比 `BOX_TOP` 更宽的带子（`_1377_r4K_a1_start.png` 真机帧）：
    ///   胶囊中心 y 会随版式漂（451×977 下实测 **y≈140**），落在 `BOX_TOP` 的 y1=140 上界
    ///   **恰好被切掉** ⇒ 识别层判不出“这是广告页”。识别层自带宽带即可，⛔ 不动 `BOX_TOP`。
    static let bCapsule = CGRect(x: 0, y: 55, width: 451, height: 105)
    /// PC `B_AD_LIVE_BOT = (0, 855, 451, 977)` —— 直播广告底部独有条
    static let bAdLiveBot = CGRect(x: 0, y: 855, width: 451, height: 122)
    /// PC `B_WIDE = (0, 300, 451, 977)` —— 外部页全文带（App Store / H5 落地页没有 App 骨架）
    static let bWide = CGRect(x: 0, y: 300, width: 451, height: 677)
    /// PC `B_MALL_ROW = (0, 150, 451, 260)` —— 商城页内容区图标行
    static let bMallRow = CGRect(x: 0, y: 150, width: 451, height: 110)
    /// PC `B_BODY = (0, 400, 451, 700)` —— 正文带（草稿箱的「发布作品」在这）
    static let bBody = CGRect(x: 0, y: 400, width: 451, height: 300)
    /// PC `B_STATUS = (0, 10, 300, 45)` —— 状态栏带（外部 App 面包屑在这）
    static let bStatus = CGRect(x: 0, y: 10, width: 300, height: 35)
    /// PC `B_SEARCH_TAB = (0, 108, 451, 182)` —— 搜索页 tab 行（实测 y≈131）
    static let bSearchTab = CGRect(x: 0, y: 108, width: 451, height: 74)
    /// PC `B_BUY = (0, 820, 451, 976)` —— 底部 CTA 带
    static let bBuy = CGRect(x: 0, y: 820, width: 451, height: 156)
    /// PC `is_stay_panel` 的判据带 `(0, 320, 451, 670)`
    static let bStayPanel = CGRect(x: 0, y: 320, width: 451, height: 350)

    // MARK: - 词表（**逐字移植** PC，⛔ 一个字都不改）

    /// PC `APP_BOT_KEYS` —— App 底栏词
    static let appBotKeys = ["首页", "精选", "消息", "我"]
    /// PC `APP_NAV_KEYS` —— App 顶栏 tab 词
    static let appNavKeys = ["探索", "商城", "同城", "团购", "关注→发现", "发现"]
    /// PC `AD_LIVE_KEYS` —— **直播广告**底部独有锚点
    ///
    /// PC 注释（真机帧实证）：`_1377_004504_a1_live.png` = `券后 ￥0.1 说点什么`；
    /// `_1377_175716_a1_start.png` = `恭喜快手用户178…我现在加入，来自推广 高端家装漆`
    /// （⛔ 这条 top 里 `关注` 后面被 OCR 读成 `18 381` 而非 `18万观看` ⇒ 旧判据漏判它）
    static let adLiveKeys = ["来自推广", "我现在加入", "说点什么", "小黄车",
                             "讲解中", "讲解", "进解", "抽大奖"]
    /// PC `APPSTORE_KEYS` —— App Store 页锚点
    ///
    /// ⚠️ PC 注释：`了解详情` **故意不收** —— 它同时是视频广告的 CTA（y≈979）⇒ 会误判。
    static let appstoreKeys = ["评分及评论", "开发者", "iPhone、iPad", "万个评分", "App 内购买"]
    /// PC `LAND_KEYS` —— H5 落地页锚点
    static let landKeys = ["免费预约", "立即下载", "前往下载", "打开APP", "打开App",
                           "应用商店", "应用详情", "立即体验", "预约下载"]
    /// PC `MALL_ROW_KEYS` —— 商城页图标行
    ///
    /// ⛔ PC 为什么不用顶栏「商城」：feed 首页顶栏**也有**它（`探索 生活 关注 同城 商城 …`）。
    static let mallRowKeys = ["我的订单", "购物车", "充值中心", "低价特卖", "赚金币", "天天领"]
    /// PC `EXT_LAND_KEYS` —— 外部 App 下载落地页顶栏词
    static let extLandKeys = ["下载链接", "官方正版", "官服", "扫码下载", "点击下载",
                              "前往应用商店", "下载APP", "下载App"]
    /// PC `SEARCH_TAB_KEYS` —— 搜索页 tab 行
    static let searchTabKeys = ["综合", "销量"]
    /// PC `BUY_KEYS` —— 商品详情页底部 CTA
    static let buyKeys = ["立即购买", "加入购物车", "立即抢购", "马上抢", "去购买", "立即下单"]

    /// PC `CENTER_RX`（`_dev/_1377_ad_loop.py:3419`，逐字）
    ///
    /// ```python
    /// CENTER_RX = re.compile(r"任务中心|我的金|金[币市]商"
    ///                        r"|看广告得金币|看视频赚金币|瓜分百亿"
    ///                        r"|(?=.*金币[：:]?\s*\d)(?=.*现金[：:]?\s*[\d.])")
    /// ```
    ///
    /// ⛔ PC 为什么是正则而非精确子串（`§1446` 真机 9 帧取证）：
    ///   OCR 把「金币商城」读成「金**市**商城」、「我的金币」读成「我的金**而**」⇒
    ///   精确匹配只命中 4/9=44.4% ⇒ **整轮跑完 0 条直接停手**；改正则后 9/9=100%，
    ///   且 140 张广告页帧的误判率持平（1/140）。
    static let centerRegex: NSRegularExpression? = {
        let pattern = "任务中心|我的金|金[币市]商"
            + "|看广告得金币|看视频赚金币|瓜分百亿"
            + "|(?=.*金币[：:]?\\s*\\d)(?=.*现金[：:]?\\s*[\\d.])"
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// PC `_TODAY_RX`（`_dev/_1377_ad_loop.py:8286`，逐字）—— iOS 今日视图左上角日期大标题
    ///
    /// ⛔ PC 血案：原判据是**负向**的（“读不到搜索 ⇒ 今日视图”）⇒ 全语料审计 **291/300 帧命中**，
    ///   等于“任何读不到搜索的帧都算今日视图”，是**假阳机器**（也正是它把视频广告抢判成别的页型）。
    ///   ✅ 改为正向：读得到日期大标题才算。
    static let todayRegex: NSRegularExpression? = {
        let pattern = "(\\d{1,2}\\s*月\\s*\\d{1,2}\\s*日)|(\\d{4}\\s*年\\s*\\d{1,2}\\s*月)"
            + "|(星期[一二三四五六日天])|((Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?\\s+\\w+\\s+\\d{1,2})"
        return try? NSRegularExpression(pattern: pattern)
    }()

    // MARK: - 识别入口（**唯一**，照 PC `page_kind()` 的表驱动结构）

    /// 统一页型识别 —— 全项目**只能**从这里问“我在哪”。
    ///
    /// 判序 = 注册表 `order` 升序（== PC 原 if 链顺序）。首个命中即返回（**中断后续检测**，
    /// 照 MaaFramework “Interruption Mechanism”）。
    ///
    /// - Parameters:
    ///   - img: 当前帧
    ///   - ocr: OCR 提供者（同一帧内部缓存，照 PC `_ocr_full` 单帧缓存）
    ///   - includeDesktop: 是否启用桌面族页型（`home_*`）。
    ///     PC 默认**不参与**（守 `PAGE_PLAN` 契约）；只有判断“在不在桌面”时才开。
    /// - Returns: 命中的页型；都不中 ⇒ `.unknown`（证据串“无锚点命中”）
    static func detect(_ img: UIImage,
                       ocr: OcrProviding,
                       includeDesktop: Bool = false) -> Result {
        // 单帧 OCR 缓存：下面 18 条判据会对同一帧反复取文字，⛔ 不许重复 OCR（PC `_ocr_full` 同理）
        let sheet = OcrSheet(img: img, ocr: ocr)
        return detectFrom(sheet: sheet, includeDesktop: includeDesktop)
    }

    /// 已经是 `OcrSheet` 的入口（调用方自己建了缓存时用 —— ⛔ 不要重复建，那会重复 OCR）
    static func detectFrom(sheet: OcrSheet, includeDesktop: Bool = false) -> Result {
        for entry in entries {
            // 桌面族默认不参与判序（PC `_DESKTOP_KINDS` 同一语义）
            if !includeDesktop, desktopKinds.contains(entry.kind) { continue }
            if let ev = entry.predicate(sheet) {
                return Result(kind: entry.kind, evidence: ev, order: entry.order)
            }
        }
        return Result(kind: .unknown, evidence: "无锚点命中", order: Int.max)
    }

    /// 便捷：只要页型不要证据
    static func kind(_ img: UIImage, ocr: OcrProviding, includeDesktop: Bool = false) -> Kind {
        detect(img, ocr: ocr, includeDesktop: includeDesktop).kind
    }

    /// 桌面族页型（PC `_DESKTOP_KINDS`）—— 默认不参与 `page_kind()` 返回
    static let desktopKinds: Set<Kind> = [.homeLibrary, .homeToday, .homeMain, .homeSub]

    // MARK: - 注册表条目

    /// 一条“页型 → 判据”的声明（对应 `registry.json` 的一个 entry）
    struct Entry {
        var kind: Kind
        var order: Int
        /// 判据本体：返回证据串 = 命中；返回 nil = 未命中（照 PC `_pred_*` 的 `(bool, ev)`）
        var predicate: (OcrSheet) -> String?
    }

    /// **判序表** —— `order` 升序，与 PC `registry.json` 的 18 条 active entry 一一对应。
    ///
    /// ⛔ 改这张表 = 改全部行为。`_dev/_2979_verify_pagekinds.py` 会对它与
    ///    `_dev/anchors/registry.json` 做**逐条对拍**（order / kind / predicate 名字），
    ///    不一致 ⇒ 拒绝出包。
    static let entries: [Entry] = [
        .init(kind: .home, order: 1) { s in
            // PC `_pred_homescreen` → `is_homescreen`（`_dev/_1377_ad_loop.py:7921`，**逐字**）：
            // ```python
            // def is_homescreen(img):
            //     if "搜索" in txt(img, (150, 780, 320, 860)):
            //         return True
            //     return "资源库" in txt(img, (0, 60, 451, 140))
            // ```
            // 📏 PC 注释（§1642 真机定标）：桌面每页底部都有「搜索」胶囊 @scr(≈226,814)；
            //    App 资源库页顶部是「App 资源库」搜索框。
            //
            // ⛔⛔ §2980 我第一版写错了（必须记下来）：
            //    我把 ROI 自造成 `(0,900,451,77)`（搜索）+ `(0,200,451,200)`（天气/日历），
            //    **那是我猜的，PC 里根本没有「天气」「日历」这两个词** ——
            //    违反「与 PC 对照，⛔ 不自造」。已按 PC 逐字改回。
            if s.has("搜索", in: CGRect(x: 150, y: 780, width: 170, height: 80)) {
                return "桌面(搜索胶囊)"
            }
            return s.has("资源库", in: CGRect(x: 0, y: 60, width: 451, height: 80))
                ? "桌面(App资源库)" : nil
        },
        .init(kind: .center, order: 2) { s in
            // PC `_pred_on_center` → `on_center` / `CENTER_RX`（`_dev/_1377_ad_loop.py:3424`，**逐字**）：
            // ```python
            // fc = txt(img, BOX_CENTER)          # BOX_CENTER = (0, 62, 451, 190)
            // return CENTER_RX.search(fc) is not None
            // ```
            // ⚠️ §2980 换算提醒：PC 的 box 是 `(x0, y0, x1, y1)`，
            //    ⛔ 不是 `(x, y, w, h)`。`BOX_CENTER = (0, 62, 451, 190)`
            //    ⇒ `CGRect(x: 0, y: 62, width: 451, height: 190-62=128)`。
            //    PC 注释 §1631：kslite 顶栏在 y≈77、第一条任务名在 y≈141 ⇒ 两行都要覆盖才判得出。
            let t = s.text(CGRect(x: 0, y: 62, width: 451, height: 128))
            guard let rx = centerRegex else { return nil }
            let ns = t as NSString
            let hit = rx.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil
            return hit ? "CENTER_RX(\(String(t.prefix(20))))" : nil
        },
        .init(kind: .mall, order: 3) { s in
            // PC `_pred_mall` → `mall_row`（`_dev/_1377_ad_loop.py:8315`，**逐字**）：
            // ```python
            // _n = 0
            // for _w, _x, _y in words(img, B_MALL_ROW):      # B_MALL_ROW = (0,150,451,260)
            //     if _w.strip() in MALL_ROW_KEYS: _n += 1
            // return (bool(_n >= 2), ...)
            // ```
            // ⛔ PC 为什么不用顶栏「商城」：feed 首页顶栏**也有**它
            //    （`_1735_1768_pre.png` 顶栏 = `探索 生活 关注 同城 商城 发理 首饰盒 搜索`）。
            let t = s.text(bMallRow)
            let n = mallRowKeys.filter { t.contains($0) }.count
            return n >= 2 ? "商城图标行(\(n)/\(mallRowKeys.count))" : nil
        },
        .init(kind: .draft, order: 4) { s in
            // PC `_pred_draft`：顶栏「草稿箱」，或「草稿」+ 正文「发布作品」
            let top = s.text(bAppTop)
            if top.contains("草稿箱") { return "草稿箱(\(String(top.prefix(18))))" }
            if top.contains("草稿"), s.text(bBody).contains("发布作品") {
                return "草稿箱(草稿+发布作品)"
            }
            return nil
        },
        .init(kind: .feed, order: 5) { s in
            // PC `_pred_app_chrome` → `app_chrome`：App 骨架（顶/底 tab 栏）
            //
            // ★ PC 注释：这是整个页面识别层的**分水岭** —— `True` ⇒ 一律 `feed`，
            //   **再也不进**「直播间」那套判据（§1683 血案）。顺序上必须排在 is_live_now 之前。
            let bot = s.text(bAppBot)
            let bh = appBotKeys.filter { bot.contains($0) }
            if bot.contains("首页"), bh.count >= 2 { return "App底栏(\(bh.joined(separator: "/")))" }
            let top = s.text(bAppTop)
            let nav = appNavKeys.filter { top.contains($0) }
            if nav.count >= 2 { return "App顶栏(\(nav.joined(separator: "/")))" }
            return nil
        },
        .init(kind: .stay, order: 6) { s in
            // PC `_pred_stay` → `is_stay_panel`：挽留面板「继续观看 / 再看N秒」
            let t = s.text(bStayPanel)
            if t.contains("继续观看") { return "「继续观看」" }
            if t.contains("再看"), t.contains("秒") { return "「再看N秒」" }
            return nil
        },
        .init(kind: .adVideo, order: 7) { s in
            // PC `_pred_ad_capsule` → `ad_capsule`（`_dev/_1377_ad_loop.py:8247`，逐字）：
            // ```python
            // top = ctx["top"]
            // _ct = top if ("可领取" in top or "已成功领取" in top) else txt(ctx["img"], B_CAPSULE)
            // hit = ("可领取" in _ct) or ("已成功领取" in _ct) or ("广告" in _ct and "金币" in _ct)
            // ```
            //
            // ⛔⛔⛔ **这就是 `island:true` 排掉的那条判据。** 本轮真机帧实测它有 100% 命中：
            // ```
            // 13:47 帧：ad_capsule {"hit":true,"score":1,"ev":"已成功领取591金币×","x":52,"y":81}
            //           ad_mark    {"hit":true,"score":1,"ev":"广告","x":348,"y":83}
            // 而 page = "(unknown)"   ← 只因 Navigator.pageHere 里 `island==true ⇒ continue`
            // ```
            let topBand = s.text(CGRect(x: 0, y: 62, width: 451, height: 78))
            let ct: String
            if topBand.contains("可领取") || topBand.contains("已成功领取") {
                ct = topBand
            } else {
                ct = s.text(bCapsule)
            }
            if ct.contains("可领取") || ct.contains("已成功领取") {
                return "胶囊(\(String(ct.prefix(22))))"
            }
            // 抗 OCR 错字（PC §1543 血案：真机把「可领取」读成「善厨领取」）
            // ⇒ 补一条：顶栏同时含「广告」+「金币」也算广告页（两词短、位置稳，实测没被读错过）
            if ct.contains("广告"), ct.contains("金币") {
                return "胶囊(广告+金币:\(String(ct.prefix(18))))"
            }
            return nil
        },
        .init(kind: .adLive, order: 8) { s in
            // PC `_pred_ad_live_bot` → `ad_live_bot`
            let t = s.text(bAdLiveBot)
            let lb = adLiveKeys.filter { t.contains($0) }
            return lb.isEmpty ? nil : "直播广告底栏(\(lb.prefix(3).joined(separator: "/")))"
        },
        .init(kind: .appstore, order: 9) { s in
            // PC `_pred_appstore_wide` → `appstore_wide`
            let t = s.text(bWide)
            let ks = appstoreKeys.filter { t.contains($0) }
            return ks.isEmpty ? nil : "App Store(\(ks.prefix(3).joined(separator: "/")))"
        },
        .init(kind: .landing, order: 10) { s in
            // PC `_pred_landing_wide` → `landing_wide`
            let t = s.text(bWide)
            let ks = landKeys.filter { t.contains($0) }
            return ks.isEmpty ? nil : "H5落地页(\(ks.prefix(3).joined(separator: "/")))"
        },
        .init(kind: .extLanding, order: 11) { s in
            // PC `_pred_ext_landing`（`_dev/_1377_ad_loop.py:8342`，逐字）
            //
            // 判据 = 顶栏含下载/推广词 **且** 状态栏有“返回 XX”指示器。
            // PC 真机实测的状态栏三态（本机逐帧对比）：
            // | 页面 | 状态栏 |
            // | 闲鱼（外部 App） | `留快手` |
            // | 草稿箱（快手内） | `品,快手极速版` |
            // | feed（快手内） | `快手极速版` |
            // 📏 判据（结构性）：外部 App 时状态栏有“返回 XX”指示器，
            //    OCR 形态 = `留快手` / `◀快手` / `←快手` / `,快手`。
            //    ⛔ **不能只判“含快手”** —— 快手内部页的状态栏**也含“快手极速版”**。
            //    ✅ 正确 = 含「快手」**但⛔ 不含「极速版」**。
            let top = s.text(bAppTop)
            let ks = extLandKeys.filter { top.contains($0) }
            guard !ks.isEmpty else { return nil }
            let bar = s.text(bStatus)
            let backInd = bar.contains("快手") && !bar.contains("极速版")
            return backInd
                ? "外部落地页(\(ks.prefix(2).joined(separator: "/"))|\(String(bar.prefix(16))))"
                : nil
        },
        .init(kind: .adLive, order: 12) { s in
            // PC `_pred_live_now` → `is_live_now(img)`（`_dev/_1377_ad_loop.py:1077`）
            //
            // ⚠️ 与 order=8 的 `ad_live_bot` 是**两条独立证据链**（PC 原样保留，⛔ 不合并）。
            // ⛔ §2980 我第一版把 ROI 自造成 `(0,300,451,800)` —— PC 里没有这个值。
            //    PC 的 `_pred_live_now` 调 `is_live_now(ctx["img"])`，**不传 box**
            //    ⇒ 用直播间自己的判据（`BOX_LIVE_*` 三条：头部 `(0,70,451,132)` /
            //    中部 `(0,668,451,700)` / 底部 `(0,898,451,942)`）。
            //    ⛔ 这里不该自造一个大框，应按 PC 的三条带子分别判。
            let top = s.text(CGRect(x: 0, y: 70, width: 451, height: 62))      // BOX_LIVE_T
            let mid = s.text(CGRect(x: 0, y: 668, width: 451, height: 32))     // BOX_LIVE_W
            let bot = s.text(CGRect(x: 0, y: 898, width: 451, height: 44))     // BOX_LIVE_B
            // PC `BOX_LIVE_W` 的注释：「直播间标记(下)：「讲解中」」
            // PC `BOX_LIVE_B` 的注释：「评论输入框「说点什么」+「小黄车」—— 直播间独有」
            var hits: [String] = []
            if mid.contains("讲解中") { hits.append("讲解中") }
            if bot.contains("说点什么") { hits.append("说点什么") }
            if bot.contains("小黄车") { hits.append("小黄车") }
            if top.contains("在线观众") { hits.append("在线观众") }
            return hits.isEmpty ? nil
                : "直播间元素(\(hits.prefix(3).joined(separator: "/")))"
        },
        .init(kind: .homeLibrary, order: 13) { s in
            // PC `"资源库" in txt(roi)` —— roi 来自 registry：`home_library`
            // 归一化 `[0.0, 0.06141, 1.0, 0.1433]` ⇒ 像素 `(0, 60, 451, 140)`
            // ⇒ `CGRect(x:0, y:60, width:451, height:80)`。
            //
            // ⛔ §2980 我第一版写成整屏 `(0,0,451,977)`（自造）⇒ 全屏命中 = 假阳机器。
            s.has("资源库", in: CGRect(x: 0, y: 60, width: 451, height: 80))
                ? "资源库" : nil
        },
        .init(kind: .homeToday, order: 14) { s in
            // PC `_pred_desk_today`（`_dev/_1377_ad_loop.py:8292`，逐字）：
            // ```python
            // top_box = (0, 0, int(BASE_W), int(BASE_H * 0.35))     # = (0,0,451,342)
            // _top = txt(img, top_box)
            // _has_date = bool(_TODAY_RX.search(_top))
            // box = entry.roi.to_px(int(BASE_W), int(BASE_H))       # home_today = (0,0,451,342)
            // _no_search = "搜索" not in txt(img, box)
            // hit = _has_date and _no_search
            // ```
            //
            // ⛔ PC 血案：原判据是**负向**的（“读不到搜索 ⇒ 今日视图”）⇒ 291/300 帧命中，
            //   是**假阳机器**（也是它把视频广告抢判成别的页型）。✅ 正向日期才是主判据。
            //
            // ⛔ §2980 我第一版把负向闸的 ROI 写成 `(0,900,451,77)`（自造）——
            //    PC 的负向闸用的是 **entry.roi 同一个 `(0,0,451,342)`**，即顶部那块。
            let topBox = CGRect(x: 0, y: 0, width: 451, height: 342)
            let topText = s.text(topBox)
            guard let rx = todayRegex else { return nil }
            let ns = topText as NSString
            let hasDate = rx.firstMatch(in: topText,
                                       range: NSRange(location: 0, length: ns.length)) != nil
            guard hasDate else { return nil }
            let noSearch = !s.has("搜索", in: topBox)
            return noSearch ? "今日视图(日期 \(String(topText.prefix(20))))" : nil
        },
        .init(kind: .homeMain, order: 15) { s in
            // PC `_pred_desk_main`（`_dev/_1377_ad_loop.py:8276`，逐字）：
            // ```python
            // box = entry.roi.to_px(int(BASE_W), int(BASE_H))       # home_main = (150,780,320,860)
            // hit = ("搜索" in txt(img, box)) and ("设置" in txt(img, (0, 60, int(BASE_W), int(BASE_H))))
            // ```
            // PC 注释：桌面第 1 页自带「设置」（用户可挪走 ⇒ 只判「读到没」）。
            //
            // ⛔ §2980 我第一版把两个 ROI 都自造了（`(0,900,451,77)` + `(0,60,451,917)`）。
            let searchBox = CGRect(x: 150, y: 780, width: 170, height: 80)   // reg home_main roi
            let settingsBox = CGRect(x: 0, y: 60, width: 451, height: 917)   // PC (0,60,451,977)
            let hasSearch = s.has("搜索", in: searchBox)
            let hasSettings = s.has("设置", in: settingsBox)
            return (hasSearch && hasSettings) ? "桌面第1页(搜索+设置)" : nil
        },
        .init(kind: .homeSub, order: 16) { s in
            // PC `"搜索" in txt(roi)` —— roi 来自 registry：`home_sub`
            // 归一化 `[0.33259, 0.79632, 0.70953, 0.88229]` ⇒ 像素 `(150, 778, 320, 862)`
            // ⇒ `CGRect(x:150, y:778, width:170, height:84)`。
            //
            // ⛔ §2980 我第一版写成 `(0,890,451,87)`（自造）⇒ 差了 112px。
            s.has("搜索", in: CGRect(x: 150, y: 778, width: 170, height: 84))
                ? "副桌面(搜索)" : nil
        },
        .init(kind: .searchResult, order: 17) { s in
            // PC `_pred_search_result`（`_dev/_1377_ad_loop.py:8378`，逐字）
            //
            // 📏 判据（本机实测 9 帧 9/9）：**顶栏含「搜索」且 tab 行含「综合」**。
            //   · 单用「综合」会误判（`mall_result_gold` 有「销量」）
            //   · 单用「搜索」会误判（feed 首页顶栏**也有**「搜索」入口）⇒ **两个都满足**才算
            let top = s.text(bAppTop)
            guard top.contains("搜索") else { return nil }
            let tab = s.text(bSearchTab)
            let c2 = searchTabKeys.contains { tab.contains($0) }
            return c2 ? "搜索页(顶栏搜索=true|tab=\(String(tab.prefix(16))))" : nil
        },
        .init(kind: .goodsDetail, order: 18) { s in
            // PC `_pred_goods_detail`（`_dev/_1377_ad_loop.py:8396`，逐字）
            //
            // 📏 判据：底部 CTA 带含购买类按钮（商品详情页独有）。
            //   ⛔ 再叠一道：顶栏**不含 App 底栏词**（`首页/精选/消息/我`）⇒ 排除 feed 误判。
            let buy = s.text(bBuy)
            let buys = buyKeys.filter { buy.contains($0) }
            guard !buys.isEmpty else { return nil }
            let top = s.text(bAppTop)
            let isApp = ["探索", "同城", "团购"].contains { top.contains($0) }
            return isApp ? nil : "商品详情(\(buys.prefix(2).joined(separator: "/")))"
        },
    ]

    // MARK: - 单帧 OCR 缓存（照 PC `_ocr_full` 单帧缓存）

    /// 一帧画面的 OCR 缓存。
    ///
    /// ⛔ 为什么必须有：18 条判据要反复读同一帧的不同 ROI。
    ///    不缓存 ⇒ 一次识别做 18+ 次 OCR ⇒ 真机上一轮要十几秒（PC 早就用 `_ocr_full` 解决了）。
    ///
    /// 实现：**整帧 OCR 一次**，之后所有 ROI 查询都是内存过滤（PC 也是整帧 OCR + 按框过滤）。
    final class OcrSheet {
        private let items: [(text: String, rect: CGRect)]
        private var cache: [String: String] = [:]

        init(img: UIImage, ocr: OcrProviding) {
            // 整帧识别一次（归一化到基准 451×977 后的坐标）
            let base = FrameNormalizer.normalize(img)
            items = ocr.ocrForPageKinds(base, minConfidence: 0.3).map { ($0.0, $0.1) }
        }

        /// 取某 ROI 内的全部文字（按行拼接）
        func text(_ roi: CGRect) -> String {
            let key = "\(roi.minX),\(roi.minY),\(roi.width),\(roi.height)"
            if let c = cache[key] { return c }
            var parts: [String] = []
            for it in items where roi.intersects(it.rect) {
                parts.append(it.text)
            }
            let joined = parts.joined(separator: " ")
            cache[key] = joined
            return joined
        }

        /// 某 ROI 内是否含某词
        func has(_ word: String, in roi: CGRect) -> Bool {
            text(roi).contains(word)
        }
    }
}

// MARK: - 依赖协议（保持本文件可独立离线复算，⛔ 不依赖 UI）

/// OCR 能力的最小接口 —— 生产实现是 `PageKindsOcr`（对 `Recognizer` 的薄适配），
/// 离线复算时可用假实现注入真帧的 OCR 结果。
protocol OcrProviding {
    /// - Returns: `(text, rect)` 列表，坐标必须是**基准 451×977**
    func ocrForPageKinds(_ img: UIImage, minConfidence: Double) -> [(String, CGRect)]
}

/// `Recognizer` 的适配 —— 让生产实现满足 `OcrProviding`。
///
/// ⛔ 为什么不直接改 `Recognizer.ocr`：它返回三元组 `(String, CGRect, Double)`（带置信度），
///    而判据层只要 `(String, CGRect)`。加一层薄适配即可，
///    ⛔ 不动已被真机验证过的 `Recognizer` 签名（改了要全链路回归）。
struct RecognizerOcr: OcrProviding {
    let rec: Recognizer
    func ocrForPageKinds(_ img: UIImage, minConfidence: Double) -> [(String, CGRect)] {
        rec.ocr(img, minConfidence: minConfidence).map { ($0.0, $0.1) }
    }
}
