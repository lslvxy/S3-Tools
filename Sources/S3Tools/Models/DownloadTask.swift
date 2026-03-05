import Foundation

enum DownloadStatus: Equatable {
    case pending
    case inProgress(Double)  // 0.0 ~ 1.0
    case completed
    case failed(String)
    case cancelled

    var displayText: String {
        switch self {
        case .pending: return "等待中"
        case .inProgress(let p): return String(format: "%.0f%%", p * 100)
        case .completed: return "完成"
        case .failed(let msg): return "失败: \(msg)"
        case .cancelled: return "已取消"
        }
    }

    var progress: Double {
        switch self {
        case .pending: return 0
        case .inProgress(let p): return p
        case .completed: return 1.0
        case .failed: return 0
        case .cancelled: return 0
        }
    }
}

struct DownloadTask: Identifiable {
    let id: UUID
    let key: String
    let bucket: String
    let size: Int64
    let destinationDir: URL
    var status: DownloadStatus
    var localURL: URL?
    var startedAt: Date?
    var completedAt: Date?
    var bytesDownloaded: Int64

    init(key: String, bucket: String, size: Int64, destinationDir: URL) {
        self.id = UUID()
        self.key = key
        self.bucket = bucket
        self.size = size
        self.destinationDir = destinationDir
        self.status = .pending
        self.bytesDownloaded = 0
    }

    var fileName: String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    var destinationURL: URL {
        destinationDir.appendingPathComponent(fileName)
    }

    var speedText: String {
        guard let start = startedAt, case .inProgress = status else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return "" }
        let bytesPerSec = Double(bytesDownloaded) / elapsed
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec), countStyle: .file) + "/s"
    }
}
