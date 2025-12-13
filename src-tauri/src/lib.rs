pub mod file_ops;
pub mod scanner;

use scanner::{scan_folder, FileNode, ScanComplete, ScanState};
use tauri::{AppHandle, Emitter, Manager, State};

#[tauri::command]
async fn scan_directory(path: String, app: AppHandle, state: State<'_, ScanState>) -> Result<(), String> {
    state.reset();
    
    let state_data = state.data.clone();
    let cancelled = state.cancelled.clone();
    let app_clone = app.clone();
    
    // Run scan in background on blocking thread pool
    tokio::task::spawn_blocking(move || {
        match scan_folder(path.clone(), state_data, cancelled, app_clone.clone()) {
            Ok((total_scanned, total_size)) => {
                let _ = app_clone.emit(
                    "scan:complete",
                    ScanComplete {
                        root_path: path,
                        total_scanned,
                        total_size,
                    },
                );
            }
            Err(e) => {
                eprintln!("Scan error: {}", e);
            }
        }
    });

    Ok(())
}

#[tauri::command]
async fn cancel_scan(state: State<'_, ScanState>) -> Result<(), String> {
    state.cancel();
    Ok(())
}

#[tauri::command]
async fn get_children(path: String, state: State<'_, ScanState>) -> Result<Vec<FileNode>, String> {
    let data = state.data.lock().unwrap();
    Ok(data.get(&path).cloned().unwrap_or_default())
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let scan_state = ScanState::new();
            app.manage(scan_state);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            scan_directory,
            cancel_scan,
            get_children,
            get_home_dir,
            pick_directory,
            file_ops::file_preview,
            file_ops::file_open,
            file_ops::file_delete,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
