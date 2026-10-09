import SwiftUI

// ⭐ V0/V3 验证版 —— 只做四件事：
//   ① 列出 Documents 目录里的文件（证明「快捷指令写进来的截图」能被读到 = 铁律②落地）
//   ② 扫描 BLE 外设（证明 CoreBluetooth 能用，能找到 ESP32）
//   ③ 打印后台状态（证明 App 被挂起/唤醒的时机）
//   ④ 显示日志（配合 `pymobiledevice3 launch-application --console` 在 Windows 上看）
//
// ⛔ 这一版**不做识别**、**不发 HID**，只验证"管道通不通"。

@main
struct PGAgentApp: App {
    @StateObject private var store = LogStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
    }
}

/// 全局日志（既进内存列表，也走 NSLog ⇒ 能被 `launch-application --console` 抓到）
final class LogStore: ObservableObject {
    @Published var lines: [String] = []
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    func log(_ s: String) {
        let t = fmt.string(from: Date())
        let line = "[\(t)] \(s)"
        NSLog("PGAgent %@", line)          // ← Windows 终端上看这条
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 500 { self.lines.removeFirst(self.lines.count - 500) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: LogStore
    @StateObject private var docs = DocsScanner()
    @StateObject private var ble = BLEScanner()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button("扫 Documents") { docs.scan(store) }
                    Button("扫 BLE") { ble.start(store) }
                    Button("停 BLE") { ble.stop(store) }
                    Button("清空") { store.lines.removeAll() }
                }
                .padding(8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.lines.enumerated()), id: \.offset) { _, l in
                            Text(l)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
            }
            .navigationTitle("PGAgent V0")
            .onAppear {
                store.log("=== PGAgent 启动 ===")
                store.log("Documents = \(DocsScanner.docPath())")
                NotificationCenter.default.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil, queue: .main) { _ in
                        store.log("⏸ didEnterBackground")
                    }
                NotificationCenter.default.addObserver(
                    forName: UIApplication.willEnterForegroundNotification,
                    object: nil, queue: .main) { _ in
                        store.log("▶️ willEnterForeground")
                    }
                docs.scan(store)
            }
        }
        .navigationViewStyle(.stack)
    }
}
