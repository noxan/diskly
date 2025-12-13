mod scanner;
mod cache;

use scanner::Scanner;
use cache::ScanCache;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Manager, State, Emitter};

struct AppState {
    scanner: Arc<Mutex<Option<Scanner>>>,
    cache: Arc<ScanCache>,
}

#[tauri::command]
async fn scan_directory(path: String, app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    // Check cache first
    if let Some(cached) = state.cache.get(&path) {
        let _ = app.emit("scan:complete", scanner::ScanComplete {
            root: cached,
            total_scanned: 0,
        });
        return Ok(());
    }

    let scanner = Scanner::new(app.clone());
    
    // Store scanner for cancellation
    {
        let mut scanner_lock = state.scanner.lock().unwrap();
        *scanner_lock = Some(Scanner::new(app.clone()));
    }

    // Run scan in background
    let _cache = state.cache.clone();
    let _path_clone = path.clone();
    
    tokio::spawn(async move {
        match scanner.scan_directory(path.clone()) {
            Ok(_) => {
                // Cache the result - we'll need to get it from the complete event
                // For simplicity, we skip caching here and let the frontend handle it
            }
            Err(e) => {
                eprintln!("Scan error: {}", e);
            }
        }
    });

    Ok(())
}

#[tauri::command]
async fn cancel_scan(state: State<'_, AppState>) -> Result<(), String> {
    let scanner_lock = state.scanner.lock().unwrap();
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
    
    let result = app.dialog()
        .file()
        .blocking_pick_folder();
    
    Ok(result.map(|p| p.to_string()))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let state = AppState {
                scanner: Arc::new(Mutex::new(None)),
                cache: Arc::new(ScanCache::new()),
            };
            app.manage(state);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            scan_directory,
            cancel_scan,
            get_home_dir,
            pick_directory,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
