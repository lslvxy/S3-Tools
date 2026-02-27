import Foundation

struct S3Object: Identifiable, Hashable {
    let id: String
    let key: String
    let size: Int64?
    let lastModified: Date?
    let eTag: String?
    let isDirectory: Bool
    let storageClass: String?

    init(key: String, size: Int64? = nil, lastModified: Date? = nil, eTag: String? = nil, isDirectory: Bool = false, storageClass: String? = nil) {
        self.id = key
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
        self.isDirectory = isDirectory
        self.storageClass = storageClass
    }

    /// 在当前 prefix 下显示的文件名或目录名
    var displayName: String {
        if isDirectory {
            let parts = key.split(separator: "/", omittingEmptySubsequences: true)
            return (parts.last.map(String.init) ?? key) + "/"
        }
        return key.split(separator: "/").last.map(String.init) ?? key
    }

    var formattedSize: String {
        guard let size = size else { return "-" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var formattedDate: String {
        guard let date = lastModified else { return "-" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Sort helpers (non-optional, Comparable)
    /// 排序用名称（目录优先 + 小写）
    var sortableName: String { (isDirectory ? "0_" : "1_") + displayName.lowercased() }
    /// 排序用大小（目录 = -1）
    var sortableSize: Int64 { size ?? (isDirectory ? -1 : 0) }
    /// 排序用时间（nil 排到最后）
    var sortableDate: Date { lastModified ?? .distantPast }
}

struct ListObjectsResult {
    let objects: [S3Object]
    let nextToken: String?
    let prefix: String
    let bucket: String
}
