use crate::config::ProfileConfig;
use aws_sdk_s3::config::{BehaviorVersion, Credentials, Region};
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::Client;
use aws_sdk_s3::error::ProvideErrorMetadata;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::io::AsyncReadExt;
use tokio::io::AsyncWriteExt;

// ─────────────────────────────────────────────────────────────
// Error model
// ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct AppError {
    pub title: String,
    pub message: String,
    pub suggestion: String,
    #[serde(skip)]
    region_redirect: bool,
}

impl AppError {
    pub fn new(title: &str, message: String, suggestion: &str) -> Self {
        Self {
            title: title.to_string(),
            message,
            suggestion: suggestion.to_string(),
            region_redirect: false,
        }
    }

    pub fn unknown(msg: String) -> Self {
        Self::new("未知错误", msg, "请查看日志面板获取详细信息")
    }
}

impl std::fmt::Display for AppError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.title, self.message)
    }
}

impl std::error::Error for AppError {}

/// Classify an AWS SDK error the same way the Swift version does.
pub fn classify_error<E: std::fmt::Display + ProvideErrorMetadata>(err: &aws_sdk_s3::error::SdkError<E>) -> AppError {
    let msg = match err.message() {
        Some(message) => format!("{}: {}", err.code().unwrap_or("S3Error"), message),
        None => err.to_string(),
    };
    let combined = msg.to_lowercase();
    let status = err.raw_response().map(|r| r.status().as_u16());

    if status == Some(301)
        || matches!(err.code(), Some("PermanentRedirect" | "AuthorizationHeaderMalformed" | "RegionMismatch"))
    {
        let mut error = AppError::new("区域不匹配", msg, "请检查 Bucket 的 Region 配置");
        error.region_redirect = true;
        error
    } else if combined.contains("credential")
        || combined.contains("invalidsignature")
        || combined.contains("authfailure")
        || combined.contains("invalidaccesskeyid")
        || combined.contains("expiredtoken")
    {
        AppError::new(
            "认证失败",
            msg,
            "请检查 ~/.aws/s3tools 中的 AK/SK，或确认 Token 是否过期",
        )
    } else if combined.contains("accessdenied") || status == Some(403) {
        AppError::new(
            "权限不足",
            msg,
            "请确认当前 AK/SK 有访问该资源的权限（检查 IAM 策略）",
        )
    } else if combined.contains("nosuchkey")
        || combined.contains("nosuchbucket")
        || status == Some(404)
    {
        AppError::new("对象不存在", msg, "对象可能已被删除，请刷新目录")
    } else if combined.contains("connect")
        || combined.contains("timeout")
        || combined.contains("unreachable")
        || combined.contains("unknownawshttp")
    {
        AppError::new(
            "连接失败",
            format!("连接失败，请检查网络或 Region 配置。\n原始错误: {}", msg),
            "请检查网络连接和 Endpoint 配置，offline 环境请确认 VPN 或本地服务已启动",
        )
    } else {
        AppError::unknown(msg)
    }
}

// ─────────────────────────────────────────────────────────────
// S3 object model
// ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct S3Object {
    pub key: String,
    pub size: Option<i64>,
    pub last_modified: Option<String>,
    pub e_tag: Option<String>,
    pub is_directory: bool,
    pub storage_class: Option<String>,
    pub display_name: String,
    pub sortable_name: String,
    pub sortable_size: i64,
    pub sortable_date: i64,
}

impl S3Object {
    fn from_key(key: String, is_directory: bool) -> Self {
        let display_name = if is_directory {
            let name = key
                .trim_end_matches('/')
                .rsplit('/')
                .next()
                .unwrap_or(&key)
                .to_string();
            format!("{}/", name)
        } else {
            key.rsplit('/').next().unwrap_or(&key).to_string()
        };
        let sortable_name = format!(
            "{}{}",
            if is_directory { "0_" } else { "1_" },
            display_name.to_lowercase()
        );
        Self {
            key: key.clone(),
            size: None,
            last_modified: None,
            e_tag: None,
            is_directory,
            storage_class: None,
            display_name,
            sortable_name,
            sortable_size: -1,
            sortable_date: 0,
        }
    }

    fn from_object(obj: &aws_sdk_s3::types::Object) -> Self {
        let key = obj.key.clone().unwrap_or_default();
        let display_name = key.rsplit('/').next().unwrap_or(&key).to_string();
        let sortable_name = format!("1_{}", display_name.to_lowercase());
        Self {
            key: key.clone(),
            size: obj.size,
            last_modified: obj
                .last_modified
                .map(|d| d.to_string().trim_end_matches('Z').to_string()),
            e_tag: obj.e_tag.clone(),
            is_directory: false,
            storage_class: obj
                .storage_class
                .as_ref()
                .map(|s| s.as_str().to_string()),
            display_name,
            sortable_name,
            sortable_size: obj.size.unwrap_or(0),
            sortable_date: obj
                .last_modified
                .map(|d| d.secs())
                .unwrap_or(0),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ListObjectsResult {
    pub objects: Vec<S3Object>,
    pub next_token: Option<String>,
    pub prefix: String,
    pub bucket: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ObjectDetail {
    pub key: String,
    pub size: Option<i64>,
    pub last_modified: Option<String>,
    pub e_tag: Option<String>,
    pub storage_class: Option<String>,
    pub content_type: Option<String>,
}

// ─────────────────────────────────────────────────────────────
// S3 Service
// ─────────────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub objects: Vec<S3Object>,
    pub next_token: Option<String>,
    pub truncated: bool,
}

pub struct S3Service {
    client: Client,
    profile: ProfileConfig,
    creds: Credentials,
    regional_clients: Mutex<HashMap<String, Client>>,
    bucket_region_cache: Mutex<HashMap<String, String>>,
}

fn build_config(
    profile: &ProfileConfig,
    region: &str,
    creds: Credentials,
) -> aws_sdk_s3::config::Config {
    let mut builder = aws_sdk_s3::config::Builder::new()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new(region.to_string()))
        .credentials_provider(creds);

    if profile.use_path_style {
        builder = builder.force_path_style(true);
    }
    if !profile.endpoint.is_empty() {
        builder = builder.endpoint_url(profile.endpoint.clone());
    }
    builder.build()
}

impl S3Service {
    pub fn new(profile: ProfileConfig) -> Self {
        let creds = Credentials::new(
            profile.access_key_id.clone(),
            profile.secret_access_key.clone(),
            profile.session_token.clone(),
            None,
            "s3rust-static",
        );
        let region = profile.effective_region();
        let config = build_config(&profile, &region, creds.clone());
        Self {
            client: Client::from_conf(config),
            profile,
            creds,
            regional_clients: Mutex::new(HashMap::new()),
            bucket_region_cache: Mutex::new(HashMap::new()),
        }
    }

    fn client_for_bucket(&self, bucket: &str) -> Client {
        let cached_region = self.bucket_region_cache.lock().unwrap().get(bucket).cloned();
        let configured = self.profile.effective_region();
        match cached_region {
            Some(region) if region != configured => {
                self.regional_client(&region).unwrap_or_else(|_| self.client.clone())
            }
            _ => self.client.clone(),
        }
    }

    fn regional_client(&self, region: &str) -> Result<Client, String> {
        if let Some(c) = self.regional_clients.lock().unwrap().get(region) {
            return Ok(c.clone());
        }
        let config = build_config(&self.profile, region, self.creds.clone());
        let client = Client::from_conf(config);
        self.regional_clients
            .lock()
            .unwrap()
            .insert(region.to_string(), client.clone());
        Ok(client)
    }

    /// Get the bucket's real region. us-east-1 returns None constraint → "us-east-1".
    async fn get_bucket_region(&self, bucket: &str) -> Result<String, AppError> {
        let output = self
            .client
            .get_bucket_location()
            .bucket(bucket)
            .send()
            .await
            .map_err(|e| classify_error(&e))?;
        Ok(output
            .location_constraint
            .map(|c| c.as_str().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "us-east-1".to_string()))
    }

    fn bucket_region_mismatch(&self, bucket_region: &str) -> bool {
        bucket_region != self.profile.effective_region()
    }

    // MARK: - List buckets

    pub async fn list_buckets(&self) -> Result<Vec<String>, AppError> {
        let output = self
            .client
            .list_buckets()
            .send()
            .await
            .map_err(|e| classify_error(&e))?;
        Ok(output
            .buckets
            .unwrap_or_default()
            .iter()
            .filter_map(|b| b.name.clone())
            .collect())
    }

    // MARK: - List objects (paginated, with region redirect)

    pub async fn list_objects(
        &self,
        bucket: &str,
        prefix: &str,
        continuation_token: Option<String>,
        page_size: i64,
    ) -> Result<ListObjectsResult, AppError> {
        match self
            .perform_list_objects(
                self.client_for_bucket(bucket),
                bucket,
                prefix,
                continuation_token.clone(),
                page_size,
            )
            .await
        {
            Ok(result) => Ok(result),
            Err(e) => {
                // region redirect retry (only for AWS standard endpoints)
                if !self.profile.endpoint.is_empty() || !e.region_redirect {
                    return Err(e);
                }
                let bucket_region = match self.get_bucket_region(bucket).await {
                    Ok(region) => region,
                    Err(_) => return Err(e),
                };
                if !self.bucket_region_mismatch(&bucket_region) {
                    return Err(e);
                }
                self.bucket_region_cache
                    .lock()
                    .unwrap()
                    .insert(bucket.to_string(), bucket_region.clone());
                let regional = self.regional_client(&bucket_region).map_err(AppError::unknown)?;
                self.perform_list_objects(regional, bucket, prefix, continuation_token, page_size)
                    .await
            }
        }
    }

    async fn perform_list_objects(
        &self,
        client: Client,
        bucket: &str,
        prefix: &str,
        continuation_token: Option<String>,
        page_size: i64,
    ) -> Result<ListObjectsResult, AppError> {
        let mut req = client
            .list_objects_v2()
            .bucket(bucket)
            .delimiter("/")
            .max_keys(page_size as i32);
        if !prefix.is_empty() {
            req = req.prefix(prefix);
        }
        if let Some(token) = continuation_token {
            req = req.continuation_token(token);
        }
        let output = req.send().await.map_err(|e| classify_error(&e))?;

        let mut objects: Vec<S3Object> = Vec::new();
        if let Some(prefixes) = output.common_prefixes {
            for cp in prefixes {
                if let Some(p) = cp.prefix {
                    objects.push(S3Object::from_key(p, true));
                }
            }
        }
        if let Some(contents) = output.contents {
            for obj in contents {
                if let Some(key) = obj.key.as_ref() {
                    if !key.ends_with('/') {
                        objects.push(S3Object::from_object(&obj));
                    }
                }
            }
        }

        Ok(ListObjectsResult {
            objects,
            next_token: output.next_continuation_token,
            prefix: prefix.to_string(),
            bucket: bucket.to_string(),
        })
    }

    // MARK: - List for completion (directories only, cached by frontend)

    pub async fn list_for_completion(&self, bucket: &str, prefix: &str) -> Result<Vec<String>, AppError> {
        let mut req = self
            .client_for_bucket(bucket)
            .list_objects_v2()
            .bucket(bucket)
            .delimiter("/")
            .max_keys(50);
        if !prefix.is_empty() {
            req = req.prefix(prefix);
        }
        let output = req.send().await.map_err(|e| classify_error(&e))?;

        let mut results: Vec<String> = Vec::new();
        if let Some(prefixes) = output.common_prefixes {
            for cp in prefixes {
                if let Some(p) = cp.prefix {
                    results.push(p);
                }
            }
        }
        if let Some(contents) = output.contents {
            for obj in contents {
                if let Some(key) = obj.key {
                    results.push(key);
                }
            }
        }
        Ok(results)
    }

    // MARK: - Search (recursive, name substring, capped)

    pub async fn search(
        &self,
        bucket: &str,
        prefix: &str,
        query: &str,
        continuation_token: Option<String>,
    ) -> Result<SearchResult, AppError> {
        let q = query.to_lowercase();
        let client = self.client_for_bucket(bucket);
        let max_results = 500usize;
        let max_pages = 20;
        let mut results: Vec<S3Object> = Vec::new();
        let mut token = continuation_token;

        for _ in 0..max_pages {
            let mut req = client.list_objects_v2().bucket(bucket).max_keys((max_results - results.len()) as i32);
            if !prefix.is_empty() {
                req = req.prefix(prefix);
            }
            if let Some(t) = token {
                req = req.continuation_token(t);
            }
            let output = req.send().await.map_err(|e| classify_error(&e))?;

            if let Some(contents) = output.contents {
                for obj in contents {
                    if let Some(key) = obj.key.as_ref() {
                        if key.ends_with('/') {
                            continue;
                        }
                        let base = key.rsplit('/').next().unwrap_or(key);
                        if q.is_empty() || base.to_lowercase().contains(&q) {
                            results.push(S3Object::from_object(&obj));
                        }
                    }
                }
            }

            token = output.next_continuation_token;
            if token.is_none() || results.len() >= max_results {
                break;
            }
        }
        Ok(SearchResult {
            objects: results,
            truncated: token.is_some(),
            next_token: token,
        })
    }

    // MARK: - Download (streams to file with progress + cancellation)

    pub async fn download_object(
        &self,
        bucket: &str,
        key: &str,
        dest_path: &Path,
        cancel: Arc<AtomicBool>,
        on_progress: impl Fn(f64),
        checksum_enabled: bool,
    ) -> Result<PathBuf, AppError> {
        match self
            .perform_download(
                self.client_for_bucket(bucket),
                bucket,
                key,
                dest_path,
                &cancel,
                &on_progress,
                checksum_enabled,
            )
            .await
        {
            Ok(p) => Ok(p),
            Err(e) => {
                if !self.profile.endpoint.is_empty() || !e.region_redirect
                    || cancel.load(std::sync::atomic::Ordering::Relaxed) {
                    return Err(e);
                }
                let bucket_region = match self.get_bucket_region(bucket).await {
                    Ok(region) => region,
                    Err(_) => return Err(e),
                };
                if !self.bucket_region_mismatch(&bucket_region) {
                    return Err(e);
                }
                self.bucket_region_cache
                    .lock()
                    .unwrap()
                    .insert(bucket.to_string(), bucket_region.clone());
                let regional = self.regional_client(&bucket_region).map_err(AppError::unknown)?;
                self.perform_download(regional, bucket, key, dest_path, &cancel, &on_progress, checksum_enabled)
                    .await
            }
        }
    }

    async fn perform_download(
        &self,
        client: Client,
        bucket: &str,
        key: &str,
        dest_path: &Path,
        cancel: &AtomicBool,
        on_progress: &impl Fn(f64),
        checksum_enabled: bool,
    ) -> Result<PathBuf, AppError> {
        let output = client
            .get_object()
            .bucket(bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| classify_error(&e))?;

        let expected_length = output.content_length;
        let content_length = expected_length.unwrap_or(0).max(1) as f64;
        on_progress(0.1);

        if let Some(parent) = dest_path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| AppError::unknown(e.to_string()))?;
        }

        // Verify MD5 against ETag only when it is a plain 32-hex MD5 (single-part upload).
        let etag_md5 = output
            .e_tag
            .as_deref()
            .map(|e| e.trim_matches('"'))
            .filter(|t| t.len() == 32 && t.chars().all(|c| c.is_ascii_hexdigit()))
            .map(|t| t.to_ascii_lowercase());
        let mut hasher = if checksum_enabled && etag_md5.is_some() {
            Some(md5::Context::new())
        } else {
            None
        };

        let mut reader = output.body.into_async_read();
        let temp_path = dest_path.with_file_name(format!(".s3rust-{}.part", uuid::Uuid::new_v4()));
        let mut file = tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp_path)
            .await
            .map_err(|e| AppError::unknown(e.to_string()))?;
        let result: Result<(), AppError> = async {

            // Allocate only once the transfer starts; queued futures stay small.
            let mut buffer = vec![0u8; 64 * 1024];
            let mut downloaded: i64 = 0;
            let mut last_report = Instant::now();

            loop {
                if cancel.load(std::sync::atomic::Ordering::Relaxed) {
                    return Err(AppError::new("已取消", "下载已取消".into(), ""));
                }
                let n = reader
                    .read(&mut buffer)
                    .await
                    .map_err(|e| AppError::unknown(e.to_string()))?;
                if n == 0 {
                    break;
                }
                file.write_all(&buffer[..n])
                    .await
                    .map_err(|e| AppError::unknown(e.to_string()))?;
                downloaded += n as i64;
                if let Some(h) = hasher.as_mut() {
                    h.consume(&buffer[..n]);
                }
                // Throttle progress events to ~10/s to avoid flooding the IPC channel.
                if last_report.elapsed().as_millis() >= 100 {
                    on_progress(0.1 + (downloaded as f64 / content_length) * 0.85);
                    last_report = Instant::now();
                }
            }
            file.flush().await.map_err(|e| AppError::unknown(e.to_string()))?;
            if let Some(expected) = expected_length {
                if downloaded != expected {
                    return Err(AppError::new("下载不完整", format!("预期 {} 字节，实际 {} 字节", expected, downloaded), "请重新下载"));
                }
            }

            if let (Some(h), Some(expected)) = (hasher, etag_md5) {
                let actual = format!("{:x}", h.compute());
                if actual != expected {
                    return Err(AppError::new(
                        "校验失败",
                        format!("文件 MD5 ({}) 与 S3 ETag ({}) 不一致", actual, expected),
                        "文件可能已损坏，请重新下载",
                    ));
                }
            }

            if cancel.load(std::sync::atomic::Ordering::Relaxed) {
                return Err(AppError::new("已取消", "下载已取消".into(), ""));
            }
            file.sync_all().await.map_err(|e| AppError::unknown(e.to_string()))?;
            Ok(())
        }
        .await;
        drop(file);
        if let Err(error) = result {
            let _ = tokio::fs::remove_file(&temp_path).await;
            return Err(error);
        }
        if cancel.load(std::sync::atomic::Ordering::Relaxed) {
            let _ = tokio::fs::remove_file(&temp_path).await;
            return Err(AppError::new("已取消", "下载已取消".into(), ""));
        }
        if let Err(error) = tokio::fs::rename(&temp_path, dest_path).await {
            let _ = tokio::fs::remove_file(&temp_path).await;
            return Err(AppError::unknown(error.to_string()));
        }
        on_progress(1.0);
        Ok(dest_path.to_path_buf())
    }

    // MARK: - Upload (streams from file with progress + cancellation)

    pub async fn upload_object_with_progress(
        &self,
        bucket: &str,
        key: &str,
        file_url: &Path,
        cancel: Arc<AtomicBool>,
        on_progress: Arc<dyn Fn(f64) + Send + Sync>,
    ) -> Result<(), AppError> {
        match self
            .perform_upload_streaming(
                self.client_for_bucket(bucket),
                bucket,
                key,
                file_url,
                cancel.clone(),
                on_progress.clone(),
            )
            .await
        {
            Ok(()) => Ok(()),
            Err(e) => {
                if !self.profile.endpoint.is_empty() || !e.region_redirect
                    || cancel.load(std::sync::atomic::Ordering::Relaxed) {
                    return Err(e);
                }
                let bucket_region = match self.get_bucket_region(bucket).await {
                    Ok(region) => region,
                    Err(_) => return Err(e),
                };
                if !self.bucket_region_mismatch(&bucket_region) {
                    return Err(e);
                }
                self.bucket_region_cache
                    .lock()
                    .unwrap()
                    .insert(bucket.to_string(), bucket_region.clone());
                let regional = self.regional_client(&bucket_region).map_err(AppError::unknown)?;
                self.perform_upload_streaming(regional, bucket, key, file_url, cancel, on_progress)
                    .await
            }
        }
    }

    async fn perform_upload_streaming(
        &self,
        client: Client,
        bucket: &str,
        key: &str,
        file_url: &Path,
        cancel: Arc<AtomicBool>,
        on_progress: Arc<dyn Fn(f64) + Send + Sync>,
    ) -> Result<(), AppError> {
        let meta = tokio::fs::metadata(file_url)
            .await
            .map_err(|e| AppError::unknown(e.to_string()))?;
        let total = meta.len().max(1);
        let file = tokio::fs::File::open(file_url)
            .await
            .map_err(|e| AppError::unknown(e.to_string()))?;

        // Stream the file through a channel so the SDK's HTTP client can pull
        // chunks while we report read progress (throttled).
        let (tx, rx) = tokio::sync::mpsc::channel::<Result<http_body::Frame<bytes::Bytes>, std::io::Error>>(2);
        let cb = on_progress;
        let cancel = cancel.clone();
        tauri::async_runtime::spawn(async move {
            let mut reader = file;
            let mut buf = vec![0u8; 256 * 1024];
            let mut read_total = 0u64;
            let mut last = Instant::now();
            loop {
                if cancel.load(std::sync::atomic::Ordering::Relaxed) {
                    let _ = tx
                        .send(Err(std::io::Error::new(
                            std::io::ErrorKind::Interrupted,
                            "cancelled",
                        )))
                        .await;
                    break;
                }
                match reader.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => {
                        read_total += n as u64;
                        if last.elapsed().as_millis() >= 100 {
                            cb(read_total as f64 / total as f64);
                            last = Instant::now();
                        }
                        let frame = http_body::Frame::data(bytes::Bytes::copy_from_slice(&buf[..n]));
                        if tx.send(Ok(frame)).await.is_err() {
                            break;
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Err(e)).await;
                        break;
                    }
                }
            }
        });

        let body = ByteStream::from_body_1_x(http_body_util::StreamBody::new(
            tokio_stream::wrappers::ReceiverStream::new(rx),
        ));
        client
            .put_object()
            .bucket(bucket)
            .key(key)
            .content_length(total as i64)
            .body(body)
            .send()
            .await
            .map_err(|e| classify_error(&e))?;
        Ok(())
    }

    // MARK: - Head object

    pub async fn head_object(&self, bucket: &str, key: &str) -> Result<ObjectDetail, AppError> {
        let output = self
            .client
            .head_object()
            .bucket(bucket)
            .key(key)
            .send()
            .await
            .map_err(|e| classify_error(&e))?;
        Ok(ObjectDetail {
            key: key.to_string(),
            size: output.content_length,
            last_modified: output.last_modified.map(|d| d.to_string()),
            e_tag: output.e_tag,
            storage_class: output
                .storage_class
                .map(|s| s.as_str().to_string()),
            content_type: output.content_type,
        })
    }
}

pub fn destination_path(download_dir: &str, bucket: &str, key: &str) -> PathBuf {
    PathBuf::from(download_dir).join(safe_relative(bucket)).join(safe_relative(key))
}

/// Strip `..`, `.`, empty components and path separators from a remote path so it
/// can never escape the destination directory (guards against `../` traversal).
fn safe_relative(s: &str) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in s.split(['/', '\\']) {
        if comp.is_empty() || comp == "." || comp == ".." {
            continue;
        }
        out.push(comp);
    }
    out
}
