import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    // MARK: - Profile
    @Published var availableProfiles: [ProfileConfig] = []
    @Published var selectedProfile: ProfileConfig? = nil
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var isUploadEnabled: Bool = false  // 非生产环境上传开关

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
    @Published var filterPattern: String = "" {
        didSet {
            scheduleFilterLoad()
        }
    }

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

    private func cacheKey(bucket: String, prefix: String) -> String { "\(bucket)\0\(prefix)" }

    private var filterCancellable: AnyCancellable?
    private var filterLoadTask: Task<Void, Never>?
    private var suppressNextFilterLoad = false
    private var settingsCancellable: AnyCancellable?

    init() {
        self.downloadManager = DownloadManager()
        self.isUploadEnabled = false
        // 将 AppSettings 内部变化（如 bookmarks）转发到 AppState.objectWillChange，让视图实时更新
        settingsCancellable = appSettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: - Environment Switching

    /// 重新读取 ~/.aws/s3tools 并更新可用 profile 列表
    func reloadProfiles() {
        availableProfiles = credentialsManager.loadProfiles()
    }

    func switchProfile(to profile: ProfileConfig) async {
        connectionStatus = .connecting
        selectedBucket = nil
        currentPrefix = ""
        objects = []
        buckets = []
        currentPage = 1
        continuationToken = nil
        filterPattern = ""
        objectCache.removeAll()
        filterPattern = "" // 切换环境时重置过滤

        do {
            let service = try await S3Service(profile: profile)
            self.s3Service = service
            self.selectedProfile = profile
            self.connectionStatus = .connected
            self.isUploadEnabled = false
            self.appSettings.lastProfileName = profile.name

            appLogger.log(action: "切换环境", detail: "切换到 [\(profile.name)]", level: .info)
            await loadBuckets()

            // 如果配置了默认 Bucket 则自动选中并加载
            if !profile.defaultBucket.isEmpty, buckets.contains(profile.defaultBucket) {
                selectedBucket = profile.defaultBucket
                await loadObjects(bucket: profile.defaultBucket, prefix: "")
            }
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
                appLogger.log(action: "列出对象(缓存)", detail: "s3://\(bucket)/\(prefix) 共 \(cached.objects.count) 个", level: .info)
                return
            }
        }

        isLoading = true
        defer { isLoading = false }

        if reset {
            objects = []
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
        let toDownload = objects.filter { selectedObjects.contains($0.key) }
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
                switch updatedTask.status {
                case .completed:
                    self?.appLogger.log(action: "下载完成", detail: updatedTask.key, level: .info)
                case .failed(let reason):
                    self?.appLogger.log(action: "下载失败", detail: "\(updatedTask.key): \(reason)", level: .error)
                default:
                    break
                }
            }
        }
    }

    // MARK: - Filter

    /// 导航时调用：静默重置过滤词，不触发网络请求
    func clearFilterSilently() {
        filterLoadTask?.cancel()
        filterLoadTask = nil
        suppressNextFilterLoad = true
        filterPattern = ""
    }

    private func scheduleFilterLoad() {
        guard !suppressNextFilterLoad else {
            suppressNextFilterLoad = false
            return
        }
        filterLoadTask?.cancel()
        filterLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            guard let bucket = selectedBucket else { return }
            let prefix = currentPrefix + filterPattern
            await loadObjects(bucket: bucket, prefix: prefix)
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
        case .disconnected: return "未连接   "
        case .connecting: return "连接中...   "
        case .connected: return "已连接   "
        case .failed(let msg): return "连接失败: \(msg)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
