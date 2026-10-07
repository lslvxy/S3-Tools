use crate::s3::S3Service;
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::Emitter;

pub const UPLOAD_PENDING: &str = "pending";
pub const UPLOAD_IN_PROGRESS: &str = "in_progress";
pub const UPLOAD_COMPLETED: &str = "completed";
pub const UPLOAD_FAILED: &str = "failed";
pub const UPLOAD_CANCELLED: &str = "cancelled";

#[derive(Debug, Clone, Serialize)]
pub struct UploadTask {
    pub id: String,
    pub key: String,
    pub bucket: String,
    pub file_name: String,
    pub size: i64,
    pub status: String,
    pub progress: f64,
    pub error: Option<String>,
    #[serde(skip_serializing)]
    pub file_path: String,
}

impl UploadTask {
    pub fn new(key: String, bucket: String, file_path: String, size: i64) -> Self {
        let file_name = file_path
            .rsplit(['/', '\\'])
            .next()
            .unwrap_or(&file_path)
            .to_string();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            key,
            bucket,
            file_name,
            size,
            status: UPLOAD_PENDING.to_string(),
            progress: 0.0,
            error: None,
            file_path,
        }
    }
}

struct UploadHandle {
    cancel: Arc<AtomicBool>,
}

/// Manages the upload queue: concurrency limit, cancellation, progress events.
pub struct UploadManager {
    registry: Mutex<HashMap<String, UploadHandle>>,
    semaphore: Mutex<Arc<tokio::sync::Semaphore>>,
}

impl UploadManager {
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            registry: Mutex::new(HashMap::new()),
            semaphore: Mutex::new(Arc::new(tokio::sync::Semaphore::new(max_concurrent.clamp(1, 4)))),
        }
    }

    pub fn enqueue(
        self: &Arc<Self>,
        app: tauri::AppHandle,
        service: Arc<S3Service>,
        tasks: Vec<UploadTask>,
    ) {
        let semaphore = self.semaphore.lock().unwrap().clone();
        for task in tasks {
            let cancel = Arc::new(AtomicBool::new(false));
            self.registry
                .lock()
                .unwrap()
                .insert(task.id.clone(), UploadHandle { cancel: cancel.clone() });
            let app = app.clone();
            let service = service.clone();
            let semaphore = semaphore.clone();
            let manager = Arc::clone(self);
            tauri::async_runtime::spawn(async move {
                let _permit = semaphore.acquire().await;
                if cancel.load(Ordering::Relaxed) {
                    let mut t = task;
                    t.status = UPLOAD_CANCELLED.to_string();
                    let _ = app.emit("upload-update", &t);
                    manager.registry.lock().unwrap().remove(&t.id);
                    return;
                }
                manager.run_task(app, service, task, cancel).await;
            });
        }
    }

    async fn run_task(
        &self,
        app: tauri::AppHandle,
        service: Arc<S3Service>,
        mut task: UploadTask,
        cancel: Arc<AtomicBool>,
    ) {
        task.status = UPLOAD_IN_PROGRESS.to_string();
        let _ = app.emit("upload-update", &task);

        let progress_task = task.clone();
        let app_cb = app.clone();
        let progress_cb = Arc::new(move |p: f64| {
            let mut t = progress_task.clone();
            t.status = UPLOAD_IN_PROGRESS.to_string();
            t.progress = p;
            let _ = app_cb.emit("upload-update", &t);
        });

        let result = service
            .upload_object_with_progress(
                &task.bucket,
                &task.key,
                Path::new(&task.file_path),
                cancel.clone(),
                progress_cb,
            )
            .await;

        match result {
            Ok(()) => {
                task.status = UPLOAD_COMPLETED.to_string();
                task.progress = 1.0;
            }
            Err(e) => {
                if cancel.load(Ordering::Relaxed) || e.title == "已取消" {
                    task.status = UPLOAD_CANCELLED.to_string();
                    task.error = Some(e.message);
                } else {
                    task.status = UPLOAD_FAILED.to_string();
                    task.error = Some(format!("{}: {}", e.title, e.message));
                }
            }
        }
        let _ = app.emit("upload-update", &task);
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
