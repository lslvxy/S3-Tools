use std::fs;
use std::path::Path;

fn main() {
    // `default_bookmarks.json` is gitignored and only exists locally. Create an
    // empty placeholder when missing so `bundle.resources` never fails on
    // open-source builds (which have no personal default bookmarks).
    let path = Path::new("resources/default_bookmarks.json");
    if !path.exists() {
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = fs::write(path, "[]\n");
    }
    tauri_build::build()
}
