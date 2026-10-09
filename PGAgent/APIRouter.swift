import Foundation
import UIKit

/// ⭐ HTTP API 路由 —— 主机（经 USB 隧道）调用 App 的唯一入口。
///
/// 设计原则（`_note_1801` §4）：
///   主机侧 `pymobiledevice3 usbmux forward 8899 8899` 之后，
///   `curl http://127.0.0.1:8899/<path>` 就能直接驱动 App。
///
/// 接口（全部返回 JSON）：
///   GET  /                  服务信息
///   GET  /status            设备/App/HTTP/BLE 状态
///   GET  /files             列 Documents 里的文件（截图）
///   GET  /file?name=X       取文件（base64）
///   POST /write?name=X      写文件（body 为原始字节）← ⭐ 主机可直接注入截图
///   DELETE /file?name=X     删文件
///   GET  /ble/scan          扫 BLE 外设（异步，返回已发现的）
///   GET  /ble/connect?name=X 连 ESP32
///   POST /ble/send?cmd=X    发一条 HID 命令（如 P:100,200）
///   POST /click?x=..&y=..   移动并点击（自动换算成 HID 坐标）
///   GET  /log               取最近的 App 日志
///   POST /log/clear         清日志
final class APIRouter {

    let docs = DocsScanner()
    let log: LogStore
    let ble: BLEController
    var httpPort: UInt16 = 0

    init(log: LogStore, ble: BLEController) {
        self.log = log
        self.ble = ble
    }

    func handle(_ r: HTTPServer.Request) -> HTTPServer.Response {
        let p = r.path
        log.log("API \(r.method) \(p)")

        switch (r.method, p) {

        case ("GET", "/"):
            return .json([
                "app": "PGAgent",
                "version": "0.2.0",
                "bundle": Bundle.main.bundleIdentifier ?? "?",
                "endpoints": ["/status", "/files", "/file", "/write", "/ble/scan",
                              "/ble/connect", "/ble/send", "/click", "/log"],
            ])

        case ("GET", "/status"):
            return .json([
                "app": "PGAgent",
                "ios": UIDevice.current.systemVersion,
                "model": UIDevice.current.model,
                "httpPort": Int(httpPort),
                "documents": DocsScanner.docPath(),
                "fileCount": (try? FileManager.default
                    .contentsOfDirectory(atPath: DocsScanner.docPath()).count) ?? -1,
                "bleState": ble.state,
                "bleDevices": ble.devices,
                "bleError": ble.lastError,
                "documentsVisibleToFilesApp": Bundle.main
                    .object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool ?? false,
            ])

        case ("GET", "/files"):
            return .json(["documents": DocsScanner.docPath(),
                          "files": listFiles()])

        case ("GET", "/file"):
            guard let name = r.query["name"], !name.isEmpty else {
                return .text("need ?name=", status: 400)
            }
            let u = URL(fileURLWithPath: DocsScanner.docPath()).appendingPathComponent(name)
            guard let d = try? Data(contentsOf: u) else {
                return .text("not found: \(name)", status: 404)
            }
            return .data(d)

        case ("POST", "/write"):
            guard let name = r.query["name"], !name.isEmpty else {
                return .text("need ?name=", status: 400)
            }
            if name.contains("/") || name.contains("..") {
                return .text("bad name", status: 400)
            }
            let u = URL(fileURLWithPath: DocsScanner.docPath()).appendingPathComponent(name)
            do {
                try r.body.write(to: u)
                log.log("写文件 \(name) \(r.body.count)B")
                return .json(["ok": true, "name": name, "bytes": r.body.count])
            } catch {
                return .json(["ok": false, "error": "\(error)"], status: 500)
            }

        case ("DELETE", "/file"):
            guard let name = r.query["name"] else { return .text("need ?name=", status: 400) }
            let u = URL(fileURLWithPath: DocsScanner.docPath()).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: u)
            return .json(["ok": true, "deleted": name])

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

        case ("POST", "/click"):
            guard let xs = r.query["x"], let ys = r.query["y"],
                  let x = Double(xs), let y = Double(ys) else {
                return .text("need ?x=..&y=..", status: 400)
            }
            let cmds = BLEController.moveAndClick(x: x, y: y)
            var sent: [String] = []
            for c in cmds {
                if ble.send(c) { sent.append(c) }
                usleep(60_000)
            }
            return .json(["ok": sent.count == cmds.count, "sent": sent,
                          "state": ble.state, "error": ble.lastError])

        case ("GET", "/log"):
            return .json(["lines": log.snapshot()])

        case ("POST", "/log/clear"):
            log.clear()
            return .json(["ok": true])

        default:
            return .json(["error": "no route", "method": r.method, "path": p], status: 404)
        }
    }

    private func listFiles() -> [[String: Any]] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: DocsScanner.docPath())
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { u in
            let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let mt = (try? u.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date(timeIntervalSince1970: 0)
            return ["name": u.lastPathComponent,
                    "bytes": sz,
                    "mtime": ISO8601DateFormatter().string(from: mt)]
        }
    }
}
