import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    // MARK: - Environment
    @Published var currentEnvironment: S3Environment = .offline
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var isUploadEnabled: Bool = false  // offline 环境上传开关

    // MARK: - Buckets & Navigation
    @Published var buckets: [String] = []
    @Published var selectedBucket: String? = nil
    @Published var currentPrefix: String = ""
    @Published var objects: [S3Object] = []
    @Published var selectedObjects: Set<String> = []

    // MARK: - Pagination
    @Published var continuationToken: String? = nil
    @Published var hasMorePages: Bool = false
    @Published var currentPage: Int = 1
    @Published var isLoading: Bool = false

    // MARK: - Filter
    @Published var filterPattern: String = ""
    @Published var filteredObjects: [S3Object] = []
    /// 过滤激活时全量加载的所有对象（跨分页）
    @Published var allObjects: [S3Object] = []
    @Published var isLoadingAll: Bool = false

    // MARK: - Download
    @Published var downloadTasks: [DownloadTask] = []
    @Published var downloadDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    // MARK: - Logs
    @Published var logEntries: [LogEntry] = []

    // MARK: - Path Completion
    @Published var completionSuggestions: [String] = []
    @Published var showCompletions: Bool = false

    // MARK: - Error
    @Published var currentError: AppError? = nil
    @Published var showError: Bool = false

    // MARK: - Services
    private(set) var s3Service: S3Service?
    private(set) var downloadManager: DownloadManager
    let credentialsManager = CredentialsManager()
    var appSettings = AppSettings()
    let appLogger = AppLogger.shared

    // MARK: - Cache
    /// 每条缓存保存首页结果，key = "bucket\0prefix"
    private struct CachedPage {
        let objects: [S3Object]
        let nextToken: String?
        let timestamp: Date
    }
    private var objectCache: [String: CachedPage] = [:]
    private let cacheTTL: TimeInterval = 300  // 5 分钟

    /// 全量对象缓存（用于跨分页过滤），key = "bucket\0prefix\0all"
    private struct AllObjectsCache {
        let objects: [S3Object]
        let timestamp: Date
    }
    private var allObjectsCache: [String: AllObjectsCache] = [:]

    private func cacheKey(bucket: String, prefix: String) -> String { "\(bucket)\0\(prefix)" }
    private func allCacheKey(bucket: String, prefix: String) -> String { "\(bucket)\0\(prefix)\0all" }

    private var filterCancellable: AnyCancellable?

    init() {
        self.downloadManager = DownloadManager()
        self.isUploadEnabled = false

        // 监听 filter 变化：空则直接过滤当前页；非空则全量加载后过滤
        filterCancellable = $filterPattern
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] pattern in
                guard let self else { return }
                if pattern.isEmpty {
                    self.filteredObjects = self.objects
                } else {
                    Task { await self.loadAllAndFilter(pattern: pattern) }
                }
            }
    }

    // MARK: - Environment Switching

    func switchEnvironment(to env: S3Environment) async {
        connectionStatus = .connecting
        selectedBucket = nil
        currentPrefix = ""
        objects = []
        allObjects = []
        buckets = []
        currentPage = 1
        continuationToken = nil
        filterPattern = ""
        objectCache.removeAll()
        allObjectsCache.removeAll()  // 切换环境时清空全量缓存

        do {
            let credentials = try credentialsManager.loadCredentials(for: env)
            let config = appSettings.environmentConfigs[env] ?? EnvironmentConfig.default(for: env)
            let service = try await S3Service(
                credentials: credentials,
                config: config,
                environment: env
            )
            self.s3Service = service
            self.currentEnvironment = env
            self.connectionStatus = .connected
            self.isUploadEnabled = false

            appLogger.log(action: "切换环境", detail: "切换到 \(env.displayName)", level: .info)
            await loadBuckets()
        } catch {
            self.connectionStatus = .failed(error.localizedDescription)
            self.s3Service = nil
            showAppError(AppError.from(error))
            appLogger.log(action: "切换环境失败", detail: error.localizedDescription, level: .error)
        }
    }

    // MARK: - Bucket Operations

    func loadBuckets() async {
        guard let service = s3Service else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await service.listBuckets()
            self.buckets = result
            appLogger.log(action: "列出 Buckets", detail: "共 \(result.count) 个", level: .info)
        } catch {
            showAppError(AppError.from(error))
            appLogger.log(action: "列出 Buckets 失败", detail: error.localizedDescription, level: .error)
        }
    }

    func loadObjects(bucket: String, prefix: String, reset: Bool = true, forceRefresh: Bool = false) async {
        guard let service = s3Service else { return }

        // 首页且未强制刷新时，优先读缓存
        if reset && !forceRefresh {
            let key = cacheKey(bucket: bucket, prefix: prefix)
            if let cached = objectCache[key],
               Date().timeIntervalSince(cached.timestamp) < cacheTTL {
                objects = cached.objects
                continuationToken = cached.nextToken
                hasMorePages = cached.nextToken != nil
                currentPage = 1
                applyFilter(pattern: filterPattern)
                appLogger.log(action: "列出对象(缓存)", detail: "s3://\(bucket)/\(prefix) 共 \(cached.objects.count) 个", level: .info)
                return
            }
        }

        isLoading = true
        defer { isLoading = false }

        if reset {
            objects = []
            allObjects = []  // 进入新目录时清空全量缓存
            continuationToken = nil
            currentPage = 1
        }

        do {
            let result = try await service.listObjects(
                bucket: bucket,
                prefix: prefix,
                continuationToken: reset ? nil : continuationToken,
                pageSize: appSettings.pageSize
            )
            if reset {
                objects = result.objects
                // 写入缓存（仅首页）
                let key = cacheKey(bucket: bucket, prefix: prefix)
                objectCache[key] = CachedPage(objects: result.objects, nextToken: result.nextToken, timestamp: Date())
            } else {
                objects.append(contentsOf: result.objects)
            }
            continuationToken = result.nextToken
            hasMorePages = result.nextToken != nil
            if !reset { currentPage += 1 }

            applyFilter(pattern: filterPattern)
            let label = forceRefresh ? "列出对象(刷新)" : "列出对象"
            appLogger.log(action: label, detail: "s3://\(bucket)/\(prefix) 共 \(result.objects.count) 个", level: .info)
        } catch {
            showAppError(AppError.from(error))
            appLogger.log(action: "列出对象失败", detail: error.localizedDescription, level: .error)
        }
    }

    func loadNextPage() async {
        guard let bucket = selectedBucket, hasMorePages, !isLoading else { return }
        await loadObjects(bucket: bucket, prefix: currentPrefix, reset: false)
    }

    // MARK: - Download

    func downloadSelected() async {
        let toDownload = filteredObjects.filter { selectedObjects.contains($0.key) }
        guard !toDownload.isEmpty else { return }
        await enqueueDownloads(objects: toDownload)
    }

    func downloadWithRegex(pattern: String) async {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            showAppError(.invalidRegex(pattern))
            return
        }
        let matched = objects.filter { obj in
            let name = obj.displayName
            return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        await enqueueDownloads(objects: matched)
        appLogger.log(action: "正则下载", detail: "pattern=\(pattern) 匹配 \(matched.count) 个文件", level: .info)
    }

    func enqueueDownloads(objects: [S3Object]) async {
        guard let service = s3Service, let bucket = selectedBucket else { return }
        for obj in objects where !obj.isDirectory {
            let task = DownloadTask(key: obj.key, bucket: bucket, size: obj.size ?? 0, destinationDir: downloadDirectory)
            downloadTasks.append(task)
        }
        let tasks = downloadTasks.filter { $0.status == .pending }
        appLogger.log(action: "加入下载队列", detail: "\(tasks.count) 个文件", level: .info)
        await downloadManager.startDownloads(
            tasks: downloadTasks.filter { $0.status == .pending },
            service: service
        ) { [weak self] updatedTask in
            await MainActor.run {
                if let idx = self?.downloadTasks.firstIndex(where: { $0.id == updatedTask.id }) {
                    self?.downloadTasks[idx] = updatedTask
                }
                self?.appLogger.log(
                    action: updatedTask.status == .completed ? "下载完成" : "下载失败",
                    detail: updatedTask.key,
                    level: updatedTask.status == .completed ? .info : .error
                )
            }
        }
    }

    // MARK: - Filter

    /// 全量加载当前目录所有分页，然后在全量结果上应用过滤（最多 50 页 × 1000 = 50,000 条）
    func loadAllAndFilter(pattern: String) async {
        guard let service = s3Service, let bucket = selectedBucket, !pattern.isEmpty else { return }
        let prefix = currentPrefix
        let key = allCacheKey(bucket: bucket, prefix: prefix)

        // 命中全量缓存则直接过滤
        if let cached = allObjectsCache[key],
           Date().timeIntervalSince(cached.timestamp) < cacheTTL {
            allObjects = cached.objects
            applyFilterToSource(cached.objects, pattern: pattern)
            appLogger.log(action: "过滤(缓存)", detail: "共 \(cached.objects.count) 条，pattern=\(pattern)", level: .info)
            return
        }

        isLoadingAll = true
        defer { isLoadingAll = false }

        var accumulated: [S3Object] = []
        var token: String? = nil
        var pageCount = 0
        let maxPages = 50

        do {
            repeat {
                let result = try await service.listObjects(
                    bucket: bucket, prefix: prefix,
                    continuationToken: token, pageSize: 1000
                )
                accumulated.append(contentsOf: result.objects)
                token = result.nextToken
                pageCount += 1
            } while token != nil && pageCount < maxPages

            allObjects = accumulated
            allObjectsCache[key] = AllObjectsCache(objects: accumulated, timestamp: Date())
            applyFilterToSource(accumulated, pattern: pattern)
            appLogger.log(action: "全量加载", detail: "s3://\(bucket)/\(prefix) 共 \(accumulated.count) 条", level: .info)
        } catch {
            appLogger.log(action: "全量加载失败", detail: error.localizedDescription, level: .error)
        }
    }

    func applyFilter(pattern: String) {
        if pattern.isEmpty {
            filteredObjects = objects
        } else if !allObjects.isEmpty {
            applyFilterToSource(allObjects, pattern: pattern)
        } else {
            applyFilterToSource(objects, pattern: pattern)
        }
    }

    private func applyFilterToSource(_ source: [S3Object], pattern: String) {
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            filteredObjects = source.filter { obj in
                let name = obj.displayName
                return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
        } else {
            filteredObjects = source.filter { $0.displayName.localizedCaseInsensitiveContains(pattern) }
        }
    }

    // MARK: - Error

    func showAppError(_ error: AppError) {
        currentError = error
        showError = true
    }

    func addLogEntry(_ entry: LogEntry) {
        logEntries.insert(entry, at: 0)
        if logEntries.count > 1000 {
            logEntries = Array(logEntries.prefix(1000))
        }
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    var displayText: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中..."
        case .connected: return "已连接"
        case .failed(let msg): return "连接失败: \(msg)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
