#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod phoenix;
mod tray;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            let app_handle = app.handle().clone();
            phoenix::start_phoenix(&app_handle)?;
            tray::setup_tray(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                #[cfg(target_os = "macos")]
                {
                    window.hide().unwrap_or_default();
                    api.prevent_close();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_phoenix_status,
            restart_phoenix,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Symphony Desktop");
}

#[tauri::command]
fn get_phoenix_status(app: tauri::AppHandle) -> String {
    phoenix::get_status(&app)
}

#[tauri::command]
fn restart_phoenix(app: tauri::AppHandle) -> Result<String, String> {
    phoenix::restart(&app).map(|_| "restarted".to_string())
}
