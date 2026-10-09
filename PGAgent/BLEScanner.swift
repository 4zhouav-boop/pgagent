import Foundation
import CoreBluetooth

/// 扫 BLE 外设 —— 证明 CoreBluetooth 能用，并且**能找到那块 ESP32**。
///
/// ⭐ 这是「手」那一侧的第一根管子：
///    App 扫到 ESP32 → 连上它的 GATT 服务 → 写 characteristic 发 `P:x,y` / `C:L`
///
/// ⛔ 这一版**只扫、只列**，不连接、不写。
final class BLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    private var central: CBCentralManager?
    private var store: LogStore?
    private var seen: Set<UUID> = []

    func start(_ store: LogStore) {
        self.store = store
        self.seen.removeAll()
        let st = CBCentralManager.authorization
        store.log("--- BLE 启动（授权状态: \(BLEScanner.authText(st))）---")
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop(_ store: LogStore) {
        central?.stopScan()
        central = nil
        store.log("--- BLE 已停 ---")
    }

    static func authText(_ s: CBManagerAuthorization) -> String {
        switch s {
        case .allowedAlways: return "allowedAlways"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    private func stateText(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "?"
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        store?.log("BLE state = \(stateText(central.state))")
        if central.state == .poweredOn {
            // 扫所有设备（不过滤 service，先看能不能看到东西）
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            store?.log("开始扫描（nil filter，全部外设）…")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard !seen.contains(peripheral.identifier) else { return }
        seen.insert(peripheral.identifier)
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "(无名)"
        let svc = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString }.joined(separator: ",") ?? "-"
        store?.log("🔵 \(name)  id=\(peripheral.identifier.uuidString.prefix(8))  rssi=\(RSSI)  svc=[\(svc)]")
    }
}
