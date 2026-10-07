use chrono::Local;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum LogLevel {
    DEBUG,
    INFO,
    #[serde(rename = "WARN")]
    WARNING,
    ERROR,
}

impl LogLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            LogLevel::DEBUG => "DEBUG",
            LogLevel::INFO => "INFO",
            LogLevel::WARNING => "WARN",
            LogLevel::ERROR => "ERROR",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct LogEntry {
    pub id: String,
    pub timestamp: String,
    pub level: LogLevel,
    pub action: String,
    pub detail: String,
    pub environment: String,
    pub line: String,
}

impl LogEntry {
    fn new(level: LogLevel, action: &str, detail: &str, environment: &str) -> Self {
        let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let line = format!(
            "[{}] [{}] [{}] {}: {}",
            timestamp,
            level.as_str(),
            environment,
            action,
            detail
        );
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            timestamp,
            level,
            action: action.to_string(),
            detail: detail.to_string(),
            environment: environment.to_string(),
            line,
        }
    }
}

pub struct Logger {
    entries: Mutex<VecDeque<LogEntry>>,
    file: Mutex<Option<File>>,
    log_file: PathBuf,
}

const LOG_RETENTION_DAYS: u64 = 14;

impl Logger {
    pub fn new(log_dir: PathBuf) -> Self {
        fs::create_dir_all(&log_dir).ok();
        Self::rotate_old_logs(&log_dir);
        let today = Local::now().format("%Y-%m-%d").to_string();
        let log_file = log_dir.join(format!("s3rust-{}.log", today));
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_file)
            .ok();
        Self {
            entries: Mutex::new(VecDeque::new()),
            file: Mutex::new(file),
            log_file,
        }
    }

    fn rotate_old_logs(log_dir: &PathBuf) {
        let now = SystemTime::now();
        let cutoff = now
            .checked_sub(Duration::from_secs(LOG_RETENTION_DAYS * 24 * 3600))
            .unwrap_or(now);
        if let Ok(entries) = fs::read_dir(log_dir) {
            for entry in entries.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                if name.starts_with("s3rust-") && name.ends_with(".log") {
                    if let Ok(meta) = entry.metadata() {
                        if let Ok(modified) = meta.modified() {
                            if modified < cutoff {
                                let _ = fs::remove_file(entry.path());
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn log(&self, level: LogLevel, action: &str, detail: &str, environment: &str) -> LogEntry {
        let entry = LogEntry::new(level, action, detail, environment);
        self.append_to_file(&entry.line);
        let mut entries = self.entries.lock().unwrap();
        entries.push_front(entry.clone());
        if entries.len() > 1000 {
            entries.truncate(1000);
        }
        entry
    }

    pub fn entries(&self) -> Vec<LogEntry> {
        self.entries.lock().unwrap().iter().cloned().collect()
    }

    pub fn clear(&self) {
        self.entries.lock().unwrap().clear();
    }

    pub fn log_file_path(&self) -> String {
        self.log_file.to_string_lossy().to_string()
    }

    fn append_to_file(&self, line: &str) {
        if let Ok(mut guard) = self.file.lock() {
            if let Some(f) = guard.as_mut() {
                let _ = writeln!(f, "{}", line);
                let _ = f.flush();
            }
        }
    }
}

pub type SharedLogger = Arc<Logger>;
