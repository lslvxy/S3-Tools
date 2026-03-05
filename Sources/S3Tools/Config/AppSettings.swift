import Foundation
import Combine

final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    // MARK: - Pagination
    @Published var pageSize: Int {
        didSet { defaults.set(pageSize, forKey: "pageSize") }
    }

    // MARK: - Download
    @Published var maxConcurrentDownloads: Int {
        didSet { defaults.set(maxConcurrentDownloads, forKey: "maxConcurrentDownloads") }
    }

    @Published var downloadDirectory: String {
        didSet { defaults.set(downloadDirectory, forKey: "downloadDirectory") }
    }

    @Published var checksumEnabled: Bool {
        didSet { defaults.set(checksumEnabled, forKey: "checksumEnabled") }
    }

    // MARK: - Log
    @Published var logLevel: LogLevel {
        didSet { defaults.set(logLevel.rawValue, forKey: "logLevel") }
    }

    // MARK: - Auto Completion
    @Published var completionCacheTTL: TimeInterval {
        didSet { defaults.set(completionCacheTTL, forKey: "completionCacheTTL") }
    }

    // MARK: - Last used profile name
    @Published var lastProfileName: String {
        didSet { defaults.set(lastProfileName, forKey: "lastProfileName") }
    }

    // MARK: - Bookmarks
    @Published var bookmarks: [BookmarkEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(bookmarks) {
                defaults.set(data, forKey: "bookmarks")
            }
        }
    }

    init() {
        pageSize = defaults.integer(forKey: "pageSize").nonZero ?? 200
        maxConcurrentDownloads = defaults.integer(forKey: "maxConcurrentDownloads").nonZero ?? 4
        checksumEnabled = defaults.bool(forKey: "checksumEnabled")
        logLevel = LogLevel(rawValue: defaults.string(forKey: "logLevel") ?? "") ?? .info
        completionCacheTTL = defaults.double(forKey: "completionCacheTTL").nonZero ?? 60
        lastProfileName = defaults.string(forKey: "lastProfileName") ?? ""

        let defaultDownload = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        downloadDirectory = defaults.string(forKey: "downloadDirectory") ?? defaultDownload

        // 加载书签（首次启动时以内置列表为默认值）
        if let data = defaults.data(forKey: "bookmarks"),
           let saved = try? JSONDecoder().decode([BookmarkEntry].self, from: data) {
            bookmarks = saved
        } else {
            bookmarks = BookmarkEntry.defaults
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
