mod commands;
mod config;
mod download;
mod logger;
mod s3;
mod settings;
mod upload;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .setup(|app| {
            commands::init_state(app.handle());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_profiles,
            commands::reload_profiles,
            commands::get_settings,
            commands::get_settings_load_warning,
            commands::get_settings_file_path,
            commands::reload_settings,
            commands::save_settings,
            commands::reset_bookmarks,
            commands::connect_profile,
            commands::list_buckets,
            commands::list_objects,
            commands::list_completion,
            commands::search_objects,
            commands::download_selected,
            commands::cancel_download,
            commands::upload_files,
            commands::cancel_upload,
            commands::head_object,
            commands::get_logs,
            commands::clear_logs,
            commands::get_log_file_path,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}