import Foundation
import AWSS3
import AWSClientRuntime
import SmithyIdentity

final class S3Service {
    private let client: S3Client
    private let environment: S3Environment
    private let config: EnvironmentConfig
    private let credResolver: StaticAWSCredentialIdentityResolver
    // 缓存各 region 的 S3Client，避免跨区域请求重复初始化
    private var regionalClients: [String: S3Client] = [:]
    // 缓存已检测到的 bucket 所属 region，listObjects/download 共享
    private var bucketRegionCache: [String: String] = [:]

    init(credentials: AWSCredentials, config: EnvironmentConfig, environment: S3Environment) async throws {
        self.environment = environment
        self.config = config

        // 构建静态凭证 resolver
        let identity = AWSCredentialIdentity(
            accessKey: credentials.accessKeyId,
            secret: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken
        )
        let credResolver = StaticAWSCredentialIdentityResolver(identity)
        self.credResolver = credResolver

        // 构建 S3 客户端配置（使用新版 S3ClientConfig API）
        var clientConfig = try await S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: credResolver,
            region: config.region.isEmpty ? "us-east-1" : config.region
        )

        // offline 环境使用自定义 endpoint
        if !config.endpoint.isEmpty {
            clientConfig.endpoint = config.endpoint
        }

        // MinIO / LocalStack 等需要 path-style
        if config.usePathStyle {
            clientConfig.forcePathStyle = true
        }

        self.client = S3Client(config: clientConfig)
    }

    /// 为指定 region 返回（或创建）S3Client，用于跨区域桶自动重定向
    private func regionalClient(for region: String) async throws -> S3Client {
        if let cached = regionalClients[region] { return cached }
        var cfg = try await S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: credResolver,
            region: region
        )
        if !config.endpoint.isEmpty { cfg.endpoint = config.endpoint }
        if config.usePathStyle { cfg.forcePathStyle = true }
        let newClient = S3Client(config: cfg)
        regionalClients[region] = newClient
        return newClient
    }

    /// 获取桶所在的真实 region（us-east-1 的 locationConstraint 为 nil）
    private func getBucketRegion(bucket: String) async throws -> String {
        let output = try await client.getBucketLocation(input: GetBucketLocationInput(bucket: bucket))
        if let constraint = output.locationConstraint, !constraint.rawValue.isEmpty {
            return constraint.rawValue
        }
        return "us-east-1"
    }

    /// 返回 bucket 对应的正确 S3Client（优先读缓存，否则使用默认 client）
    private func clientForBucket(_ bucket: String) async -> S3Client {
        guard let cachedRegion = bucketRegionCache[bucket] else { return client }
        let configuredRegion = config.region.isEmpty ? "us-east-1" : config.region
        guard cachedRegion != configuredRegion else { return client }
        return (try? await regionalClient(for: cachedRegion)) ?? client
    }

    // MARK: - List Buckets

    func listBuckets() async throws -> [String] {
        let output = try await client.listBuckets(input: ListBucketsInput())
        return (output.buckets ?? []).compactMap { $0.name }
    }

    // MARK: - List Objects (分页)

    func listObjects(
        bucket: String,
        prefix: String,
        continuationToken: String? = nil,
        pageSize: Int = 200
    ) async throws -> ListObjectsResult {
        do {
            return try await performListObjects(
                using: client, bucket: bucket,
                prefix: prefix, continuationToken: continuationToken, pageSize: pageSize
            )
        } catch {
            // 尝试 region 重定向：获取桶真实所在 region 并重试
            guard config.endpoint.isEmpty,  // 自定义 endpoint 时不做重定向
                  let bucketRegion = try? await getBucketRegion(bucket: bucket)
            else { throw error }

            let configuredRegion = config.region.isEmpty ? "us-east-1" : config.region
            guard bucketRegion != configuredRegion else { throw error }

            // 缓存检测到的 region，供后续 download 等操作复用
            bucketRegionCache[bucket] = bucketRegion
            let regional = try await regionalClient(for: bucketRegion)
            return try await performListObjects(
                using: regional, bucket: bucket,
                prefix: prefix, continuationToken: continuationToken, pageSize: pageSize
            )
        }
    }

    private func performListObjects(
        using s3: S3Client,
        bucket: String,
        prefix: String,
        continuationToken: String?,
        pageSize: Int
    ) async throws -> ListObjectsResult {
        let input = ListObjectsV2Input(
            bucket: bucket,
            continuationToken: continuationToken,
            delimiter: "/",
            maxKeys: pageSize,
            prefix: prefix.isEmpty ? nil : prefix
        )
        let output = try await s3.listObjectsV2(input: input)

        var objects: [S3Object] = []

        // 子目录 (CommonPrefixes)
        for cp in output.commonPrefixes ?? [] {
            if let p = cp.prefix {
                objects.append(S3Object(key: p, isDirectory: true))
            }
        }

        // 文件
        for obj in output.contents ?? [] {
            if let key = obj.key, !key.hasSuffix("/") {
                objects.append(S3Object(
                    key: key,
                    size: obj.size.map { Int64($0) },
                    lastModified: obj.lastModified,
                    eTag: obj.eTag,
                    isDirectory: false,
                    storageClass: obj.storageClass?.rawValue
                ))
            }
        }

        return ListObjectsResult(
            objects: objects,
            nextToken: output.nextContinuationToken,
            prefix: prefix,
            bucket: bucket
        )
    }

    // MARK: - List for Completion (前缀查询，不分页)

    func listForCompletion(bucket: String, prefix: String) async throws -> [String] {
        let input = ListObjectsV2Input(
            bucket: bucket,
            delimiter: "/",
            maxKeys: 50,
            prefix: prefix.isEmpty ? nil : prefix
        )
        let output = try await client.listObjectsV2(input: input)
        var results: [String] = []
        for cp in output.commonPrefixes ?? [] {
            if let p = cp.prefix { results.append(p) }
        }
        for obj in output.contents ?? [] {
            if let key = obj.key { results.append(key) }
        }
        return results
    }

    // MARK: - Download Object

    func downloadObject(
        bucket: String,
        key: String,
        destinationURL: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        // 使用缓存的 regional client，避免 region 不符导致 UnknownAWSHTTPServiceError
        let s3 = await clientForBucket(bucket)
        let input = GetObjectInput(bucket: bucket, key: key)
        let output: GetObjectOutput
        do {
            output = try await s3.getObject(input: input)
        } catch {
            // 若缓存 region 未命中，尝试检测真实 region 并重试
            guard config.endpoint.isEmpty,
                  let bucketRegion = try? await getBucketRegion(bucket: bucket)
            else { throw error }
            let configuredRegion = config.region.isEmpty ? "us-east-1" : config.region
            guard bucketRegion != configuredRegion else { throw error }
            bucketRegionCache[bucket] = bucketRegion
            let regional = try await regionalClient(for: bucketRegion)
            output = try await regional.getObject(input: input)
        }

        guard let body = output.body else {
            throw AppError.objectNotFound("对象 key=\(key) 无内容")
        }

        progressHandler(0.1)

        // 读取完整响应体
        let data = try await body.readData() ?? Data()
        let totalSize = output.contentLength ?? 0
        if totalSize > 0 {
            progressHandler(0.1 + Double(data.count) / Double(totalSize) * 0.85)
        } else {
            progressHandler(0.9)
        }

        try data.write(to: destinationURL)
        progressHandler(1.0)
    }

    // MARK: - Upload Object (仅 offline 环境)

    func uploadObject(
        bucket: String,
        key: String,
        fileURL: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        guard environment.allowsUpload else {
            throw AppError.uploadDisabled("当前环境 \(environment.displayName) 不允许上传")
        }

        let data = try Data(contentsOf: fileURL)
        let input = PutObjectInput(
            body: .data(data),
            bucket: bucket,
            contentLength: Int(data.count),
            key: key
        )
        _ = try await client.putObject(input: input)
        progressHandler(1.0)
    }

    // MARK: - Head Object (获取元信息)

    func headObject(bucket: String, key: String) async throws -> S3Object {
        let input = HeadObjectInput(bucket: bucket, key: key)
        let output = try await client.headObject(input: input)
        return S3Object(
            key: key,
            size: output.contentLength.map { Int64($0) },
            lastModified: output.lastModified,
            eTag: output.eTag
        )
    }
}
