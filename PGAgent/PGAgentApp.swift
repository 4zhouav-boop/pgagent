import SwiftUI
import UIKit

// ⭐ PGAgent v0.2 —— 「AI 能调用」版
//
//   ① Documents 读写（快捷指令写截图进来）
//   ② BLE 连 ESP32 发 HID（点击/滑动）
//   ③ ⭐ HTTP 服务（绑 127.0.0.1）⇒ 主机经 USB 隧道直接调用
//   ④ 日志（NSLog + HTTP /log）
//
// ⛔ 这一版**不做识别**，只把「管道」全部打通，让主机能驱动它。

@main
struct PGAgentApp: App {
    @StateObject private var store = LogStore()
    @StateObject private var ble = BLEController()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).environmentObject(ble)
        }
    }
}

/// 全局日志：内存环形 + NSLog（主机 `dvt launch --stream` 能看）
final class LogStore: ObservableObject {
    @Published private(set) var lines: [String] = []
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
    private let lock = NSLock()

    func log(_ s: String) {
        let line = "[\(fmt.string(from: Date()))] \(s)"
        NSLog("PGAgent %@", line)
        lock.lock()
        lines.append(line)
        if lines.count > 800 { lines.removeFirst(lines.count - 800) }
        lock.unlock()
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock(); lines.removeAll(); lock.unlock()
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: LogStore
    @EnvironmentObject var ble: BLEController
    @StateObject private var http = HTTPServer()
    @State private var router: APIRouter?
    @State private var started = false
    @State private var port: UInt16 = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HTTP 127.0.0.1:\(port == 0 ? "…" : "\(port)")")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text("BLE: \(ble.state)")
                        .font(.system(size: 12, design: .monospaced))
                    Text("Documents: \(DocsScanner.docPath())")
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)

                HStack(spacing: 6) {
                    Button("扫 BLE") { ble.scan { _ in } }
                    Button("停扫") { ble.stopScan() }
                    Button("清日志") { store.clear() }
                }
                .padding(.horizontal, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.snapshot().enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
            }
            .navigationTitle("PGAgent v0.2")
            .onAppear(perform: boot)
        }
        .navigationViewStyle(.stack)
    }

    private func boot() {
        guard !started else { return }
        started = true

        store.log("=== PGAgent v0.2 启动 ===")
        store.log("Documents = \(DocsScanner.docPath())")

        // ⭐ 起 HTTP 服务
        let rt = APIRouter(log: store, ble: ble)
        router = rt
        http.onRequest = { [weak rt] req in
            rt?.handle(req) ?? HTTPServer.Response.text("no router", status: 500)
        }
        http.start(preferredPort: 8899)
        port = http.port
        rt.httpPort = http.port
        store.log("HTTP 已起 127.0.0.1:\(http.port)  err=\(http.lastError)")

        // 通知
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { _ in store.log("⏸ didEnterBackground") }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { _ in store.log("▶️ willEnterForeground") }

        // 开机扫一次 Documents
        store.log("--- 扫 Documents ---")
        let n = (try? FileManager.default
            .contentsOfDirectory(atPath: DocsScanner.docPath()).count) ?? -1
        store.log("共 \(n) 个文件")
    }
}
