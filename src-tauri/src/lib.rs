pub mod cache;
pub mod scanner;

use cache::LruCache;
use scanner::Scanner;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager, State};

struct AppState {
    scanner: Arc<Mutex<Option<Scanner>>>,
    cache: Arc<Mutex<LruCache>>,
}

#[tauri::command]
async fn scan_directory(
    path: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<(), String> {
    // Check cache first
    {
        let mut cache = state.cache.lock().unwrap();
        if let Some((data, total_scanned)) = cache.get(&path) {
            // Emit cached result immediately
            use scanner::{ScanComplete, ScanProgress};
            let _ = app.emit(
                "scan:directory_complete",
                ScanProgress {
                    path: path.clone(),
                    node_data: data.clone(),
                    total_scanned,
                },
            );
            let _ = app.emit(
                "scan:complete",
                ScanComplete {
                    root: data,
                    total_scanned,
                },
            );
            return Ok(());
        }
    }

    let scanner = Scanner::new(app.clone());

    // Store scanner for cancellation
    {
        let mut scanner_lock = state.scanner.lock().unwrap();
        *scanner_lock = Some(Scanner::new(app.clone()));
    }

    let cache = state.cache.clone();
    let scan_path = path.clone();

    // Run scan in background on blocking thread pool
    tokio::task::spawn_blocking(move || {
        if let Ok((data, total_scanned)) = scanner.scan_directory_with_result(scan_path.clone()) {
            // Cache the result
            let mut cache_lock = cache.lock().unwrap();
            cache_lock.put(scan_path, data, total_scanned);
        } else if let Err(e) = scanner.scan_directory(scan_path) {
            eprintln!("Scan error: {}", e);
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

    let result = app.dialog().file().blocking_pick_folder();

    Ok(result.map(|p| p.to_string()))
}

#[tauri::command]
async fn clear_cache(state: State<'_, AppState>) -> Result<(), String> {
    let mut cache = state.cache.lock().unwrap();
    cache.clear();
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let state = AppState {
                scanner: Arc::new(Mutex::new(None)),
                cache: Arc::new(Mutex::new(LruCache::new())),
            };
            app.manage(state);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            scan_directory,
            cancel_scan,
            get_home_dir,
            pick_directory,
            clear_cache,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
