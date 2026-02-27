import Foundation
import os

/// 应用日志工具，同时写入内存缓冲和文件
final class AppLogger {
    static let shared = AppLogger()

    private let osLogger = Logger(subsystem: "com.s3tools.app", category: "S3Tools")
    private var logFileURL: URL?
    private let queue = DispatchQueue(label: "com.s3tools.logger", qos: .utility)

    private var onEntry: ((LogEntry) -> Void)?
    private var currentEnvironment: String = "unknown"

    private init() {
        setupLogFile()
    }

    func configure(environment: String, onEntry: @escaping (LogEntry) -> Void) {
        self.currentEnvironment = environment
        self.onEntry = onEntry
    }

    func log(action: String, detail: String, level: LogLevel) {
        let entry = LogEntry(level: level, action: action, detail: detail, environment: currentEnvironment)

        // OSLog
        switch level {
        case .info:  osLogger.info("\(entry.logLine)")
        case .warning: osLogger.warning("\(entry.logLine)")
        case .error: osLogger.error("\(entry.logLine)")
        case .debug: osLogger.debug("\(entry.logLine)")
        }

        // 回调通知 UI
        Task { @MainActor in
            self.onEntry?(entry)
        }

        // 写文件
        queue.async {
            self.writeToFile(line: entry.logLine)
        }
    }

    private func setupLogFile() {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/S3Tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        logFileURL = logDir.appendingPathComponent("s3tools-\(dateStr).log")
    }

    private func writeToFile(line: String) {
        guard let url = logFileURL else { return }
        let lineWithNewline = line + "\n"
        if let data = lineWithNewline.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    var logFileLocation: String {
        logFileURL?.path ?? "未知"
    }
}
