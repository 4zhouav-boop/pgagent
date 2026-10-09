import Foundation
import CoreBluetooth

/// 连 ESP32 并写 HID 命令（PG 已有的 `P:x,y` / `C:L` / `D:...` 协议）。
///
/// ⭐ 沿用 `_note_1799` 已验证的东西：
///   - 前台用 CoreBluetooth **不需要 entitlement**（免费 Apple ID 可用）
///   - 命令格式与生产脚本里的 `ks_io.py` 完全一致 ⇒ 主机侧逻辑不用改
///
/// ⛔ 本类只做「连接 + 写字节」，不做任何识别决策。
final class BLEController: NSObject, ObservableObject {

    @Published private(set) var state = "idle"
    @Published private(set) var devices: [String] = []
    @Published private(set) var lastError = ""

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var scanStore: ((String) -> Void)?

    /// ESP32 常见的 HID/透传服务 UUID（PG 板子用的是 Nordic UART 风格的透传）
    /// ⚠️ 真机实测后按需调整；也支持不过滤扫描（nil）
    static let candidateServiceUUIDs: [CBUUID] = [
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),   // Nordic UART Service
        CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB"),   // 常见透传
        CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB"),   // HID over GATT
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scan(_ onFound: @escaping (String) -> Void) {
        scanStore = onFound
        devices.removeAll()
        guard central.state == .poweredOn else {
            state = "bt-\(central.state.rawValue)"
            return
        }
        state = "scanning"
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        state = "idle"
    }

    func connect(_ nameOrId: String) {
        guard let p = foundPeripherals.first(where: {
            ($0.name ?? "").contains(nameOrId) || $0.identifier.uuidString.hasPrefix(nameOrId)
        }) else {
            lastError = "没找到外设: \(nameOrId)"
            return
        }
        target = p
        p.delegate = self
        state = "connecting"
        central.connect(p, options: nil)
    }

    /// 写一条 HID 命令（自动补 \n，PG 固件按行解析）
    @discardableResult
    func send(_ cmd: String) -> Bool {
        guard let ch = writeChar, let p = target else {
            lastError = "未连接（writeChar=\(writeChar == nil ? "nil" : "ok")）"
            return false
        }
        var s = cmd
        if !s.hasSuffix("\n") { s += "\n" }
        guard let d = s.data(using: .ascii) else {
            lastError = "命令不是 ASCII: \(cmd)"
            return false
        }
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(d, for: ch, type: type)
        return true
    }

    /// ⭐ 把 PG 的坐标（基准 451×977）转成 HID 的 0..32767
    static func moveAndClick(x: Double, y: Double) -> [String] {
        let hx = Int((x / 451.0) * 32767.0)
        let hy = Int(((y + 4.0) / 977.0) * 32767.0)   // Y_FIX = 4（与生产脚本一致）
        return ["P:\(hx),\(hy)", "C:L"]
    }

    private var foundPeripherals: [CBPeripheral] = []
}

extension BLEController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        state = "bt-\(c.state.rawValue)"
        if c.state != .poweredOn { lastError = "蓝牙不可用 (state=\(c.state.rawValue))" }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !foundPeripherals.contains(where: { $0.identifier == p.identifier }) else { return }
        foundPeripherals.append(p)
        let n = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "(无名)"
        let line = "\(n) | \(p.identifier.uuidString.prefix(8)) | rssi=\(RSSI)"
        devices.append(line)
        scanStore?(line)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        state = "connected:\(p.name ?? "?")"
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        state = "connect-failed"
        lastError = "连接失败: \(error?.localizedDescription ?? "?")"
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        state = "disconnected"
        writeChar = nil
    }
}

extension BLEController: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                if writeChar == nil { writeChar = ch }   // 取第一个可写的
            }
        }
        if writeChar != nil {
            state = "ready:\(p.name ?? "?")"
        } else {
            lastError = "外设没找到可写 characteristic"
        }
    }
}
