import Foundation

final class CredentialsManager {

    // MARK: - 文件路径

    private var homeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/.aws/s3tools 文件路径
    var configFilePath: String {
        homeDir.appendingPathComponent(".aws/s3tools").path
    }

    var configFileExists: Bool {
        FileManager.default.fileExists(atPath: configFilePath)
    }

    // MARK: - 加载 Profiles

    /// 解析 ~/.aws/s3tools，返回所有有效环境配置（按名称排序）
    func loadProfiles() -> [ProfileConfig] {
        let url = homeDir.appendingPathComponent(".aws/s3tools")
        guard let sections = try? INIParser.parse(url: url) else { return [] }

        // [default] 作为全局默认值
        let defaultRegion = sections["default"]?["region"] ?? "ap-southeast-1"

        return sections
            .filter { $0.key != "default" }
            .compactMap { (name, section) -> ProfileConfig? in
                guard
                    let ak = section["aws_access_key_id"], !ak.isEmpty,
                    let sk = section["aws_secret_access_key"], !sk.isEmpty
                else { return nil }

                let region   = section["region"] ?? defaultRegion
                let endpoint = section["endpoint"] ?? ""
                let pathStyle = section["path_style"]?.lowercased() == "true"

                // 生产判断：显式 is_production 优先，否则按名称启发
                let isProduction: Bool
                if let explicit = section["is_production"] {
                    isProduction = explicit.lowercased() == "true"
                } else {
                    isProduction = ProfileConfig.detectsProduction(name: name)
                }

                return ProfileConfig(
                    name: name,
                    accessKeyId: ak,
                    secretAccessKey: sk,
                    sessionToken: section["aws_session_token"],
                    region: region,
                    endpoint: endpoint,
                    usePathStyle: pathStyle,
                    isProduction: isProduction,
                    defaultBucket: section["default_bucket"] ?? ""
                )
            }
            .sorted { $0.name < $1.name }
    }

    // MARK: - 凭证文件路径（保留，用于兼容标准 ~/.aws/credentials 说明）

    var credentialsFilePath: String {
        homeDir.appendingPathComponent(".aws/credentials").path
    }

    var credentialsFileExists: Bool {
        FileManager.default.fileExists(atPath: credentialsFilePath)
    }

    /// 读取 ~/.aws/credentials 所有 profile 名（排除 default），供参考
    func availableProfiles() -> [String] {
        let url = homeDir.appendingPathComponent(".aws/credentials")
        guard let sections = try? INIParser.parse(url: url) else { return [] }
        return sections.keys.filter { $0 != "default" }.sorted()
    }
}
