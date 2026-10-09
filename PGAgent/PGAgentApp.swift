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

/// ⚠️ `HTTPServer` 不是 `ObservableObject`（它只管网络，不发 UI 通知）
/// ⇒ 用这个 holder 把它包一层，才能放进 `@StateObject`
final class HTTPServerHolder: ObservableObject {
    let server = HTTPServer()
    @Published var port: UInt16 = 0
    @Published var lastError = ""
}

struct ContentView: View {
    @EnvironmentObject var store: LogStore
    @EnvironmentObject var ble: BLEController
    @StateObject private var http = HTTPServerHolder()
    @StateObject private var cfgStore = ConfigStore()
    @StateObject private var grabber = ScreenGrabber()
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

                // ⭐ 「眼」—— App 自己取画面（触发快捷指令截图）
                HStack(spacing: 6) {
                    Button("📷 抓一帧") {
                        store.log("▶️ 手动抓帧（快捷指令 \(grabber.shortcutName)）")
                        grabber.grab(timeout: 10) { u, e in
                            if let u = u {
                                store.log("✅ 抓到 \(u.lastPathComponent)")
                            } else {
                                store.log("⛔ 抓帧失败：\(e)")
                            }
                        }
                    }
                    Button("只触发") {
                        let ok = grabber.triggerShortcut()
                        store.log("触发快捷指令: \(ok ? "✅ 已发起" : "⛔ \(grabber.lastError)")")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

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
            .navigationTitle("PGAgent v0.4.1")
            .onAppear(perform: boot)
        }
        .navigationViewStyle(.stack)
    }

    private func boot() {
        guard !started else { return }
        started = true

        store.log("=== PGAgent v0.4.1 启动 ===")
        store.log("Documents = \(DocsScanner.docPath())")

        // ⭐ 起 HTTP 服务
        let rt = APIRouter(log: store, ble: ble, cfgStore: cfgStore, grabber: grabber)
        router = rt
        http.server.onRequest = { [weak rt] req in
            rt?.handle(req) ?? HTTPServer.Response.text("no router", status: 500)
        }
        http.server.start(preferredPort: 8899)
        port = http.server.port
        http.port = http.server.port
        http.lastError = http.server.lastError
        rt.httpPort = http.server.port
        store.log("HTTP 已起 127.0.0.1:\(http.server.port)  err=\(http.server.lastError)")

        // ⭐ 读运行时配置（改逻辑只推这个文件，⛔ 不重装）
        ConfigStore.ensureDirs()
        if cfgStore.reload() {
            store.log("✅ 配置已加载：\(cfgStore.cfg?.elements.count ?? 0) 个元素 / \(cfgStore.cfg?.pages.count ?? 0) 个页型")
        } else {
            store.log("⚠️ 配置未加载：\(cfgStore.lastError)")
        }

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
