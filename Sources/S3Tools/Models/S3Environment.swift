import Foundation

/// 一个可用环境的完整配置，从 ~/.aws/s3tools 解析而来
struct ProfileConfig: Identifiable, Hashable, Codable {
    /// section 名，既是唯一标识符，也是显示名称
    var name: String
    var accessKeyId: String
    var secretAccessKey: String
    var sessionToken: String?
    /// 默认 ap-southeast-1
    var region: String
    /// 留空表示 AWS 标准 Endpoint；填写则用于 MinIO / LocalStack 等
    var endpoint: String
    /// MinIO / LocalStack 需要 path-style；AWS S3 不需要
    var usePathStyle: Bool
    /// 生产环境：禁止上传，连接时橙色标识
    var isProduction: Bool

    var id: String { name }

    // MARK: - 生产环境自动检测

    /// 名称中包含这些词（不区分大小写）时，自动视为生产环境
    static let productionKeywords = ["prod", "production", "live", "online", "prd"]

    static func detectsProduction(name: String) -> Bool {
        let lower = name.lowercased()
        return productionKeywords.contains { lower.contains($0) }
    }
}
