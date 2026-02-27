import Foundation

enum S3Environment: String, CaseIterable, Identifiable, Codable {
    case offline
    case production

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .offline: return "Offline"
        case .production: return "Production"
        }
    }

    var allowsUpload: Bool {
        switch self {
        case .offline: return true   // 由 AppState.isUploadEnabled 控制开关
        case .production: return false
        }
    }

    var statusColor: String {
        switch self {
        case .offline: return "green"
        case .production: return "orange"
        }
    }
}

struct EnvironmentConfig: Codable, Equatable {
    var endpoint: String
    var region: String
    var profile: String
    var usePathStyle: Bool

    static func `default`(for env: S3Environment) -> EnvironmentConfig {
        switch env {
        case .offline:
            return EnvironmentConfig(
                endpoint: "",  // 空表示使用 AWS 标准 endpoint，填写则覆盖（如 MinIO）
                region: "us-east-1",
                profile: "offline",
                usePathStyle: false
            )
        case .production:
            return EnvironmentConfig(
                endpoint: "",  // 使用 AWS 标准 endpoint
                region: "ap-southeast-1",
                profile: "production",
                usePathStyle: false
            )
        }
    }
}
