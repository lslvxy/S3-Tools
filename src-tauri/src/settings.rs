use crate::config::{default_bookmarks, BookmarkEntry, BOOKMARKS_VERSION};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::io::Write;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AppSettings {
    pub page_size: i64,
    pub max_concurrent_downloads: i64,
    pub download_directory: String,
    pub checksum_enabled: bool,
    pub conflict_policy: String,
    pub log_level: String,
    pub completion_cache_ttl: f64,
    pub last_profile_name: String,
    pub bookmarks_version: i32,
    pub bookmarks: Vec<BookmarkEntry>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            page_size: 200,
            max_concurrent_downloads: 4,
            download_directory: dirs::download_dir()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|| ".".to_string()),
            checksum_enabled: false,
            conflict_policy: "overwrite".to_string(),
            log_level: "INFO".to_string(),
            completion_cache_ttl: 60.0,
            last_profile_name: String::new(),
            bookmarks_version: BOOKMARKS_VERSION,
            bookmarks: default_bookmarks(),
        }
    }
}

pub struct SettingsStore {
    pub path: PathBuf,
}

impl SettingsStore {
    pub fn new(app_data_dir: PathBuf) -> Self {
        fs::create_dir_all(&app_data_dir).ok();
        Self {
            path: app_data_dir.join("settings.json"),
        }
    }

    pub fn load(&self) -> Result<AppSettings, String> {
        let mut settings: AppSettings = match fs::read_to_string(&self.path) {
            Ok(s) => serde_json::from_str(&s).map_err(|e| format!("配置文件 {} 无法解析，原文件已保留：{}", self.path.display(), e))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => AppSettings::default(),
            Err(e) => return Err(format!("无法读取配置文件 {}：{}", self.path.display(), e)),
        };
        Self::migrate_bookmarks(&mut settings);
        Ok(settings)
    }

    pub fn save(&self, settings: &AppSettings) -> Result<(), String> {
        let json = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
        let temp = self.path.with_file_name(format!(".settings-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> std::io::Result<()> {
            let mut file = fs::OpenOptions::new().write(true).create_new(true).open(&temp)?;
            file.write_all(json.as_bytes())?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temp, &self.path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temp);
        }
        result.map_err(|e| format!("配置保存失败：{}", e))
    }

    /// Mirror the Swift migration: when bookmarksVersion is behind, reset the
    /// built-in entries while preserving user-added ones.
    fn migrate_bookmarks(settings: &mut AppSettings) {
        if settings.bookmarks_version < BOOKMARKS_VERSION {
            let default_names: HashSet<String> = default_bookmarks()
                .iter()
                .map(|b| b.name.clone())
                .collect();
            let user_added: Vec<BookmarkEntry> = settings
                .bookmarks
                .iter()
                .filter(|b| !default_names.contains(b.name.as_str()))
                .cloned()
                .collect();
            let mut merged = default_bookmarks();
            merged.extend(user_added);
            settings.bookmarks = merged;
            settings.bookmarks_version = BOOKMARKS_VERSION;
        }
    }
}