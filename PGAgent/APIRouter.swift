import Foundation
import UIKit

/// ⭐⭐⭐ HTTP API —— 主机（经 USB 隧道）调用 App 的唯一入口。
///
/// 设计：`_note_1801` §4 —— 主机 `pymobiledevice3 usbmux forward 8899 8899` 之后，
/// `curl http://127.0.0.1:8899/<path>` 直接驱动 App。
///
/// ⭐ 关键接口（**配置驱动**，改逻辑只推文件，⛔ 不重装）：
///   GET  /status           App/HTTP/BLE 状态 + 配置是否已加载
///   POST /reload           重新读 Documents/pgconfig/config.json  ⭐
///   GET  /config           回显当前配置（排查用）
///   GET  /elements?img=X   对某张图跑一遍所有元素的检测（识别自测）⭐
///   GET  /page?img=X       对某张图判页型
///   POST /nav?dest=X&img=Y 跑导航（到某页）
///   POST /ocr?img=X        对某张图跑 OCR，返回全部文字+坐标  ⭐
///
/// 文件接口：
///   GET  /files  /file?name=X  POST /write?name=X  DELETE /file?name=X
///   POST /mkdir?name=X         建子目录（推模板用）
final class APIRouter {

    let log: LogStore
    let ble: BLEController
    let cfgStore: ConfigStore
    let grabber: ScreenGrabber
    let runner: Runner
    let broadcaster: BroadcastStarter
    let pip: PiPManager
    var httpPort: UInt16 = 0

    init(log: LogStore, ble: BLEController, cfgStore: ConfigStore,
         grabber: ScreenGrabber, runner: Runner, broadcaster: BroadcastStarter,
         pip: PiPManager) {
        self.log = log
        self.ble = ble
        self.cfgStore = cfgStore
        self.grabber = grabber
        self.runner = runner
        self.broadcaster = broadcaster
        self.pip = pip
    }

    // MARK: - 工具

    private func docsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 取一张图：优先 `?img=<Documents 里的文件名>`；没有则报错（⛔ App 不能截别的 App 的屏）
    private func loadImage(_ q: [String: String]) -> (UIImage?, String) {
        guard let name = q["img"], !name.isEmpty else {
            return (nil, "need ?img=<filename>（App 无法自己截别的 App 的屏，见 /PLAN）")
        }
        let u = docsURL().appendingPathComponent(name)
        guard let d = try? Data(contentsOf: u), let im = UIImage(data: d) else {
            return (nil, "读不到图: \(name)")
        }
        return (im, "")
    }

    private func makeRecognizer() -> Recognizer {
        Recognizer(templatesDir: ConfigStore.templatesDir())
    }

    // MARK: - 路由

    func handle(_ r: HTTPServer.Request) -> HTTPServer.Response {
        let p = r.path
        log.log("API \(r.method) \(p)")

        switch (r.method, p) {

        case ("GET", "/"):
            return .json([
                "app": "PGAgent", "version": AppVersion.display,
                "endpoints": ["/status", "/probe", "/reload", "/config", "/elements",
                              "/page", "/nav", "/ocr", "/see", "/grab", "/grabinfo",
                              "/shoot", "/shortcut", "/run", "/runstop", "/runstate",
                              "/dl", "/openurl", "/install-shortcut", "/rec/start", "/rec/state",
                              "/frame", "/frame.jpg", "/rec/save", "/framediag", "/framepoll",
                              "/pip/start", "/pip/stop", "/pip/state", "/pip/text",
                              "/keepalive/start", "/keepalive/stop", "/keepalive/state",
                              "/runlog", "/recogdiag",
                              "/files", "/file", "/write", "/mkdir", "/ble/scan",
                              "/ble/connect", "/ble/connect-paired", "/blediag", "/ble/send",
                              "/click", "/swipe", "/settings", "/log"],
            ])

        // ⭐ 极简探活（⛔ 不碰文件系统、不做识别）—— 用来区分「App 挂了」和「handler 慢」
        //
        // ⭐ 顺手带上**真实版本**（读 Info.plist）—— 排查「装的新包还是旧包」一眼就够
        case ("GET", "/probe"):
            let b = Bundle.main
            let ver = (b.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
            let bld = (b.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
            return .json(["ok": true, "t": Date().timeIntervalSince1970,
                          "version": ver, "build": bld])

        // ⭐⭐⭐ 「眼」—— App **自己取画面**（⛔ 不依赖 PC）
        //    App 触发快捷指令「拍摄截屏」⇒ 截图落到自己的 Documents
        case ("POST", "/grab"):
            let sem = DispatchSemaphore(value: 0)
            var gotURL: URL?
            var gotErr = ""
            grabber.grab(timeout: 10.0) { u, e in
                gotURL = u; gotErr = e; sem.signal()
            }
            _ = sem.wait(timeout: .now() + 14)
            if let u = gotURL {
                return .json(["ok": true, "file": u.lastPathComponent,
                              "path": u.path,
                              "bytes": (try? Data(contentsOf: u).count) ?? -1])
            }
            return .json(["ok": false, "error": gotErr.isEmpty ? "超时" : gotErr,
                          "shortcut": grabber.shortcutName,
                          "openResult": grabber.lastOpenResult,
                          "attempts": grabber.grabAttempts,
                          "successes": grabber.grabSuccesses], status: 500)

        // ⭐ 诊断：App 侧「眼」的全部状态（v0.4.1）
        case ("GET", "/grabinfo"):
            return .json([
                "shortcut": grabber.shortcutName,
                "openResult": grabber.lastOpenResult,
                "lastError": grabber.lastError,
                "attempts": grabber.grabAttempts,
                "successes": grabber.grabSuccesses,
                "lastShot": grabber.lastShot?.lastPathComponent ?? "-",
                "documents": docsURL().path,
                "pngCount": ScreenGrabber.listPNGs().count,
                "pngFiles": ScreenGrabber.listPNGs().map { $0.lastPathComponent },
                "canOpenShortcuts": UIApplication.shared
                    .canOpenURL(URL(string: "shortcuts://")!),
            ])

        // 只触发快捷指令，不等文件（快）
        case ("POST", "/shoot"):
            let ok = grabber.triggerShortcut()
            return .json(["ok": ok, "shortcut": grabber.shortcutName,
                          "error": grabber.lastError])

        // 设置快捷指令名
        case ("POST", "/shortcut"):
            if let n = r.query["name"], !n.isEmpty {
                grabber.shortcutName = n
            }
            return .json(["ok": true, "shortcut": grabber.shortcutName])

        // ⭐⭐⭐⭐ `/run` —— **App 自己在手机上跑循环**（⛔ 不需要 PC / USB / 开发者模式）
        //    用户令：「以后是全部交到手机上的，调试可以取画面，APP那边得自己取画面。」
        case ("POST", "/run"):
            // ⭐ 先把保活打开（否则一切后台就被挂起，循环必然断）
            let ka = SilentKeepAlive.shared.start()
            runner.start(dest: r.query["dest"])

            // ⭐⭐⭐⭐⭐ §2364 **切 App 已回到「上滑→认图标→点」**（真机验过的序列）
            //
            // ⛔ 之前删过一次（§2353），因为当时那套代码用 `H:HOME` 当主腿 + 左右翻页，
            //    三轮真机都做不对。**现在换成了 §2360~§2363 实测出来的序列**：
            // ```
            //   上滑（225,971→225,300 /120ms）→ OCR 找「快手/快手极速版」标签
            //     → 点标签上方 0.055 屏高   ⇒ 实测页型 = feed ✅
            //   没看到就再上滑（最多 4 次），⛔ 不左右翻页
            // ```
            // ⇒ 真正的干活点在 `Runner.loop()`（它在**后台队列** `q` 上跑，
            //   所以里面那串 `Thread.sleep` 不会阻塞主线程 / 不触发看门狗）。
            //    这里只回一个 informational 的 gotoInfo。
            let gotoInfo: [String: Any] = [
                "requested": (r.query["goto"] ?? "1") != "0",
                "via": "ESP32: swipe-up until the kuaishou icon shows, then tap it",
                "section": "2364",
            ]

            return .json(["ok": true, "started": true, "keepAlive": ka,
                          "dest": r.query["dest"] ?? cfgStore.cfg?.settings?.target ?? "center",
                          "goto": gotoInfo,
                          "state": runner.snapshot()])

        case ("POST", "/runstop"):
            runner.stop()
            return .json(["ok": true, "state": runner.snapshot()])

        case ("GET", "/runstate"):
            return .json(["ok": true, "state": runner.snapshot()])

        case ("GET", "/status"):
            let cfgOK = cfgStore.cfg != nil
            return .json([
                "app": "PGAgent", "version": AppVersion.display,
                "ios": UIDevice.current.systemVersion,
                "httpPort": Int(httpPort),
                "documents": docsURL().path,
                "configLoaded": cfgOK,
                "configError": cfgStore.lastError,
                "configPath": ConfigStore.configPath().path,
                "elements": cfgStore.cfg?.elements.count ?? 0,
                "pages": cfgStore.cfg?.pages.count ?? 0,
                "bleState": ble.state,
                "bleDevices": ble.devices,
                "bleError": ble.lastError,
                "runner": runner.snapshot(),
            ])

        case ("POST", "/reload"):
            let ok = cfgStore.reload()
            // ⭐⭐⭐⭐⭐ §2645 **回带配置自检结果**（照 `Runner` 的「帧龄自检」范式，§2631）
            //
            // ⛔ 为什么要单独回一个字段（而不是只看 `ok`）：
            //   自检不过时 `reload()` **故意不覆盖 `cfg`**（保留上一份有效配置继续跑）
            //   ⇒ 拿 `cfg` 反查**看不到错误** ⇒ 必须由这里把**刚推上来的那个文件**的问题带回来。
            // ✅ **加字段是零破坏性的**：老调用方只读 `ok` / `error` 时行为不变。
            // ⚠️ 语义：`configErrors` 非空且 `ok=false` = **这次被拒绝**；
            //          `configErrors` 非空且 `ok=true`  = **已加载但有缺陷**（照 §2945 的 warnings）。
            //   ⇒ 为了⛔不让调用方误读，另给 `configWarnings`（与 errors **同一个数组**，
            //     语义上：`ok==true` 时它就都是 warnings）。老调用方行为不变。
            let errs = cfgStore.lastConfigErrors
            return .json(["ok": ok, "error": cfgStore.lastError,
                          "configErrors": ok ? [] : errs,
                          "configWarnings": ok ? errs : [],
                          "elements": cfgStore.cfg?.elements.count ?? 0,
                          "pages": cfgStore.cfg?.pages.count ?? 0],
                         status: ok ? 200 : 500)

        // ⭐⭐⭐ §2269 **保存设置**（控制台「保存设置」按钮与 PC 远程设置**同一条路**）
        //
        // 为什么要有 HTTP 入口（⛔ 不只是为了 PC）：
        //   · 让「勾选功能/设时间」这条链路**可被脚本验收**（⛔ 不用靠手点 UI 去测）
        //   · 用户在 PC 上也能改手机设置（推 config 是**整文件覆盖**，这个是**只改几个键**）
        //
        // 请求体：`{"features":[...],"feat_min":{...},"ad_count":6,"ad_dwell":30,...}`
        // ⇒ 只允许写**白名单**里的键（⛔ 不让任意键污染配置）
        case ("POST", "/settings"):
            guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
                return .json(["ok": false, "error": "请求体必须是 JSON 对象"], status: 400)
            }
            // ⭐ 白名单：⛔ 不在表里的键一律忽略（防手滑写坏配置）
            let allowed: Set<String> = [
                "features", "apps", "feat_min", "ad_count", "ad_dwell",
                "entry", "tail",
                "feed_stay_hv", "feed_stay_lv", "feed_gap_min", "feed_gap_max",
                "tag_round_min", "mall_round_min", "mall_browse_min", "mall_min_price",
                "live_stay", "ad_stay_min", "ad_stay_max",
                "loop_frame_max_age", "loop_step_wait", "loop_unknown_limit",
            ]
            var patch: [String: Any?] = [:]
            var ignored: [String] = []
            for (k, v) in obj {
                if allowed.contains(k) { patch[k] = v } else { ignored.append(k) }
            }
            guard !patch.isEmpty else {
                return .json(["ok": false, "error": "没有可写的键",
                              "ignored": ignored.sorted()], status: 400)
            }
            let res = cfgStore.saveSettings(patch)
            log.log("💾 /settings 保存: \(res.ok ? "✅" : "⛔") \(res.msg)"
                + (ignored.isEmpty ? "" : " ｜ 忽略 \(ignored.sorted().joined(separator: ","))"))
            return .json(["ok": res.ok, "msg": res.msg,
                          "saved": patch.keys.sorted(),
                          "ignored": ignored.sorted(),
                          "features": cfgStore.cfg?.settings?.features ?? [],
                          "feat_min": cfgStore.cfg?.settings?.feat_min ?? [:]],
                         status: res.ok ? 200 : 500)

        // ⭐ 读回当前设置（给控制台/PC 看"现在是什么值"）
        case ("GET", "/settings"):
            let s = cfgStore.cfg?.settings
            return .json(["ok": true,
                          "features": s?.features ?? [],
                          "apps": s?.apps ?? [],
                          "feat_min": s?.feat_min ?? [:],
                          "ad_count": s?.ad_count ?? 0,
                          "ad_dwell": s?.ad_dwell ?? 0,
                          "entry": s?.entry ?? "",
                          "tail": s?.tail ?? "",
                          "path": ConfigStore.configPath().path])

        case ("GET", "/config"):
            guard let c = cfgStore.cfg else {
                return .json(["ok": false, "error": cfgStore.lastError], status: 500)
            }
            let els = c.elements.keys.sorted()
            let pgs = c.pages.keys.sorted()
            return .json(["ok": true, "elements": els, "pages": pgs,
                          "loadedAt": cfgStore.loadedAt.map { "\($0)" } ?? "-"])

        case ("GET", "/ocr"):
            let (im, err) = loadImage(r.query)
            guard let img = im else { return .json(["ok": false, "error": err], status: 400) }
            let rec = makeRecognizer()
            let items = rec.ocr(img, minConfidence: 0.3)
            // ⭐ 坐标是**基准像素**（451×977 尺度）—— 与 ROI / 模板 / 点击坐标同一套
            let list: [[String: Any]] = items.map { (t, r, c) in
                ["text": t, "conf": c,
                 "x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
            }
            return .json(["ok": true, "count": list.count,
                          "coordSpace": "base_px_451x977",
                          "ocrScale": Double(Recognizer.ocrScale),
                          "items": list])

        // ⭐⭐⭐⭐ `/recogdiag` —— **识别专项诊断**（§2241）
        //
        // 为什么必须有：移植后最典型的故障就是「全部认成 unknown 然后退出」，
        // 而根因往往是**尺度对不上**（帧 1353 宽 vs 标定 451 宽）。
        // 一条请求看清：帧多大、归一到多少、ROI 落在哪、元素命中没命中。
        case ("GET", "/recogdiag"):
            let (im, err) = loadImage(r.query)
            guard let img = im else {
                return .json(["ok": false, "error": err,
                              "hint": "先 ?img=<Documents 里的文件名>"], status: 400)
            }
            guard let c = cfgStore.cfg else {
                return .json(["ok": false, "error": "配置未加载"], status: 500)
            }
            let rec = makeRecognizer()
            // ⭐ 触发一次识别（内部会归一化，并记下 raw/norm 尺寸）
            _ = rec.ocr(img, minConfidence: 0.3)
            let nav = Navigator(cfg: c, rec: rec, ble: ble) { _ in }
            var hits: [String: Any] = [:]
            for name in c.elements.keys.sorted() {
                if let h = nav.detect(name, img: img) {
                    hits[name] = ["hit": true,
                                  "score": Double(round(h.score * 1000) / 1000),
                                  "x": Int(h.rect.minX), "y": Int(h.rect.minY),
                                  "ev": h.evidence]
                } else {
                    hits[name] = ["hit": false]
                }
            }
            let baseW = c.settings?.base_w ?? 451
            let baseH = c.settings?.base_h ?? 977
            return .json([
                "ok": true,
                "frameRawSize": "\(Int(rec.lastRawSize.width))x\(Int(rec.lastRawSize.height))",
                "frameNormSize": "\(Int(rec.lastNormSize.width))x\(Int(rec.lastNormSize.height))",
                "baseWH": "\(Int(baseW))x\(Int(baseH))",
                // ⭐ 尺度是否已对齐（= 归一化有没有生效）
                "scaleAligned": abs(rec.lastNormSize.width - baseW) < 1
                                && abs(rec.lastNormSize.height - baseH) < 1,
                "page": nav.pageHere(img) ?? "(unknown)",
                "elements": hits,
                "templatesDir": ConfigStore.templatesDir().path,
                "templateCount": (try? FileManager.default
                    .contentsOfDirectory(atPath: ConfigStore.templatesDir().path).count) ?? -1,
            ])

        case ("GET", "/elements"):
            let (im, err) = loadImage(r.query)
            guard let img = im else { return .json(["ok": false, "error": err], status: 400) }
            guard let c = cfgStore.cfg else {
                return .json(["ok": false, "error": "配置未加载，先 POST /reload"], status: 500)
            }
            let nav = Navigator(cfg: c, rec: makeRecognizer(), ble: ble) { _ in }
            var out: [[String: Any]] = []
            for name in c.elements.keys.sorted() {
                if let h = nav.detect(name, img: img) {
                    out.append(["element": name, "hit": true, "score": h.score,
                                "x": h.rect.minX, "y": h.rect.minY,
                                "w": h.rect.width, "h": h.rect.height,
                                "evidence": h.evidence])
                } else {
                    out.append(["element": name, "hit": false])
                }
            }
            return .json(["ok": true, "count": out.count, "results": out])

        // ⭐⭐⭐ `/see` —— **App 自己取画面 + 自己识别**（一步到位，⛔ 不依赖 PC）
        //    这是「以后全部交到手机上」的核心接口。
        case ("GET", "/see"):
            // ① 自己抓帧
            let sem = DispatchSemaphore(value: 0)
            var gotURL: URL?
            var gotErr = ""
            grabber.grab(timeout: 10.0) { u, e in gotURL = u; gotErr = e; sem.signal() }
            _ = sem.wait(timeout: .now() + 14)
            guard let u = gotURL, let img = UIImage(contentsOfFile: u.path) else {
                return .json(["ok": false, "stage": "grab",
                              "error": gotErr.isEmpty ? "抓帧超时" : gotErr], status: 500)
            }
            guard let c = cfgStore.cfg else {
                return .json(["ok": false, "stage": "config",
                              "error": "配置未加载"], status: 500)
            }
            let rec = makeRecognizer()
            let nav = Navigator(cfg: c, rec: rec, ble: ble) { _ in }

            // ② 判页
            let page = nav.pageHere(img) ?? "unknown"

            // ③ 元素检测
            var hits: [[String: Any]] = []
            for name in c.elements.keys.sorted() {
                if let h = nav.detect(name, img: img) {
                    hits.append(["element": name, "score": h.score,
                                 "x": h.rect.minX, "y": h.rect.minY,
                                 "w": h.rect.width, "h": h.rect.height,
                                 "evidence": h.evidence])
                }
            }

            // ④ OCR（可选，?ocr=0 关掉省时间）
            var ocrOut: [[String: Any]] = []
            if r.query["ocr"] != "0" {
                for (t, rr, cf) in rec.ocr(img, minConfidence: 0.3) {
                    ocrOut.append(["text": t, "conf": cf,
                                   "x": rr.minX, "y": rr.minY,
                                   "w": rr.width, "h": rr.height])
                }
            }

            return .json(["ok": true, "file": u.lastPathComponent, "page": page,
                          "hits": hits, "ocr": ocrOut])

        case ("GET", "/page"):
            let (im, err) = loadImage(r.query)
            guard let img = im else { return .json(["ok": false, "error": err], status: 400) }
            guard let c = cfgStore.cfg else {
                return .json(["ok": false, "error": "配置未加载"], status: 500)
            }
            let rec = makeRecognizer()
            let nav = Navigator(cfg: c, rec: rec, ble: ble) { _ in }
            // ⭐ §2980 桌面族页型的**运行时开关**（照 PC `AISJ_DESK_KINDS=1` 的语义）。
            //
            // ## ⛔ 血案：默认参数被编译器**常量折叠**，整支桌面判据从包里消失
            // 0.33 出包后查二进制（十六进制逐字节）：
            // ```
            //   "资源库" (homeLibrary 的唯一输入词)  → MISSING（utf8/utf16/gbk 全 MISSING）
            //   "天气" "日历" (home 的输入词)          → MISSING
            //   "includeDesktop"                      → MISSING
            //   "desktopKinds"                        → MISSING
            // ```
            // 而 `home_library` 页型名、`副桌面(搜索)` `今日视图(日期 ` `桌面第1页(搜索+设置)`
            // 这些**证据串都在**（offset 903600-904288 的常量池）——
            // ⇒ entries 表在、闭包却**没被编译**。
            // 根因：`detect(..., includeDesktop: Bool = false)` 的两个调用点**都没传**这个参数
            //   ⇒ Swift 跨函数常量传播判定它恒 false ⇒ `if !includeDesktop { continue }` 恒成立
            //   ⇒ 桌面分支 = 死代码 ⇒ 连它的字符串字面量一起消除。
            // ⚠️ 这不是"编译器优化无关紧要"：它让 `/page` **永远无法**验证桌面族判据，
            //    而"判据必须能离线复算"是本项目的硬纪律。
            // ✅ 修法：给一个**运行时**来源（查询参数），编译器就无法证明它恒 false。
            let includeDesktop = ["1", "true", "yes"].contains(
                (r.query["desktop"] ?? "").lowercased()
            )
            // ⭐ §2979 两套结果**同时返回**，便于对拍（过渡期用，稳定后只留 unified）
            let here = nav.pageHere(img) ?? "unknown"
            let hereWithIslands = nav.pageHere(img, includeIslands: true) ?? "unknown"
            let pk = PageKinds.detect(img, ocr: RecognizerOcr(rec: rec),
                                      includeDesktop: includeDesktop)
            return .json([
                "ok": true,
                "page": here,
                // ⭐ 统一识别层结果（§2979 新增，唯一判据来源）
                "unified": pk.kind.rawValue,
                "evidence": pk.evidence,
                "order": pk.order == Int.max ? -1 : pk.order,
                // 本次是否启用桌面族判据（= 请求里的 ?desktop=1）
                "includeDesktop": includeDesktop,
                // 旧导航判据（含 island 跳过）—— 过渡期供对拍
                "navLegacy": here,
                // 导航判据但**让孤岛页参与**（§2979 的 includeIslands）
                "navWithIslands": hereWithIslands,
            ])

        case ("POST", "/nav"):
            let (im, err) = loadImage(r.query)
            guard let img = im else { return .json(["ok": false, "error": err], status: 400) }
            guard let dest = r.query["dest"] else {
                return .json(["ok": false, "error": "need ?dest=<page>"], status: 400)
            }
            guard let c = cfgStore.cfg else {
                return .json(["ok": false, "error": "配置未加载"], status: 500)
            }
            var trace: [String] = []
            let nav = Navigator(cfg: c, rec: makeRecognizer(), ble: ble) { trace.append($0) }
            let ok = nav.go(to: dest, img: img)
            return .json(["ok": ok, "dest": dest, "trace": trace])

        // ⭐⭐⭐ §2272 **滑动**（`/swipe?x1=..&y1=..&x2=..&y2=..&ms=..`）
        //
        // 为什么必须补它：切 App 要在桌面上**翻页**找图标（快手极速版在第二页），
        //   而原来**没有**滑动接口 ⇒ 只能用 `?cmd=D:...` 手工拼串口命令
        //   ⇒ 脚本写起来易错，且拿不到"发了几条"的反馈。
        // ⚠️ 坐标是**基准 451×977**，与 `/click` 同一套（⛔ 不是屏幕像素）。
        case ("POST", "/swipe"):
            guard let a1 = r.query["x1"], let b1 = r.query["y1"],
                  let a2 = r.query["x2"], let b2 = r.query["y2"],
                  let x1 = Double(a1), let y1 = Double(b1),
                  let x2 = Double(a2), let y2 = Double(b2) else {
                return .text("need ?x1=..&y1=..&x2=..&y2=..&ms=..", status: 400)
            }
            let bw = cfgStore.cfg?.settings?.base_w ?? 451
            let bh = cfgStore.cfg?.settings?.base_h ?? 977
            let yf = cfgStore.cfg?.settings?.y_fix ?? 4
            let ms = Int(r.query["ms"] ?? "300") ?? 300
            // 档位照 §2253：fast=100 / mid=220 / slow=2000
            let speed: BLEController.SwipeSpeed =
                ms <= 120 ? .fast : (ms >= 1000 ? .slow : .mid)
            let cmd = BLEController.swipe(x1: x1, y1: y1, x2: x2, y2: y2,
                                          speed: speed,
                                          baseW: bw, baseH: bh, yFix: yf)
            let ok = ble.send(cmd)
            // ⭐ 滑完等它走完（`D:` 自带 ms 时长）⇒ 调用方紧接着抓帧才拿得到新画面
            usleep(UInt32(min(3000, ms + 400)) * 1000)
            return .json(["ok": ok, "cmd": cmd, "ms": ms, "speed": "\(speed)",
                          "state": ble.state, "error": ble.lastError])

        // ⭐ 直接发一条 HID 命令（诊断/特殊场景用；`?cmd=P:1,2` 之类）
        case ("POST", "/click"):
            guard let xs = r.query["x"], let ys = r.query["y"],
                  let x = Double(xs), let y = Double(ys) else {
                return .text("need ?x=..&y=..", status: 400)
            }
            let bw = cfgStore.cfg?.settings?.base_w ?? 451
            let bh = cfgStore.cfg?.settings?.base_h ?? 977
            let yf = cfgStore.cfg?.settings?.y_fix ?? 4
            let cmds = BLEController.moveAndClick(x: x, y: y, baseW: bw, baseH: bh, yFix: yf)
            var sent: [String] = []
            // ⭐ §2600：`moveAndClick` 现在返回 `["P:…", "D:…,600"]` —— 第 2 条是**长按 600ms**。
            //   原来的 60ms 间隔会在板子还没走完按住序列时就去发下一条 ⇒ 必须等够。
            //   ⇒ 第 1 条后等 150ms（让库内的 8 帧插值走完），第 2 条后等 900ms（600ms 按压 + 余量）。
            for (i, c) in cmds.enumerated() {
                if ble.send(c) { sent.append(c) }
                usleep(i == 0 ? 150_000 : 900_000)
            }
            return .json(["ok": sent.count == cmds.count, "sent": sent,
                          "state": ble.state, "error": ble.lastError])

        // ⭐⭐⭐⭐ 录屏广播 —— 「眼」的**正路**（荔枝/所有 RPA App 的做法）
        //    ⛔ 不需要快捷指令、⛔ 不需要人手点：
        //    `RPSystemBroadcastPickerView().triggerPicker()` 程序化启动
        //
        // ⚠️⚠️ **`?verify=1` 才是真正可用的那个**（§2240）：
        //    「触发 picker」**不等于**「录屏在跑」——
        //    系统面板弹出后若没人点「开始直播」，或上一次会话半死，
        //    就会「看起来成功、一帧都不来」。
        //    ⇒ `/rec/start?verify=1` 会用**共享容器的帧时间戳**去验证，
        //      不进行就重试（最多 3 轮 × 8 秒）。
        //    ⚠️ 它会**阻塞**最多 ~30 秒 ⇒ 只在 handler 队列上跑（安全）。
        case ("POST", "/rec/start"):
            if r.query["verify"] == "1" || r.query["verify"] == "true" {
                let res = broadcaster.startAndVerify()
                return .json(["ok": res.ok, "waited": res.waited,
                              "state": broadcaster.snapshot()],
                             status: res.ok ? 200 : 500)
            }
            let ok = broadcaster.start()
            return .json(["ok": ok, "state": broadcaster.snapshot()],
                         status: ok ? 200 : 500)

        case ("GET", "/rec/state"):
            return .json(["ok": true, "state": broadcaster.snapshot()])

        // ⭐⭐⭐⭐ `/framediag` —— **「眼」的专项诊断**（§2210 新增）
        //   一条请求看清：共享容器有没有生效、帧文件在哪、多大、多新。
        //   ⛔ 不依赖任何识别/网络，纯本地文件系统 ⇒ 必然秒回。
        case ("GET", "/framediag"):
            return .json([
                "appGroup": AppGroup.snapshot(),
                "broadcaster": broadcaster.snapshot(),
                "recStateSync": broadcaster.snapshot()["frames"] ?? -1,
            ])

        // ⭐ 手动**同步读一次**帧文件（⛔ 不等 timer；排查用）
        case ("POST", "/framepoll"):
            let got = broadcaster.pollFrame()
            return .json(["ok": got, "state": broadcaster.snapshot()])

        // ⭐⭐⭐⭐ 画中画保活（照荔枝的做法，`_note_2011` §7）
        case ("POST", "/pip/start"):
            let ok = pip.start()
            return .json(["ok": ok, "state": pip.snapshot()], status: ok ? 200 : 500)

        case ("POST", "/pip/stop"):
            pip.stop()
            return .json(["ok": true, "state": pip.snapshot()])

        case ("GET", "/pip/state"):
            return .json(["ok": true, "state": pip.snapshot()])

        case ("POST", "/pip/text"):
            if let t = r.query["t"] { pip.text = t }
            return .json(["ok": true, "text": pip.text])

        // ⭐⭐⭐ `/runlog` —— **共享容器里的运行日志**（§2236）
        //    App 退后台 HTTP 不通时，PC 直接
        //    `ios file pull --app-group=<gid> --remote=/Documents/run_status.json`
        case ("GET", "/runlog"):
            var out: [String: Any] = [:]
            if let u = AppGroup.sharedFile("run_status.json"),
               let d = try? Data(contentsOf: u),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                out["status"] = j
            } else {
                out["status"] = "(还没有 run_status.json)"
            }
            if let u = AppGroup.sharedFile("run_trace.log"),
               let s = try? String(contentsOf: u, encoding: .utf8) {
                out["traceTail"] = Array(s.split(separator: "\n").suffix(30)).map(String.init)
            } else {
                out["traceTail"] = []
            }
            out["path"] = AppGroup.sharedFile("run_status.json")?.path ?? "(no group)"
            return .json(out)

        // ⭐⭐⭐⭐⭐ **静音音频保活**（§2235）—— 比 PiP 简单可靠
        //
        // 语义：App 声明了 `UIBackgroundModes:[audio]`，
        //       只要**真的有音频在播**（哪怕是静音），系统就**不挂起**它。
        // ⇒ 这是「App 退后台还能继续跑 Runner」的**正路**。
        case ("POST", "/keepalive/start"):
            let ok = SilentKeepAlive.shared.start()
            return .json(["ok": ok, "state": SilentKeepAlive.shared.snapshot()],
                         status: ok ? 200 : 500)

        case ("POST", "/keepalive/stop"):
            SilentKeepAlive.shared.stop()
            return .json(["ok": true, "state": SilentKeepAlive.shared.snapshot()])

        case ("GET", "/keepalive/state"):
            return .json(["ok": true, "state": SilentKeepAlive.shared.snapshot()])

        // ⭐ 扩展把每一帧 POST 到这里（`http://127.0.0.1:8899/frame`）
        case ("POST", "/frame"):
            let seq = Int(r.query["seq"] ?? "-1") ?? -1
            let ok = broadcaster.onFrame(r.body, seq: seq)
            // ⛔ 不要在这里读 `broadcaster.frames`（@Published，后台线程读是数据竞争）
            //    ⇒ 用 snapshot() 里的值
            let f = (broadcaster.snapshot()["frames"] as? Int) ?? -1
            return .json(["ok": ok, "seq": seq, "bytes": r.body.count, "frames": f])

        // ⭐ 取最近一帧（=「眼」）—— 存成 PNG 供 /ocr /page /elements 用
        case ("GET", "/frame.jpg"):
            guard let d = broadcaster.lastFrame else {
                return .text("还没有帧（先 POST /rec/start）", status: 404)
            }
            return .data(d, type: "image/jpeg")

        case ("POST", "/rec/save"):
            guard let d = broadcaster.lastFrame else {
                return .json(["ok": false, "error": "还没有帧"], status: 404)
            }
            let name = r.query["name"] ?? "lastframe.jpg"
            let u = docsURL().appendingPathComponent(name)
            do {
                try d.write(to: u)
                return .json(["ok": true, "file": name, "bytes": d.count])
            } catch {
                return .json(["ok": false, "error": "\(error)"], status: 500)
            }

        // ── 文件 ──
        case ("GET", "/files"):
            return .json(["documents": docsURL().path, "files": listFiles()])

        // ⭐⭐⭐ `GET /dl?name=X` —— **App 自己吐出文件给 Safari 下载**
        //    手机 Safari 访问 `http://127.0.0.1:8899/dl?name=PGshot.shortcut`
        //    ⇒ 走**本机回环**，⛔ 不依赖 Wi-Fi / VPN / 同网段！
        //    ⇒ 带 `Content-Disposition: attachment` ⇒ Safari 走下载管理器
        //      然后「点开下载」就出「添加快捷指令」导入框（`_note_1938` 的路 A）
        case ("GET", "/dl"):
            guard let name = r.query["name"], !name.isEmpty, !name.contains("..") else {
                return .text("need ?name=", status: 400)
            }
            let u = docsURL().appendingPathComponent(name)
            guard let d = try? Data(contentsOf: u) else {
                return .text("not found: \(name)", status: 404)
            }
            return .data(d, type: "application/octet-stream",
                         extraHeaders: ["Content-Disposition":
                                        "attachment; filename=\"\(u.lastPathComponent)\""])

        // ⭐⭐⭐ `POST /openurl?u=<url>` —— **App 自己用 Safari 打开一个网址**
        //    ⇒ 我把 `/dl` 的地址交给它，它自己开 Safari
        //    ⇒ ⛔ 不需要我在外面用 OCR + ESP32 一个字一个字敲地址
        case ("POST", "/openurl"):
            guard let s = r.query["u"], let url = URL(string: s) else {
                return .text("need ?u=<url>", status: 400)
            }
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { r in ok = r; sem.signal() }
            }
            _ = sem.wait(timeout: .now() + 6)
            log.log("openurl \(s) -> \(ok)")
            return .json(["ok": ok, "url": s])

        // ⛔⛔ §2273 **`/gotoapp` 已删除**（我上一版在这里用 `UIApplication.open` 跳转，
        //    违反用户铁律「**所有操作用 ESP32**」，§2249 逐字）。
        // ✅ 正确做法（照 PC `ensure_app`，`_1377_ad_loop.py:8508`）已在 `/run` 里实现：
        //    **回主屏 → 翻页 → 点桌面图标**，全程 ESP32。
        // ⛔ 不要在这里加回任何"用 App 自己能力跳转"的接口。

        // ⭐⭐⭐ `POST /install-shortcut` —— **一站式：把 PGshot 推给 Safari 下载**
        //    ① App 自己确认 Documents 里有 PGshot.shortcut
        //    ② App 自己开 Safari 到 `http://127.0.0.1:<port>/dl?name=PGshot.shortcut`
        //    ③ Safari 下载 ⇒ 用户点开 ⇒ 导入框
        case ("POST", "/install-shortcut"):
            let nm = r.query["name"] ?? "PGshot.shortcut"
            let u = docsURL().appendingPathComponent(nm)
            guard FileManager.default.fileExists(atPath: u.path) else {
                return .json(["ok": false, "stage": "file",
                              "error": "Documents 里没有 \(nm)（先推文件）",
                              "documents": docsURL().path], status: 404)
            }
            let port = Int(httpPort)
            let s = "http://127.0.0.1:\(port)/dl?name=\(nm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? nm)"
            guard let url = URL(string: s) else {
                return .json(["ok": false, "stage": "url", "error": s], status: 500)
            }
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { r in ok = r; sem.signal() }
            }
            _ = sem.wait(timeout: .now() + 6)
            log.log("install-shortcut \(nm) -> open \(ok) \(s)")
            return .json(["ok": ok, "opened": s, "file": nm,
                          "next": "Safari 会下载 ⇒ 点右下 ↓ 打开下载 ⇒ 点文件 ⇒ 点「添加」"])

        case ("GET", "/file"):
            guard let name = r.query["name"], !name.isEmpty else {
                return .text("need ?name=", status: 400)
            }
            let u = docsURL().appendingPathComponent(name)
            guard let d = try? Data(contentsOf: u) else {
                return .text("not found: \(name)", status: 404)
            }
            return .data(d)

        case ("POST", "/write"):
            guard let name = r.query["name"], !name.isEmpty else {
                return .text("need ?name=", status: 400)
            }
            if name.contains("..") { return .text("bad name", status: 400) }
            let u = docsURL().appendingPathComponent(name)
            if name.contains("/") {
                try? FileManager.default.createDirectory(
                    at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            do {
                try r.body.write(to: u)
                log.log("写文件 \(name) \(r.body.count)B")
                return .json(["ok": true, "name": name, "bytes": r.body.count])
            } catch {
                return .json(["ok": false, "error": "\(error)"], status: 500)
            }

        case ("POST", "/mkdir"):
            guard let name = r.query["name"] else { return .text("need ?name=", status: 400) }
            let u = docsURL().appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return .json(["ok": true, "dir": name])

        case ("DELETE", "/file"):
            guard let name = r.query["name"] else { return .text("need ?name=", status: 400) }
            try? FileManager.default.removeItem(at: docsURL().appendingPathComponent(name))
            return .json(["ok": true, "deleted": name])

        // ── BLE ──
        case ("GET", "/ble/scan"):
            ble.scan { _ in }
            return .json(["ok": true, "state": ble.state, "found": ble.devices])

        case ("GET", "/ble/stop"):
            ble.stopScan()
            return .json(["ok": true, "state": ble.state])

        case ("GET", "/ble/connect"):
            guard let n = r.query["name"] else { return .text("need ?name=", status: 400) }
            ble.connect(n)
            return .json(["ok": true, "state": ble.state])

        // ⭐⭐⭐ `/ble/connect-paired` —— **连已配对的板子**（§2249）
        //
        // 为什么需要：板子 `蓝牙=已连` 时**不再广播** ⇒ `scan` 扫不到
        // ⇒ 只能走 `retrieveConnectedPeripherals` + 上次记住的 UUID。
        // ⭐ 这也是「⛔ 不用开发者模式、全用 ESP32」的前提：
        //    手机要能**自己**连上板子，才能发点击。
        case ("GET", "/ble/connect-paired"):
            let n = ble.connectPaired(hint: r.query["name"])
            return .json(["ok": n > 0, "tried": n, "state": ble.state,
                          "error": ble.lastError])

        // ⭐⭐⭐ `/blediag` —— **BLE 命令通道专项诊断**（§2252）
        //   「手机能不能给板子发命令」是移植的**最后一环** ⇒ 必须有专用诊断。
        //   一条请求看清：认到 NUS 没、服务/特征发现过程、板子回执内容。
        case ("GET", "/blediag"):
            return .json([
                "ok": true,
                "state": ble.state,
                "error": ble.lastError,
                "nusRxFound": ble.nusRxFound,      // ⭐ 认到 NUS 命令特征没
                "lastAck": ble.lastAck,            // ⭐ 板子回执（双向通的证据）
                "threadAck": ble.lastAck.isEmpty
                    ? "（还没收到回执）" : ble.lastAck,
                "probe": ble.probeStore,           // 服务/特征发现过程
                "devices": ble.devices,
                // ⭐ §3310 最近一次**写入**的确认结果
                //   ⛔ 旧实现没有 `didWriteValueFor` ⇒ 写入失败被吞掉、`send` 永远 true
                //   ⇒ 真机出现「App 说发了、板子没收到」（lastAck 停在几分钟前）。
                //   现在把 `writeOK` / `writeErr` 暴露出来，一眼能分清
                //   「链路断了」还是「板子没执行」。
                "writeOK": ble.lastWriteOK,
                "writeErr": ble.lastWriteErr,
            ])

        case ("POST", "/ble/send"):
            guard let c = r.query["cmd"] else { return .text("need ?cmd=", status: 400) }
            let ok = ble.send(c)
            return .json(["ok": ok, "cmd": c, "state": ble.state, "error": ble.lastError],
                         status: ok ? 200 : 500)

        // ── 日志 ──
        case ("GET", "/log"):
            return .json(["lines": log.snapshot()])

        case ("POST", "/log/clear"):
            log.clear()
            return .json(["ok": true])

        default:
            return .json(["error": "no route", "method": r.method, "path": p], status: 404)
        }
    }

    /// 列 Documents（⛔ 不用 enumerator —— 它在 iOS 上会跟符号链接/深目录卡死）
    /// 只列一层 + 已知子目录一层，深度上限写死。
    private func listFiles() -> [[String: Any]] {
        let fm = FileManager.default
        let root = docsURL()
        var out: [[String: Any]] = []

        func addDir(_ dir: URL, depth: Int) {
            guard depth <= 2 else { return }
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
            guard let items = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return }
            for u in items {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let rel = u.path.replacingOccurrences(of: root.path + "/", with: "")
                if isDir {
                    out.append(["name": rel + "/", "bytes": 0, "mtime": "", "dir": true])
                    addDir(u, depth: depth + 1)
                } else {
                    let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                    let mt = (try? u.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? Date(timeIntervalSince1970: 0)
                    out.append(["name": rel, "bytes": sz,
                                "mtime": ISO8601DateFormatter().string(from: mt)])
                }
            }
        }

        addDir(root, depth: 0)
        return out.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

}
