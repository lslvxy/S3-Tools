use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

// ─────────────────────────────────────────────────────────────
// INI parser (awscli style, mirrors the Swift INIParser)
// ─────────────────────────────────────────────────────────────

pub fn parse_ini(content: &str) -> HashMap<String, HashMap<String, String>> {
    let mut sections: HashMap<String, HashMap<String, String>> = HashMap::new();
    let mut current: Option<(String, HashMap<String, String>)> = None;

    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            if let Some((name, vals)) = current.take() {
                sections.insert(name, vals);
            }
            let mut name = line[1..line.len() - 1].trim().to_string();
            if let Some(stripped) = name.strip_prefix("profile ") {
                name = stripped.trim().to_string();
            }
            current = Some((name, HashMap::new()));
            continue;
        }
        if let Some(eq) = line.find('=') {
            if let Some((_name, vals)) = current.as_mut() {
                let key = line[..eq].trim().to_string();
                let value = line[eq + 1..].trim().to_string();
                vals.insert(key, value);
            }
        }
    }
    if let Some((name, vals)) = current {
        sections.insert(name, vals);
    }
    sections
}

pub fn parse_ini_file(path: &Path) -> Result<HashMap<String, HashMap<String, String>>, String> {
    let content = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    Ok(parse_ini(&content))
}

// ─────────────────────────────────────────────────────────────
// Profile
// ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileConfig {
    pub name: String,
    pub access_key_id: String,
    #[serde(skip_serializing)]
    pub secret_access_key: String,
    #[serde(skip_serializing)]
    pub session_token: Option<String>,
    pub region: String,
    pub endpoint: String,
    pub use_path_style: bool,
    pub is_production: bool,
    pub default_bucket: String,
}

pub static PRODUCTION_KEYWORDS: [&str; 5] = ["prod", "production", "live", "online", "prd"];

pub fn detects_production(name: &str) -> bool {
    let lower = name.to_lowercase();
    PRODUCTION_KEYWORDS.iter().any(|k| lower.contains(k))
}

impl ProfileConfig {
    pub fn effective_region(&self) -> String {
        if self.region.is_empty() {
            "ap-southeast-1".to_string()
        } else {
            self.region.clone()
        }
    }
}

/// Parse ~/.aws/s3tools, returns profiles sorted by name.
pub fn load_profiles(config_path: Option<&Path>) -> Vec<ProfileConfig> {
    let path = config_path
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".aws/s3tools"));

    let sections = match parse_ini_file(&path) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };

    let default_region = sections
        .get("default")
        .and_then(|s| s.get("region"))
        .cloned()
        .unwrap_or_else(|| "ap-southeast-1".to_string());

    let mut profiles: Vec<ProfileConfig> = Vec::new();
    for (name, section) in sections {
        if name == "default" {
            continue;
        }
        let ak = match section.get("aws_access_key_id") {
            Some(v) if !v.is_empty() => v.clone(),
            _ => continue,
        };
        let sk = match section.get("aws_secret_access_key") {
            Some(v) if !v.is_empty() => v.clone(),
            _ => continue,
        };

        let region = section
            .get("region")
            .cloned()
            .unwrap_or_else(|| default_region.clone());
        let endpoint = section.get("endpoint").cloned().unwrap_or_default();
        let use_path_style = section
            .get("path_style")
            .map(|v| v.to_lowercase() == "true")
            .unwrap_or(false);

        let is_production = if let Some(explicit) = section.get("is_production") {
            explicit.to_lowercase() == "true"
        } else {
            detects_production(&name)
        };

        profiles.push(ProfileConfig {
            name: name.clone(),
            access_key_id: ak,
            secret_access_key: sk,
            session_token: section.get("aws_session_token").cloned(),
            region,
            endpoint,
            use_path_style,
            is_production,
            default_bucket: section.get("default_bucket").cloned().unwrap_or_default(),
        });
    }

    profiles.sort_by(|a, b| a.name.cmp(&b.name));
    profiles
}

// ─────────────────────────────────────────────────────────────
// Bookmarks
// ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookmarkEntry {
    pub id: uuid::Uuid,
    pub name: String,
    pub path: String,
}

pub const BOOKMARKS_VERSION: i32 = 2;

/// Resource dir (set at startup from the Tauri app). Used to locate the
/// bundled default bookmarks file inside a packaged app.
static RESOURCE_DIR: OnceLock<PathBuf> = OnceLock::new();

pub fn init_resource_dir(dir: PathBuf) {
    let _ = RESOURCE_DIR.set(dir);
}

/// Default bookmarks live in `src-tauri/resources/default_bookmarks.json`.
/// That file is git-ignored (private paths) and only bundled on local
/// packaging; when absent we fall back to an empty default set.
pub fn default_bookmarks() -> Vec<BookmarkEntry> {
    default_bookmarks_path()
        .and_then(|path| load_bookmarks(&path))
        .unwrap_or_default()
}

fn default_bookmarks_path() -> Option<PathBuf> {
    if let Some(dir) = RESOURCE_DIR.get() {
        let bundled = dir.join("default_bookmarks.json");
        if bundled.is_file() {
            return Some(bundled);
        }
    }
    let dev = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("resources/default_bookmarks.json");
    if dev.is_file() {
        Some(dev)
    } else {
        None
    }
}

fn load_bookmarks(path: &Path) -> Option<Vec<BookmarkEntry>> {
    let content = fs::read_to_string(path).ok()?;
    let raw: Vec<serde_json::Value> = serde_json::from_str(&content).ok()?;
    Some(
        raw.into_iter()
            .filter_map(|v| {
                Some(BookmarkEntry {
                    id: uuid::Uuid::new_v4(),
                    name: v.get("name")?.as_str()?.to_string(),
                    path: v.get("path")?.as_str()?.to_string(),
                })
            })
            .collect(),
    )
}