import Foundation

enum LogLevel: String, CaseIterable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case debug = "DEBUG"

    var emoji: String {
        switch self {
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .debug: return "🔍"
        }
    }
}

struct LogEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let action: String
    let detail: String
    let environment: String

    init(level: LogLevel, action: String, detail: String, environment: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.action = action
        self.detail = detail
        self.environment = environment
    }

    var formattedTimestamp: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: timestamp)
    }

    var logLine: String {
        "[\(formattedTimestamp)] [\(level.rawValue)] [\(environment)] \(action): \(detail)"
    }
}

enum AppError: Error, Identifiable {
    case credentialsNotFound(String)
    case connectionFailed(String)
    case accessDenied(String)
    case objectNotFound(String)
    case uploadDisabled(String)
    case invalidRegex(String)
    case downloadFailed(String)
    case unknown(String)

    var id: String { title + message }

    var title: String {
        switch self {
        case .credentialsNotFound: return "认证失败"
        case .connectionFailed: return "连接失败"
        case .accessDenied: return "权限不足"
        case .objectNotFound: return "对象不存在"
        case .uploadDisabled: return "上传被禁用"
        case .invalidRegex: return "正则表达式无效"
        case .downloadFailed: return "下载失败"
        case .unknown: return "未知错误"
        }
    }

    var message: String {
        switch self {
        case .credentialsNotFound(let msg): return msg
        case .connectionFailed(let msg): return msg
        case .accessDenied(let msg): return msg
        case .objectNotFound(let msg): return msg
        case .uploadDisabled(let msg): return msg
        case .invalidRegex(let pattern): return "正则表达式不合法: \(pattern)"
        case .downloadFailed(let msg): return msg
        case .unknown(let msg): return msg
        }
    }

    var suggestion: String {
        switch self {
        case .credentialsNotFound:
            return "请检查 ~/.aws/credentials 文件，或设置 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY 环境变量"
        case .connectionFailed:
            return "请检查网络连接和 Endpoint 配置，offline 环境请确认 VPN 或本地服务已启动"
        case .accessDenied:
            return "请确认当前 AK/SK 有访问该资源的权限（检查 IAM 策略）"
        case .objectNotFound:
            return "对象可能已被删除，请刷新目录"
        case .uploadDisabled:
            return "Production 环境禁止上传；Offline 环境请在设置中开启上传开关"
        case .invalidRegex:
            return "请检查正则语法，例如: .*\\.log$"
        case .downloadFailed:
            return "请检查磁盘空间和下载目录权限"
        case .unknown:
            return "请查看日志面板获取详细信息"
        }
    }

    static func from(_ error: Error) -> AppError {
        let msg = error.localizedDescription
        let desc = String(describing: error)
        let combined = msg + desc
        if combined.contains("credential") || combined.contains("InvalidSignature") || combined.contains("AuthFailure") || combined.contains("InvalidAccessKeyId") {
            return .credentialsNotFound(msg)
        } else if combined.contains("AccessDenied") || combined.contains("403") {
            return .accessDenied(msg)
        } else if combined.contains("NoSuchKey") || combined.contains("404") || combined.contains("NoSuchBucket") {
            return .objectNotFound(msg)
        } else if combined.contains("PermanentRedirect") || combined.contains("AuthorizationHeaderMalformed") || combined.contains("RegionMismatch") {
            return .connectionFailed("Bucket 所在 Region 与当前配置不符，正在尝试自动重定向。如持续失败，请在设置中修改 Region。\n原始错误: \(msg)")
        } else if combined.contains("connect") || combined.contains("timeout") || combined.contains("unreachable") || combined.contains("UnknownAWSHTTP") {
            return .connectionFailed("连接失败，请检查网络或 Region 配置。\n原始错误: \(msg)")
        } else {
            return .unknown(msg)
        }
    }
}
