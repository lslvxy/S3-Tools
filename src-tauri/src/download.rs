use crate::s3::{destination_path, S3Service};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tauri::Emitter;

pub const STATUS_PENDING: &str = "pending";
pub const STATUS_IN_PROGRESS: &str = "in_progress";
pub const STATUS_COMPLETED: &str = "completed";
pub const STATUS_FAILED: &str = "failed";
pub const STATUS_CANCELLED: &str = "cancelled";
pub const STATUS_SKIPPED: &str = "skipped";

#[derive(Debug, Clone, Serialize)]
pub struct DownloadTask {
    pub id: String,
    pub key: String,
    pub bucket: String,
    pub size: i64,
    pub status: String,
    pub progress: f64,
    pub bytes_downloaded: i64,
    pub speed: f64,
    pub local_url: Option<String>,
    pub file_name: String,
    pub error: Option<String>,
}

impl DownloadTask {
    pub fn new(key: String, bucket: String, size: i64) -> Self {
        let file_name = key.rsplit('/').next().unwrap_or(&key).to_string();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            key,
            bucket,
            size,
            status: STATUS_PENDING.to_string(),
            progress: 0.0,
            bytes_downloaded: 0,
            speed: 0.0,
            local_url: None,
            file_name,
            error: None,
        }
    }
}

struct DownloadHandle {
    cancel: Arc<AtomicBool>,
}

struct DownloadLimiter {
    state: Mutex<(usize, usize)>, // (active, limit)
    changed: tokio::sync::Notify,
}

struct DownloadPermit(Arc<DownloadLimiter>);

impl Drop for DownloadPermit {
    fn drop(&mut self) {
        self.0.state.lock().unwrap().0 -= 1;
        self.0.changed.notify_waiters();
    }
}

impl DownloadLimiter {
    async fn acquire(self: &Arc<Self>) -> DownloadPermit {
        loop {
            let notified = self.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let mut state = self.state.lock().unwrap();
                if state.0 < state.1 {
                    state.0 += 1;
                    return DownloadPermit(Arc::clone(self));
                }
            }
            notified.await;
        }
    }
}

/// Manages the download queue: concurrency limit, cancellation, progress events.
pub struct DownloadManager {
    registry: Mutex<HashMap<String, DownloadHandle>>,
    limiter: Arc<DownloadLimiter>,
}

impl DownloadManager {
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            registry: Mutex::new(HashMap::new()),
            limiter: Arc::new(DownloadLimiter {
                state: Mutex::new((0, max_concurrent.clamp(1, 16))),
                changed: tokio::sync::Notify::new(),
            }),
        }
    }

    pub fn configure(&self, max_concurrent: usize) {
        self.limiter.state.lock().unwrap().1 = max_concurrent.clamp(1, 16);
        self.limiter.changed.notify_waiters();
    }

    /// Enqueue downloads. Each runs in a tokio task honoring the concurrency limit.
    /// Emits `download-update` events carrying each DownloadTask.
    pub fn enqueue(
        self: &Arc<Self>,
        app: tauri::AppHandle,
        service: Arc<S3Service>,
        download_dir: String,
        checksum_enabled: bool,
        conflict_policy: String,
        tasks: Vec<DownloadTask>,
    ) {
        let limiter = self.limiter.clone();
        for task in tasks {
            let cancel = Arc::new(AtomicBool::new(false));
            self.registry
                .lock()
                .unwrap()
                .insert(task.id.clone(), DownloadHandle { cancel: cancel.clone() });
            let app = app.clone();
            let service = service.clone();
            let limiter = limiter.clone();
            let manager = Arc::clone(self);
            let dd = download_dir.clone();
            let checksum_enabled = checksum_enabled;
            let conflict_policy = conflict_policy.clone();
            tauri::async_runtime::spawn(async move {
                let _permit = limiter.acquire().await;
                if cancel.load(Ordering::Relaxed) {
                    let mut t = task;
                    t.status = STATUS_CANCELLED.to_string();
                    let _ = app.emit("download-update", &t);
                    manager.registry.lock().unwrap().remove(&t.id);
                    return;
                }
                manager
                    .run_task(app, service, dd, checksum_enabled, conflict_policy, task, cancel)
                    .await;
            });
        }
    }

    async fn run_task(
        &self,
        app: tauri::AppHandle,
        service: Arc<S3Service>,
        download_dir: String,
        checksum_enabled: bool,
        conflict_policy: String,
        mut task: DownloadTask,
        cancel: Arc<AtomicBool>,
    ) {
        let dest = destination_path(&download_dir, &task.bucket, &task.key);
        match conflict_policy.as_str() {
            "skip" => {
                if dest.exists() {
                    task.status = STATUS_SKIPPED.to_string();
                    task.error = Some("本地文件已存在，已跳过".to_string());
                    let _ = app.emit("download-update", &task);
                    self.registry.lock().unwrap().remove(&task.id);
                    return;
                }
            }
            "rename" => {
                let dest = unique_path(&dest);
                return self.run_download(app, service, task, dest, cancel, checksum_enabled).await;
            }
            _ => {}
        }

        self.run_download(app, service, task, dest, cancel, checksum_enabled)
            .await;
    }

    async fn run_download(
        &self,
        app: tauri::AppHandle,
        service: Arc<S3Service>,
        mut task: DownloadTask,
        dest: std::path::PathBuf,
        cancel: Arc<AtomicBool>,
        checksum_enabled: bool,
    ) {
        let started = Instant::now();
        task.status = STATUS_IN_PROGRESS.to_string();
        let _ = app.emit("download-update", &task);

        let progress_task = task.clone();
        let app_cb = app.clone();
        let started_cb = started;
        let cancel_cb = cancel.clone();
        let progress_cb = move |p: f64| {
            let mut t = progress_task.clone();
            t.status = STATUS_IN_PROGRESS.to_string();
            t.progress = p;
            t.bytes_downloaded = (t.size as f64 * p) as i64;
            let elapsed = started_cb.elapsed().as_secs_f64();
            if elapsed > 0.0 {
                t.speed = t.bytes_downloaded as f64 / elapsed;
            }
            let _ = app_cb.emit("download-update", &t);
        };

        let result = service
            .download_object(&task.bucket, &task.key, &dest, cancel_cb, progress_cb, checksum_enabled)
            .await;

        match result {
            Ok(path) => {
                task.status = STATUS_COMPLETED.to_string();
                task.progress = 1.0;
                task.bytes_downloaded = task.size;
                task.local_url = Some(path.to_string_lossy().to_string());
            }
            Err(e) => {
                if cancel.load(Ordering::Relaxed) || e.title == "已取消" {
                    task.status = STATUS_CANCELLED.to_string();
                    task.error = Some(e.message);
                } else {
                    task.status = STATUS_FAILED.to_string();
                    task.error = Some(format!("{}: {}", e.title, e.message));
                }
            }
        }
        let _ = app.emit("download-update", &task);
        self.registry.lock().unwrap().remove(&task.id);
    }

    pub fn cancel(&self, id: &str) -> bool {
        if let Some(handle) = self.registry.lock().unwrap().get(id) {
            handle.cancel.store(true, Ordering::Relaxed);
            true
        } else {
            false
        }
    }
}

/// Return `path` if free, otherwise append " (1)", " (2)" … before the extension.
fn unique_path(path: &std::path::Path) -> std::path::PathBuf {
    if !path.exists() {
        return path.to_path_buf();
    }
    let parent = path.parent().unwrap_or(std::path::Path::new(""));
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .map(|e| format!(".{}", e))
        .unwrap_or_default();
    let mut n = 1;
    loop {
        let candidate = parent.join(format!("{} ({}){}", stem, n, ext));
        if !candidate.exists() {
            return candidate;
        }
        n += 1;
    }
}
