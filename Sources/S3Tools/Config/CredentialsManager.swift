import Foundation

struct AWSCredentials {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
}

final class CredentialsManager {

    enum CredentialError: Error, LocalizedError {
        case notFound(String)
        case invalidFormat(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let msg): return "凭证未找到: \(msg)"
            case .invalidFormat(let msg): return "凭证格式错误: \(msg)"
            }
        }
    }

    /// 按优先级加载凭证：环境变量 > credentials 文件 > config 文件
    func loadCredentials(for environment: S3Environment) throws -> AWSCredentials {
        // 1. 环境变量
        if let creds = loadFromEnvironment() {
            return creds
        }

        // 2. ~/.aws/credentials
        let profile = profileName(for: environment)
        if let creds = try? loadFromCredentialsFile(profile: profile) {
            return creds
        }

        // 3. ~/.aws/config
        if let creds = try? loadFromConfigFile(profile: profile) {
            return creds
        }

        throw CredentialError.notFound(
            "未找到环境 '\(environment.displayName)' 的凭证。\n" +
            "请在 ~/.aws/credentials 中添加 [\(profile)] 配置，或设置环境变量 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
        )
    }

    private func profileName(for env: S3Environment) -> String {
        switch env {
        case .offline: return "offline"
        case .production: return "production"
        }
    }

    // MARK: - 环境变量

    private func loadFromEnvironment() -> AWSCredentials? {
        let env = ProcessInfo.processInfo.environment
        guard
            let ak = env["AWS_ACCESS_KEY_ID"], !ak.isEmpty,
            let sk = env["AWS_SECRET_ACCESS_KEY"], !sk.isEmpty
        else { return nil }
        let token = env["AWS_SESSION_TOKEN"]
        return AWSCredentials(accessKeyId: ak, secretAccessKey: sk, sessionToken: token)
    }

    // MARK: - ~/.aws/credentials

    private func loadFromCredentialsFile(profile: String) throws -> AWSCredentials {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/credentials")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CredentialError.notFound("文件不存在: \(url.path)")
        }
        let sections = try INIParser.parse(url: url)
        let section = sections[profile] ?? sections["default"]

        guard let s = section,
              let ak = s["aws_access_key_id"], !ak.isEmpty,
              let sk = s["aws_secret_access_key"], !sk.isEmpty
        else {
            throw CredentialError.notFound("~/.aws/credentials 中未找到 profile: \(profile)")
        }
        return AWSCredentials(accessKeyId: ak, secretAccessKey: sk, sessionToken: s["aws_session_token"])
    }

    // MARK: - ~/.aws/config

    private func loadFromConfigFile(profile: String) throws -> AWSCredentials {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/config")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CredentialError.notFound("文件不存在: \(url.path)")
        }
        let sections = try INIParser.parse(url: url)
        guard
            let section = sections[profile],
            let ak = section["aws_access_key_id"], !ak.isEmpty,
            let sk = section["aws_secret_access_key"], !sk.isEmpty
        else {
            throw CredentialError.notFound("~/.aws/config 中未找到 profile: \(profile)")
        }
        return AWSCredentials(accessKeyId: ak, secretAccessKey: sk, sessionToken: section["aws_session_token"])
    }

    /// 返回 credentials 文件路径，供用户参考
    var credentialsFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/credentials").path
    }
}
