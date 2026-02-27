import Foundation

actor DownloadManager {
    private var maxConcurrent: Int = 4
    private var activeTasks: Int = 0

    func configure(maxConcurrent: Int) {
        self.maxConcurrent = max(1, min(maxConcurrent, 16))
    }

    func startDownloads(
        tasks: [DownloadTask],
        service: S3Service,
        onTaskUpdated: @escaping (DownloadTask) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = tasks
            var running = 0

            while !pending.isEmpty || running > 0 {
                while running < maxConcurrent && !pending.isEmpty {
                    var task = pending.removeFirst()
                    running += 1
                    group.addTask {
                        await self.executeDownload(task: &task, service: service, onTaskUpdated: onTaskUpdated)
                    }
                }
                await group.next()
                running = max(0, running - 1)
            }
        }
    }

    private func executeDownload(
        task: inout DownloadTask,
        service: S3Service,
        onTaskUpdated: @escaping (DownloadTask) async -> Void
    ) async {
        var mutableTask = task
        mutableTask.status = .inProgress(0)
        mutableTask.startedAt = Date()
        await onTaskUpdated(mutableTask)

        do {
            // 确保下载目录存在
            try FileManager.default.createDirectory(
                at: mutableTask.destinationDir,
                withIntermediateDirectories: true
            )

            try await service.downloadObject(
                bucket: mutableTask.bucket,
                key: mutableTask.key,
                destinationURL: mutableTask.destinationURL
            ) { progress in
                Task {
                    var updated = mutableTask
                    updated.status = .inProgress(progress)
                    updated.bytesDownloaded = Int64(Double(mutableTask.size) * progress)
                    await onTaskUpdated(updated)
                }
            }

            mutableTask.status = .completed
            mutableTask.completedAt = Date()
            mutableTask.bytesDownloaded = mutableTask.size
            mutableTask.localURL = mutableTask.destinationURL

        } catch {
            mutableTask.status = .failed(error.localizedDescription)
        }

        await onTaskUpdated(mutableTask)
    }
}
