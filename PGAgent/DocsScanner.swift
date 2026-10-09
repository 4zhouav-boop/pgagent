import Foundation

/// 扫 App 自己的 Documents 目录 —— 证明「快捷指令『存储到文件』写进来的截图」能被读到。
///
/// ⭐ 这是整条「手机单机」路线的**第一根管子**：
///    快捷指令截屏 → 写入 Documents → 这里读到 → （后续做识别）
///
/// ⛔ 之所以必须开 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`（见 project.yml），
///    是因为只有开了这两个键，App 的 Documents 才会出现在「文件」App 里，
///    快捷指令的「存储到文件」才选得到它。
final class DocsScanner: ObservableObject {

    static func docPath() -> String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    func scan(_ store: LogStore) {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        store.log("--- 扫 Documents: \(dir.path) ---")
        do {
            let items = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            if items.isEmpty {
                store.log("（空）—— 还没有文件写进来")
                return
            }
            for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                let mt = (try? u.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate)
                store.log("  \(u.lastPathComponent)  \(sz) B  \(mt.map { "\($0)" } ?? "-")")
            }
            store.log("共 \(items.count) 个文件")
        } catch {
            store.log("⛔ 读 Documents 失败: \(error)")
        }
    }
}
