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

    // MARK: - Environment Configs
    @Published var environmentConfigs: [S3Environment: EnvironmentConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(environmentConfigs.mapKeys(\.rawValue)) {
                defaults.set(data, forKey: "environmentConfigs")
            }
        }
    }

    // MARK: - Log
    @Published var logLevel: LogLevel {
        didSet { defaults.set(logLevel.rawValue, forKey: "logLevel") }
    }

    // MARK: - Auto Completion
    @Published var completionCacheTTL: TimeInterval {
        didSet { defaults.set(completionCacheTTL, forKey: "completionCacheTTL") }
    }

    // MARK: - Last used environment
    @Published var lastEnvironment: S3Environment {
        didSet { defaults.set(lastEnvironment.rawValue, forKey: "lastEnvironment") }
    }

    init() {
        pageSize = defaults.integer(forKey: "pageSize").nonZero ?? 200
        maxConcurrentDownloads = defaults.integer(forKey: "maxConcurrentDownloads").nonZero ?? 4
        checksumEnabled = defaults.bool(forKey: "checksumEnabled")
        logLevel = LogLevel(rawValue: defaults.string(forKey: "logLevel") ?? "") ?? .info
        completionCacheTTL = defaults.double(forKey: "completionCacheTTL").nonZero ?? 60
        lastEnvironment = S3Environment(rawValue: defaults.string(forKey: "lastEnvironment") ?? "") ?? .offline

        let defaultDownload = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        downloadDirectory = defaults.string(forKey: "downloadDirectory") ?? defaultDownload

        // 加载环境配置，并迁移旧默认值
        var configs: [S3Environment: EnvironmentConfig] = [
            .offline: .default(for: .offline),
            .production: .default(for: .production)
        ]
        if let data = defaults.data(forKey: "environmentConfigs"),
           let decoded = try? JSONDecoder().decode([String: EnvironmentConfig].self, from: data) {
            for (key, val) in decoded {
                if let env = S3Environment(rawValue: key) {
                    var migratedVal = val
                    // 迁移：旧版默认 offline endpoint 为 localhost:9000，重置为空（AWS 标准）
                    if env == .offline && migratedVal.endpoint == "http://localhost:9000" {
                        migratedVal.endpoint = ""
                        migratedVal.usePathStyle = false
                    }
                    configs[env] = migratedVal
                }
            }
        }
        environmentConfigs = configs
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
