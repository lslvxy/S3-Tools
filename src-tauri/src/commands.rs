use crate::config::{init_resource_dir, load_profiles, ProfileConfig};
use crate::download::{DownloadManager, DownloadTask};
use crate::logger::{LogLevel, Logger, SharedLogger};
use crate::s3::{AppError, ObjectDetail, SearchResult, S3Service};
use crate::settings::{AppSettings, SettingsStore};
use crate::upload::{UploadManager, UploadTask};
use serde::Serialize;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

// ─────────────────────────────────────────────────────────────
// Global state
// ─────────────────────────────────────────────────────────────

pub struct AppState {
    pub connection_request: Mutex<u64>,
    pub profiles: Mutex<Vec<ProfileConfig>>,
    pub selected_profile: Mutex<Option<ProfileConfig>>,
    pub service: Mutex<Option<Arc<S3Service>>>,
    pub settings: Mutex<AppSettings>,
    pub settings_store: SettingsStore,
    pub settings_load_warning: Mutex<Option<String>>,
    pub download_manager: Arc<DownloadManager>,
    pub upload_manager: Arc<UploadManager>,
    pub logger: SharedLogger,
}

#[derive(Serialize)]
pub struct ConnectResult {
    pub profile: ProfileConfig,
    pub buckets: Vec<String>,
}

// ─────────────────────────────────────────────────────────────
// Command helpers
// ─────────────────────────────────────────────────────────────

fn current_env(state: &AppState) -> String {
    state
        .selected_profile
        .lock()
        .unwrap()
        .as_ref()
        .map(|p| p.name.clone())
        .unwrap_or_else(|| "unknown".to_string())
}

fn log(state: &AppState, app: &AppHandle, level: LogLevel, action: &str, detail: &str) {
    let env = current_env(state);
    let entry = state.logger.log(level, action, detail, &env);
    let _ = app.emit("log-entry", &entry);
}

fn info(state: &AppState, app: &AppHandle, action: &str, detail: &str) {
    log(state, app, LogLevel::INFO, action, detail)
}

/// Retry listing buckets on transient connection errors with exponential backoff.
async fn retry_connect(service: &S3Service) -> Result<Vec<String>, AppError> {
    let mut delay_ms = 500u64;
    let mut last_err = None;
    for attempt in 0..3 {
        match service.list_buckets().await {
            Ok(buckets) => return Ok(buckets),
            Err(e) => {
                let retryable = e.title == "连接失败";
                if !retryable || attempt == 2 {
                    return Err(e);
                }
                last_err = Some(e);
                tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
                delay_ms *= 2;
            }
        }
    }
    Err(last_err.unwrap_or_else(|| AppError::unknown("连接失败".into())))
}

// ─────────────────────────────────────────────────────────────
// Profile & connection commands
// ─────────────────────────────────────────────────────────────

#[tauri::command]
pub fn get_profiles(state: State<'_, AppState>) -> Vec<ProfileConfig> {
    state.profiles.lock().unwrap().clone()
}

#[tauri::command]
pub fn reload_profiles(state: State<'_, AppState>) -> Vec<ProfileConfig> {
    let profiles = load_profiles(None);
    *state.profiles.lock().unwrap() = profiles.clone();
    profiles
}

#[tauri::command]
pub fn get_settings(state: State<'_, AppState>) -> AppSettings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
pub fn get_settings_load_warning(state: State<'_, AppState>) -> Option<String> {
    state.settings_load_warning.lock().unwrap().clone()
}

#[tauri::command]
pub fn get_settings_file_path(state: State<'_, AppState>) -> String {
    state.settings_store.path.to_string_lossy().to_string()
}

#[tauri::command]
pub fn reload_settings(state: State<'_, AppState>) -> Result<AppSettings, String> {
    let mut current = state.settings.lock().unwrap();
    let settings = state.settings_store.load()?;
    let max_concurrent = settings.max_concurrent_downloads.max(1) as usize;
    state.download_manager.configure(max_concurrent);
    *current = settings.clone();
    *state.settings_load_warning.lock().unwrap() = None;
    Ok(settings)
}

#[tauri::command]
pub fn reset_bookmarks(state: State<'_, AppState>) -> Result<Vec<crate::config::BookmarkEntry>, String> {
    let defaults = crate::config::default_bookmarks();
    let mut settings = state.settings.lock().unwrap();
    let mut updated = settings.clone();
    updated.bookmarks = defaults.clone();
    state
        .settings_store
        .save(&updated)
        .map_err(|e| e.to_string())?;
    *settings = updated;
    Ok(defaults)
}

#[tauri::command]
pub fn save_settings(app: AppHandle, state: State<'_, AppState>, settings: AppSettings) -> Result<(), String> {
    {
        let mut s = state.settings.lock().unwrap();
        state
            .settings_store
            .save(&settings)
            .map_err(|e| e.to_string())?;
        *s = settings.clone();
        *state.settings_load_warning.lock().unwrap() = None;
        state
            .download_manager
            .configure(settings.max_concurrent_downloads as usize);
    }
    info(&state, &app, "保存设置", "已更新应用设置");
    Ok(())
}

#[tauri::command]
pub async fn connect_profile(
    app: AppHandle,
    state: State<'_, AppState>,
    name: String,
    request_id: u64,
) -> Result<ConnectResult, AppError> {
    {
        let mut latest = state.connection_request.lock().unwrap();
        if request_id <= *latest {
            return Err(AppError::new("请求已过期", "环境连接请求已被替代".into(), ""));
        }
        *latest = request_id;
        *state.selected_profile.lock().unwrap() = None;
        *state.service.lock().unwrap() = None;
    }
    let profile = state
        .profiles
        .lock()
        .unwrap()
        .iter()
        .find(|p| p.name == name)
        .cloned()
        .ok_or_else(|| AppError::new("未找到环境", format!("Profile \"{}\" 不存在", name), "请检查 ~/.aws/s3tools 配置"))?;

    let service = Arc::new(S3Service::new(profile.clone()));
    let buckets = retry_connect(&service).await?;

    let latest = state.connection_request.lock().unwrap();
    if request_id != *latest {
        return Err(AppError::new("请求已过期", "环境连接请求已被替代".into(), ""));
    }
    *state.selected_profile.lock().unwrap() = Some(profile.clone());
    *state.service.lock().unwrap() = Some(service);
    {
        let mut settings = state.settings.lock().unwrap();
        let mut updated = settings.clone();
        updated.last_profile_name = profile.name.clone();
        // Do not overwrite a damaged configuration automatically on startup.
        if state.settings_load_warning.lock().unwrap().is_none() && state.settings_store.save(&updated).is_ok() {
            *settings = updated;
        }
    }

    drop(latest);
    info(&state, &app, "切换环境", &format!("已连接到 [{}]", profile.name));
    Ok(ConnectResult { profile, buckets })
}

// ─────────────────────────────────────────────────────────────
// Bucket / object commands
// ─────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn list_buckets(app: AppHandle, state: State<'_, AppState>) -> Result<Vec<String>, AppError> {
    let service = state
        .service
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| AppError::new("未连接", "请先选择一个环境".into(), "从顶部工具栏选择环境"))?;
    let buckets = service.list_buckets().await?;
    info(&state, &app, "列出 Buckets", &format!("共 {} 个", buckets.len()));
    Ok(buckets)
}

#[derive(serde::Deserialize)]
pub struct ListObjectsArgs {
    pub bucket: String,
    pub prefix: String,
    pub continuation_token: Option<String>,
    pub page_size: i64,
}

#[tauri::command]
pub async fn list_objects(
    app: AppHandle,
    state: State<'_, AppState>,
    args: ListObjectsArgs,
) -> Result<crate::s3::ListObjectsResult, AppError> {
    let service = state
        .service
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| AppError::new("未连接", "请先选择一个环境".into(), "从顶部工具栏选择环境"))?;
    let result = service
        .list_objects(
            &args.bucket,
            &args.prefix,
            args.continuation_token,
            args.page_size,
        )
        .await?;
    info(
        &state,
        &app,
        "列出对象",
        &format!("s3://{}/{} 共 {} 个", args.bucket, args.prefix, result.objects.len()),
    );
    Ok(result)
}

#[derive(serde::Deserialize)]
pub struct CompletionArgs {
    pub bucket: String,
    pub prefix: String,
}

#[tauri::command]
pub async fn list_completion(
    state: State<'_, AppState>,
    args: CompletionArgs,
) -> Result<Vec<String>, AppError> {
    let service = state
        .service
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| AppError::new("未连接", "请先选择一个环境".into(), "从顶部工具栏选择环境"))?;
    service.list_for_completion(&args.bucket, &args.prefix).await
}

// ─────────────────────────────────────────────────────────────
// Download commands
// ─────────────────────────────────────────────────────────────

#[derive(serde::Deserialize)]
pub struct DownloadItem {
    pub key: String,
    pub size: i64,
}

#[tauri::command]
pub fn download_selected(
    app: AppHandle,
    state: State<'_, AppState>,
    bucket: String,
    items: Vec<DownloadItem>,
) -> Result<(), String> {
    let service = state
        .service
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "未连接".to_string())?;
    let (download_dir, checksum_enabled, conflict_policy) = {
        let s = state.settings.lock().unwrap();
        (
            s.download_directory.clone(),
            s.checksum_enabled,
            s.conflict_policy.clone(),
        )
    };
    let tasks: Vec<DownloadTask> = items
        .into_iter()
        .map(|item| DownloadTask::new(item.key, bucket.clone(), item.size))
        .collect();
    let count = tasks.len();
    state.download_manager.enqueue(
        app.clone(),
        service,
        download_dir,
        checksum_enabled,
        conflict_policy,
        tasks,
    );
    info(&state, &app, "加入下载队列", &format!("{} 个文件", count));
    Ok(())
}

#[tauri::command]
pub fn cancel_download(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state.download_manager.cancel(&id);
    Ok(())
}

#[derive(serde::Deserialize)]
pub struct UploadFileItem {
    pub key: String,
    pub file_path: String,
}

#[derive(serde::Deserialize)]
pub struct UploadFilesArgs {
    pub bucket: String,
    pub files: Vec<UploadFileItem>,
}

#[tauri::command]
pub fn upload_files(
    app: AppHandle,
    state: State<'_, AppState>,
    args: UploadFilesArgs,
) -> Result<usize, AppError> {
    let service = state
        .service
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| AppError::new("未连接", "请先选择一个环境".into(), "从顶部工具栏选择环境"))?;
    let profile = state.selected_profile.lock().unwrap().clone();
    if let Some(p) = &profile {
        if p.is_production {
            return Err(AppError::new(
                "上传被禁用",
                format!("生产环境 [{}] 不允许上传", p.name),
                "Production 环境禁止上传；Offline 环境请在设置中开启上传开关",
            ));
        }
    }

    let mut tasks: Vec<UploadTask> = Vec::new();
    for item in args.files {
        let path = std::path::Path::new(&item.file_path);
        if !path.is_file() {
            continue;
        }
        let size = path.metadata().map(|m| m.len() as i64).unwrap_or(0);
        tasks.push(UploadTask::new(item.key, args.bucket.clone(), item.file_path, size));
    }
    let count = tasks.len();
    if count == 0 {
        return Err(AppError::new(
            "无有效文件",
            "没有可上传的文件".into(),
            "请重新选择要上传的文件",
        ));
    }
    state.upload_manager.enqueue(app.clone(), service, tasks);
    info(&state, &app, "加入上传队列", &format!("{} 个文件", count));
    Ok(count)
}

#[tauri::command]
pub fn cancel_upload(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state.upload_manager.cancel(&id);
    Ok(())
}

#[derive(serde::Deserialize)]
pub struct SearchArgs {
    pub bucket: String,
    pub prefix: String,
    pub query: String,
    pub continuation_token: Option<String>,
}

#[tauri::command]
pub async fn search_objects(
    app: AppHandle,
    state: State<'_, AppState>,
    args: SearchArgs,
) -> Result<SearchResult, AppError> {
    let service = state
        .service
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| AppError::new("未连接", "请先选择一个环境".into(), "从顶部工具栏选择环境"))?;
    let results = service.search(&args.bucket, &args.prefix, &args.query, args.continuation_token).await?;
    info(
        &state,
        &app,
        "搜索",
        &format!("s3://{}/{} 匹配 {} 个", args.bucket, args.prefix, results.objects.len()),
    );
    Ok(results)
}

#[derive(serde::Deserialize)]
pub struct HeadObjectArgs {
    pub bucket: String,
    pub key: String,
}

#[tauri::command]
pub async fn head_object(
    state: State<'_, AppState>,
    args: HeadObjectArgs,
) -> Result<ObjectDetail, AppError> {
    let service = state
        .service
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| AppError::new("未连接", "请先选择一个环境".into(), "从顶部工具栏选择环境"))?;
    service.head_object(&args.bucket, &args.key).await
}

// ─────────────────────────────────────────────────────────────
// Log commands
// ─────────────────────────────────────────────────────────────

#[tauri::command]
pub fn get_logs(state: State<'_, AppState>) -> Vec<crate::logger::LogEntry> {
    state.logger.entries()
}

#[tauri::command]
pub fn clear_logs(state: State<'_, AppState>) {
    state.logger.clear();
}

#[tauri::command]
pub fn get_log_file_path(state: State<'_, AppState>) -> String {
    state.logger.log_file_path()
}

// ─────────────────────────────────────────────────────────────
// Boot
// ─────────────────────────────────────────────────────────────

pub fn init_state(app: &AppHandle) {
    let app_data_dir = app
        .path()
        .app_data_dir()
        .expect("failed to resolve app data dir");
    init_resource_dir(app.path().resource_dir().unwrap_or_default());
    let log_dir = app_data_dir.join("logs");
    let settings_store = SettingsStore::new(app_data_dir);
    let (settings, settings_load_warning) = match settings_store.load() {
        Ok(settings) => (settings, None),
        Err(error) => (AppSettings::default(), Some(error)),
    };
    let max_concurrent = settings.max_concurrent_downloads.max(1) as usize;

    let state = AppState {
        connection_request: Mutex::new(0),
        profiles: Mutex::new(load_profiles(None)),
        selected_profile: Mutex::new(None),
        service: Mutex::new(None),
        settings: Mutex::new(settings),
        settings_store,
        settings_load_warning: Mutex::new(settings_load_warning),
        download_manager: Arc::new(DownloadManager::new(max_concurrent)),
        upload_manager: Arc::new(UploadManager::new(2)),
        logger: Arc::new(Logger::new(log_dir)),
    };
    app.manage(state);
}
