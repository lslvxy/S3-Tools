import Foundation

actor DownloadManager {
    private var maxConcurrent: Int = 4
    private var running: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func configure(maxConcurrent: Int) {
        self.maxConcurrent = max(1, min(maxConcurrent, 16))
    }

    /// Acquire a concurrency slot, suspending until one is available.
    private func acquireSlot() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    /// Release a concurrency slot, resuming the next waiter if any.
    private func releaseSlot() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            running = max(0, running - 1)
        }
    }

    /// Execute a single download, honouring structured concurrency cancellation.
    func executeSingle(
        task: DownloadTask,
        service: S3Service,
        onTaskUpdated: @escaping (DownloadTask) async -> Void
    ) async {
        // Wait for a concurrency slot (also cancellable while waiting).
        await acquireSlot()
        defer { releaseSlot() }

        var mutableTask = task

        // Skip if already cancelled before we even start.
        if Task.isCancelled {
            mutableTask.status = .cancelled
            await onTaskUpdated(mutableTask)
            return
        }

        mutableTask.status = .inProgress(0)
        mutableTask.startedAt = Date()
        await onTaskUpdated(mutableTask)

        do {
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

        } catch is CancellationError {
            mutableTask.status = .cancelled
        } catch {
            mutableTask.status = .failed(error.localizedDescription)
        }

        await onTaskUpdated(mutableTask)
    }
}

