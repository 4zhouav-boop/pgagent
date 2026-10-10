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
    @StateObject private var broadcaster = BroadcastStarter()
    @StateObject private var pip = PiPManager()
    @State private var router: APIRouter?
    @State private var started = false
    @State private var port: UInt16 = 0
    /// ⭐ 自主循环的运行状态（UI 显示）
    @State private var runState = "-"
    /// ⭐ 循环实例（boot 里创建，UI 按钮用）
    @State private var runnerRef: Runner?

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

                // ⭐⭐⭐⭐ 「眼」正路 —— 录屏广播（⛔ 不用快捷指令、⛔ 不用人手点）
                HStack(spacing: 6) {
                    Button("🔴 开录屏") {
                        let ok = broadcaster.start()
                        store.log("▶️ 启动录屏广播: \(ok ? "✅ 已触发" : "⛔ \(broadcaster.lastError)")")
                    }
                    Text("帧 \(broadcaster.frames)")
                        .font(.system(size: 10, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // 「眼」备选 —— 快捷指令截图
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

                // ⭐⭐⭐⭐ 「活」—— 画中画保活（照荔枝的做法）
                HStack(spacing: 6) {
                    Button("🖼 开画中画") {
                        let ok = pip.start()
                        store.log("▶️ 启动画中画保活: \(ok ? "✅ 已发起" : "⛔ \(pip.lastError)")")
                    }
                    Button("关") { pip.stop() }
                    Text(pip.active ? "PiP 活" : "PiP 停")
                        .font(.system(size: 10, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                // ⭐⭐⭐ 自主循环 —— App 自己在手机上跑（⛔ 不需要 PC / USB / 开发者模式）
                HStack(spacing: 6) {
                    Button("▶️ 开始跑") {
                        store.log("▶️ 手动启动自主循环")
                        runnerRef?.start(dest: nil)
                    }
                    Button("⛔ 停") { runnerRef?.stop() }
                    Text(runState)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
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
            .navigationTitle("PGAgent v0.9.0")
            .onAppear(perform: boot)
        }
        .navigationViewStyle(.stack)
    }

    private func boot() {
        guard !started else { return }
        started = true

        store.log("=== PGAgent v0.9.0 启动 ===")
        store.log("Documents = \(DocsScanner.docPath())")

        // ⭐ 自主循环（App 自己在手机上跑，⛔ 不需要 PC）
        let runner = Runner(cfgStore: cfgStore, grabber: grabber, ble: ble,
                              broadcaster: broadcaster) { s in
            store.log(s)
        }
        runnerRef = runner
        // 每秒刷新一次 UI 上的循环状态
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let s = runner.snapshot()
            let running = (s["running"] as? Bool) ?? false
            let step = (s["step"] as? Int) ?? 0
            let page = (s["page"] as? String) ?? "-"
            let reason = (s["stopReason"] as? String) ?? "-"
            runState = running ? "跑中 步\(step) \(page)" : "停 \(reason)"
            // ⭐ 把状态同步到画中画（荔枝的做法：PiP 里显示进度）
            if pip.active { pip.text = runner.pipLine() }
        }

        // ⭐ 起 HTTP 服务
        let rt = APIRouter(log: store, ble: ble, cfgStore: cfgStore,
                           grabber: grabber, runner: runner,
                           broadcaster: broadcaster, pip: pip)
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
