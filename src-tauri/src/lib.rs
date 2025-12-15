pub mod file_ops;
pub mod scanner;
pub mod volumes;

use scanner::{DirNode, Scanner};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Manager, State};

struct AppState {
    scanner: Arc<Mutex<Option<Scanner>>>,
}

#[tauri::command]
async fn scan_directory(
    path: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    let scanner = Scanner::new(app.clone());

    // Store scanner for cancellation
    {
        let mut scanner_lock = state.scanner.lock().expect("Scanner lock poisoned");
        *scanner_lock = Some(scanner.clone());
    }

    // Run scan in background on blocking thread pool
    tokio::task::spawn_blocking(move || {
        if let Err(e) = scanner.scan_directory(path.clone()) {
            eprintln!("Scan error: {}", e);
        }
    });

    Ok(())
}

#[tauri::command]
async fn cancel_scan(state: State<'_, AppState>) -> Result<(), String> {
    let scanner_lock = state.scanner.lock().expect("Scanner lock poisoned");
    if let Some(scanner) = scanner_lock.as_ref() {
        scanner.cancel();
    }
    Ok(())
}

#[tauri::command]
async fn get_home_dir() -> Result<String, String> {
    dirs::home_dir()
        .and_then(|p| p.to_str().map(|s| s.to_string()))
        .ok_or_else(|| "Could not determine home directory".to_string())
}

#[tauri::command]
async fn pick_directory(app: AppHandle) -> Result<Option<String>, String> {
    use tauri_plugin_dialog::DialogExt;

    let result = app.dialog().file().blocking_pick_folder();

    Ok(result.map(|p| p.to_string()))
}

#[tauri::command]
async fn load_children(path: String) -> Result<Vec<DirNode>, String> {
    let path_buf = PathBuf::from(&path);
    tokio::task::spawn_blocking(move || scanner::load_children(&path_buf))
        .await
        .map_err(|e| format!("Task failed: {}", e))?
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let state = AppState {
                scanner: Arc::new(Mutex::new(None)),
            };
            app.manage(state);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            scan_directory,
            cancel_scan,
            get_home_dir,
            pick_directory,
            load_children,
            volumes::list_volumes,
            file_ops::file_preview,
            file_ops::file_open,
            file_ops::file_delete,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
