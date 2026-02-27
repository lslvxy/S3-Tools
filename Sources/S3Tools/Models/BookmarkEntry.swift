import Foundation

/// 用户可编辑的路径书签（取代静态 QuickJumpEntry.all）
struct BookmarkEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var path: String        // 完整对象前缀（含文件名前缀部分）

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    /// 提取目录前缀（strip 最后一个 / 之后的文件名前缀）
    var directoryPrefix: String {
        if path.hasSuffix("/") { return path }
        guard let slashIndex = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex...slashIndex])
    }

    // MARK: - Default seeds (from original QuickJumpEntry)

    static let defaults: [BookmarkEntry] = QuickJumpEntry.all.map {
        BookmarkEntry(name: $0.id, path: $0.path)
    }
}
