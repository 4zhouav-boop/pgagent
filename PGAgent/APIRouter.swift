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

            // ⭐⭐⭐⭐⭐ §2273 **切到目标 App —— ⛔ 一律走 ESP32（用户铁律）**
            //
            // ## ⛔⛔ 我上一版（v0.10.30）在这里犯的错
            // 我用 `UIApplication.shared.open("ksnebula://")` 做跳转 ——
            // **那是"用 App 自己的能力跳转"，违反用户铁律**：
            // > 「**所有操作用 ESP32 控制**」（§2249 逐字）
            // > 「**你现在还是全程用开发者权限，说了不要用开发者。所有操作用 ESP32 控制。**」
            //
            // ## ✅ 照抄 PC `ensure_app`（`_1377_ad_loop.py:8508`）
            // ```python
            // go_home(tag)                                  # ① 回主屏（底部上滑）
            // _d, _p = find_desktop_icon_paged(tag, TARGET)  # ② 桌面找图标（**会翻页**）
            // click_at(plog(_p[0], _p[1]))                  # ③ 点它
            // ```
            // ⇒ PC **全程只用 ESP32**（点图标），⛔ 从不调 App 自己的跳转。
            //    手机端必须**同款**。
            //
            // ## ⚠️ 为什么不能"从外面用脚本切"
            // 手机端录屏录的是**当前前台** ⇒ `/run` 必须趁 App 在前台发出来；
            // 而"切 App"如果靠 App 的 `open()`，就又把控制权交给了 App 自己。
            // ⇒ 唯一合规做法：**App 里发 ESP32 命令**（回主屏 + 点图标），
            //    这与 PC 的语义**逐字一致**（PC 也是脚本发串口命令）。
            let wantGoto = (r.query["goto"] ?? "1") != "0"
            var gotoInfo: [String: Any] = ["requested": wantGoto, "via": "ESP32"]
            if wantGoto {
                let which = r.query["app"] ?? (cfgStore.cfg?.settings?.apps?.first ?? "kslite")
                gotoInfo["name"] = which
                // ⛔⛔ §2273 **必须丢到后台队列跑**，⛔ 不能在主线程上 `Thread.sleep`
                //
                // 血案（§2212 同类，崩溃日志实证）：主线程**长时间阻塞** ⇒
                //   SwiftUI 的看门狗直接 `SIGKILL` 整个 App。
                // 而 `switchApp` 里有一串"发命令 + 等界面反应"的 `Thread.sleep`
                //   （回主屏 2.5s + 翻页 1.4s×N + 点击后 6s）⇒ **轻松超过 10 秒**。
                // ⇒ 这里**先用 `asyncAfter` 保证 App 还活着**（起跑后 2 秒），
                //   再**立刻转后台队列**执行真正的切换。
                // ⚠️ `ble.send` / `microphone` 与 `LogStore.log` 都是**线程安全**的
                //   （前者内部串行、后者有锁）⇒ 后台调用安全。
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    DispatchQueue.global(qos: .userInitiated).async {
                        guard let self = self else { return }
                        let ok = self.switchApp(named: which)
                        self.log.log("切换(ESP32) \(which) ⇒ \(ok ? "✅ 已发出点图标" : "⛔ 没找到图标")")
                    }
                }
                gotoInfo["after_s"] = 2.0
            }

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
            return .json(["ok": ok, "error": cfgStore.lastError,
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
            let nav = Navigator(cfg: c, rec: makeRecognizer(), ble: ble) { _ in }
            let here = nav.pageHere(img) ?? "unknown"
            return .json(["ok": true, "page": here])

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
            for c in cmds { if ble.send(c) { sent.append(c) }; usleep(60_000) }
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

    // MARK: - ⭐⭐⭐⭐⭐ §2273 切到目标 App（照 PC `ensure_app`，**全程 ESP32**）

    /// ⭐ 像不像 iOS 桌面/资源库 —— 翻页前的**安全闸**（照 PC `is_homescreen`，L7921）。
    ///
    /// PC 原文：「⛔ 免得 HOME 万一没生效、**在 App 里乱滑**」。
    /// 判据（PC §1642 真机定标）：
    /// ```
    ///   桌面每页底部都有「**搜索**」胶囊 @ ≈(226, 814)
    ///   App 资源库页顶部是「**App 资源库**」搜索框 @ y 60~140
    /// ```
    static func looksLikeDesktop(_ img: UIImage, rec: Recognizer,
                                bw: Double, bh: Double) -> Bool {
        let a = rec.ocrRegion(img, rect: CGRect(x: 150, y: 780, width: 170, height: 80),
                              minConfidence: 0.3)
        if a.contains(where: { $0.0.contains("搜索") }) { return true }
        let b = rec.ocrRegion(img, rect: CGRect(x: 0, y: 60, width: bw, height: 80),
                              minConfidence: 0.3)
        return b.contains(where: { $0.0.contains("资源库") })
    }

    /// 把前台切到 `kslite` / `ks` —— ⛔ **不用 App 的 `open()`**（用户铁律：所有操作走 ESP32）。
    ///
    /// ## 逐条照抄 PC（`_1377_ad_loop.py`）
    /// ```
    /// ensure_app()                    # L8508
    ///   go_home(tag)                  # ① 回主屏（底部快速上滑 / H:HOME 兜底）
    ///   find_desktop_icon_paged(...)  # ② 桌面找图标（**会翻页**，L8001）
    ///   click_at(plog(_p[0], _p[1]))  # ③ 点它
    /// ```
    /// 而 `find_desktop_icon`（L7856）的判据是 **OCR 标签 + 点标签上方**：
    /// ```python
    /// cands ⇒ sorted(最上、再最左)[0]
    /// return (cx, cy - FH(0.055), s)     # ⭐ **图标在标签文字上方 0.055 屏高**
    /// ```
    /// ⛔ 我一开始想**写死图标坐标** —— 那正是 PC 反复踩过的坑
    ///    （换页数/换版式就失效）。✅ 改成**识别标签再算落点**。
    ///
    /// ## ⛔ PC 记过的三条**排除闸**（必须照抄，否则会把弹窗句子当图标）
    /// 真机血案 `_var/_1755_stab_{1..4}.log`：iOS 弹
    /// 「"快手"想访问相机。」（**整句含"快手"**）⇒ 旧判据把它当图标 ⇒
    /// **点了 8 次弹窗、一次没点到真图标** ⇒ 4/4 全废。
    /// ⇒ ① 标签长 ≤6 字 ② 不带引号/句号/问号 ③ 不含弹窗语义词
    ///
    /// - Returns: true = 已发出"点图标"命令（⛔ 不代表真的切过去了）
    @discardableResult
    func switchApp(named which: String) -> Bool {
        let bw = cfgStore.cfg?.settings?.base_w ?? 451
        let bh = cfgStore.cfg?.settings?.base_h ?? 977
        let yf = cfgStore.cfg?.settings?.y_fix ?? 4
        let rec = makeRecognizer()

        func hid(_ cmds: [String], gapUS: UInt32 = 130_000) {
            for c in cmds { _ = ble.send(c); usleep(gapUS) }
        }
        /// 抓当前帧（优先内存帧；没有就轮询一次）
        func frame() -> UIImage? {
            if let d = broadcaster.lastFrame, let im = UIImage(data: d) { return im }
            broadcaster.pollFrame()
            if let d = broadcaster.lastFrame, let im = UIImage(data: d) { return im }
            return nil
        }
        /// PC `find_desktop_icon`：OCR 找标签，返回**图标落点**（标签上方 0.055 屏高）
        func findIcon(_ img: UIImage) -> (CGPoint, String)? {
            let ws = rec.ocrRegion(img, rect: CGRect(x: 0, y: 60, width: bw, height: bh - 60),
                                    minConfidence: 0.3)
            var cands: [(CGPoint, String)] = []
            for (t, r, _c) in ws {
                let s = t.trimmingCharacters(in: .whitespaces)
                if s.isEmpty || !s.contains("快手") { continue }
                // ⛔ 排除闸①：图标名短（弹窗句子长）
                if s.count > 6 { continue }
                // ⛔ 排除闸②：带标点 ⇒ 是句子
                if s.contains(where: { "“”。？！，,".contains($0) }) { continue }
                // ⛔ 排除闸③：弹窗语义词
                if ["想访问", "允许", "用于", "录制", "拍照", "直播"].contains(where: { s.contains($0) }) {
                    continue
                }
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
            let pt = CGPoint(x: pick.0.x, y: pick.0.y - bh * 0.055)
            return (pt, pick.1)
        }

        // ① ⭐⭐⭐ 回主屏 —— **照 PC `go_home`（L7982）逐字**：
        //    **先「底部快速上滑」，不成再补 `H:HOME`**（⛔ 我原来只发 `H:HOME` ⇒ **永远回不去**）
        //
        // ## ⛔⛔ 这是 PC 早查清的元凶（§1645 / §1697d），我照抄漏了
        // PC 原文三条铁律：
        // ```
        //   ① 手法 = **底部快速上滑**（不是 H:HOME）
        //      H:HOME 的真身是 **⌘H 键盘组合键**（走 ID1 键盘通道），
        //      ⛔ **会被前台 App 吃掉**（PC 实测 WorkBuddy 对话页 0 像素变化）⇒ 只当兜底。
        //   ② 起点必须 **y = 971**（贴进 Home Indicator 手势区）
        //      ⛔ 958 差这 10px 就**落在手势区外 ⇒ iOS 不认** ⇒ PC 实测 0/2；
        //      968~971 才 2/2。📏「**起点差 10px**」= "永远回不去主屏"的元凶。
        //   ③ 必须**快**：**120ms** 行、250ms **不行**（PC 实测 0.08% vs 31.96%）。
        // ```
        // ⇒ 而且上滑**直接落到第 1 页（主桌面）**，比 `H:HOME` 更准、还省掉翻页。
        log.log("切换(ESP32) ① 回主屏（底部快速上滑，照 PC `go_home`）")
        _ = ble.send(BLEController.swipe(x1: 225, y1: 971, x2: 225, y2: 300,
                                         speed: .fast,      // ⭐ fast = 100ms ≈ PC 的 120ms
                                         baseW: bw, baseH: bh, yFix: yf))
        Thread.sleep(forTimeInterval: 1.7)
        // 兜底：若仍不像桌面，再补 H:HOME（⌘H，可能被 App 吃）
        if let img = frame(), !Self.looksLikeDesktop(img, rec: rec, bw: bw, bh: bh) {
            log.log("切换(ESP32) ①b 上滑后不像桌面 ⇒ 补一发 H:HOME（⌘H 兜底）")
            _ = ble.send("H:HOME\n")
            Thread.sleep(forTimeInterval: 1.8)
        }

        // ② 当页找；找不到就**翻页**
        //
        // ⭐ 照 PC `find_desktop_icon_paged`（L8001）的**顺序与安全闸**：
        // ```
        //   ① 先看当页
        //   ② ⛔ **安全闸**：这页**不像 iOS 桌面**（底部没「搜索」胶囊）⇒ **不翻页**
        //      （PC 原文：「免得**在 App 里乱滑**」）
        //   ③ **先右滑**回退（第 1 页在最左端）→ ④ 再**左滑**前进
        // ```
        // ⛔ 我上一版**只左滑**、而且**没有安全闸** ⇒ 一路滑进「App 资源库」
        //    （真机 `_var/_sf1_n.png` 铁证：停在资源库页，所以永远找不到图标）。
        if let img = frame(), let (pt, label) = findIcon(img) {
            log.log("切换(ESP32) ② 当页命中「\(label)」⇒ 点 (\(Int(pt.x)),\(Int(pt.y)))")
            hid(BLEController.moveAndClick(x: Double(pt.x), y: Double(pt.y),
                                           baseW: bw, baseH: bh, yFix: yf))
            Thread.sleep(forTimeInterval: 6.0)      // 照 PC `wait(6.5)`
            return true
        }
        // ⛔ 安全闸（照 PC）：不像桌面就**不翻页**（否则会在 App 里乱滑）
        if let img = frame(), !Self.looksLikeDesktop(img, rec: rec, bw: bw, bh: bh) {
            log.log("切换(ESP32) ⛔ 这一页**不像 iOS 桌面**（底部没「搜索」胶囊）"
                    + " ⇒ **不翻页**（照 PC，免得在 App 里乱滑）")
            return false
        }
        // ③ 先**右滑**回退到第 1 页，再 ④ **左滑**前进（PC 同序）
        var tried = 0
        func tryPage(_ desc: String) -> Bool {
            guard let img = frame() else { return false }
            if let (pt, label) = findIcon(img) {
                log.log("切换(ESP32) ③ \(desc) 命中「\(label)」⇒ 点 (\(Int(pt.x)),\(Int(pt.y)))")
                hid(BLEController.moveAndClick(x: Double(pt.x), y: Double(pt.y),
                                               baseW: bw, baseH: bh, yFix: yf))
                Thread.sleep(forTimeInterval: 6.0)
                return true
            }
            return false
        }
        for k in 1...6 {                                   // 右滑（回退）
            hid([BLEController.swipe(x1: 60, y1: 500, x2: 380, y2: 500,
                                     speed: .mid, baseW: bw, baseH: bh, yFix: yf)])
            Thread.sleep(forTimeInterval: 1.3)
            tried += 1
            if tryPage("右滑第 \(k) 次") { return true }
        }
        for k in 1...8 {                                   // 左滑（前进）
            hid([BLEController.swipe(x1: 380, y1: 500, x2: 60, y2: 500,
                                     speed: .mid, baseW: bw, baseH: bh, yFix: yf)])
            Thread.sleep(forTimeInterval: 1.3)
            tried += 1
            if tryPage("左滑第 \(k) 次") { return true }
        }
        log.log("切换(ESP32) ⛔ 翻了 \(tried) 页都没找到「\(which)」图标 ⇒ **不放枪**（铁律②）")
        return false
    }
}
