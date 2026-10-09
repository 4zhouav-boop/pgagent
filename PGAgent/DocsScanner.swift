import Foundation

/// 扫 App 自己的 Documents 目录 —— 快捷指令「存储到文件」写进来的截图在这。
///
/// ⭐ `_note_1799` 已实测：外部（AFC / 快捷指令）写进来的文件，App 能读到。
/// ⛔ 之所以能读到，是因为 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`（见 project.yml）。
final class DocsScanner: ObservableObject {

    static func docPath() -> String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }

    /// 返回 (文件名, 字节数, 修改时间) 列表
    static func list() -> [(String, Int, Date)] {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { u in
            let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let mt = (try? u.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date(timeIntervalSince1970: 0)
            return (u.lastPathComponent, sz, mt)
        }
    }

    func scan(_ store: LogStore) {
        store.log("--- 扫 Documents: \(DocsScanner.docPath()) ---")
        let files = DocsScanner.list()
        if files.isEmpty {
            store.log("（空）—— 还没有文件写进来")
            return
        }
        for (n, sz, mt) in files {
            store.log("  \(n)  \(sz) B  \(mt)")
        }
        store.log("共 \(files.count) 个文件")
    }
}
