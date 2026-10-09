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
    var httpPort: UInt16 = 0

    init(log: LogStore, ble: BLEController, cfgStore: ConfigStore, grabber: ScreenGrabber) {
        self.log = log
        self.ble = ble
        self.cfgStore = cfgStore
        self.grabber = grabber
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
                "app": "PGAgent", "version": "0.4.0",
                "endpoints": ["/status", "/probe", "/reload", "/config", "/elements",
                              "/page", "/nav", "/ocr", "/files", "/file", "/write",
                              "/mkdir", "/ble/scan", "/ble/connect", "/ble/send",
                              "/click", "/log"],
            ])

        // ⭐ 极简探活（⛔ 不碰文件系统、不做识别）—— 用来区分「App 挂了」和「handler 慢」
        case ("GET", "/probe"):
            return .json(["ok": true, "t": Date().timeIntervalSince1970])

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
                          "shortcut": grabber.shortcutName], status: 500)

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

        case ("GET", "/status"):
            let cfgOK = cfgStore.cfg != nil
            return .json([
                "app": "PGAgent", "version": "0.4.0",
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

        // ── 文件 ──
        case ("GET", "/files"):
            return .json(["documents": docsURL().path, "files": listFiles()])

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
