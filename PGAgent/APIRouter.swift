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
                              "/ble/connect", "/ble/connect-paired", "/ble/send", "/click", "/log"],
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
            return .json(["ok": true, "started": true, "keepAlive": ka,
                          "dest": r.query["dest"] ?? cfgStore.cfg?.settings?.target ?? "center",
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
            let list: [[String: Any]] = items.map { (t, r, c) in
                ["text": t, "conf": c,
                 "x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
            }
            return .json(["ok": true, "count": list.count, "items": list])

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
