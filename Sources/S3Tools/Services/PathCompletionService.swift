import Foundation
import Combine

@MainActor
final class PathCompletionService: ObservableObject {
    @Published var suggestions: [String] = []
    @Published var isLoading: Bool = false

    private var cache: [String: (results: [String], expiry: Date)] = [:]
    private var debounceTask: Task<Void, Never>? = nil
    private let cacheTTL: TimeInterval

    init(cacheTTL: TimeInterval = 60) {
        self.cacheTTL = cacheTTL
    }

    func requestCompletions(
        input: String,
        bucket: String,
        service: S3Service?
    ) {
        debounceTask?.cancel()
        guard let service = service, !bucket.isEmpty else {
            suggestions = []
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms 防抖
            guard !Task.isCancelled else { return }
            await self?.fetchCompletions(input: input, bucket: bucket, service: service)
        }
    }

    private func fetchCompletions(input: String, bucket: String, service: S3Service) async {
        let cacheKey = "\(bucket)/\(input)"

        // 检查缓存
        if let cached = cache[cacheKey], cached.expiry > Date() {
            suggestions = cached.results
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let results = try await service.listForCompletion(bucket: bucket, prefix: input)
            // 只保留目录（以 / 结尾），地址框跳转目标几乎都是目录
            let dirs = results.filter { $0.hasSuffix("/") }
            cache[cacheKey] = (dirs, Date().addingTimeInterval(cacheTTL))
            suggestions = dirs
        } catch {
            suggestions = []
        }
    }

    func clearCache() {
        cache.removeAll()
    }
}
