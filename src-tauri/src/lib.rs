mod cache;
mod events;
mod scanner;

use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

use rayon::ThreadPoolBuilder;
use tauri::{AppHandle, Emitter, State};

use crate::{
    cache::{CachedScan, ScanCache},
    events::DirectoryCompletePayload,
};

struct ActiveScan {
    cancel: Arc<AtomicBool>,
}

struct ScanManager {
    active: Mutex<Option<ActiveScan>>,
    cache: ScanCache,
}

impl ScanManager {
    fn new() -> Self {
        Self {
            active: Mutex::new(None),
            cache: ScanCache::new(),
        }
    }

    fn cancel_current(&self) {
        if let Some(active) = self.active.lock().expect("scan manager mutex poisoned").as_ref() {
            active.cancel.store(true, Ordering::Relaxed);
        }
    }

    fn set_active(&self, active: ActiveScan) {
        *self.active.lock().expect("scan manager mutex poisoned") = Some(active);
    }

    fn clear_active(&self) {
        *self.active.lock().expect("scan manager mutex poisoned") = None;
    }
}

#[tauri::command]
fn get_home_dir() -> Result<String, String> {
    dirs::home_dir()
        .map(|p| p.display().to_string())
        .ok_or_else(|| "Unable to determine home directory".to_string())
}

#[tauri::command]
async fn pick_directory() -> Result<Option<String>, String> {
    let picked = tauri::async_runtime::spawn_blocking(move || rfd::FileDialog::new().pick_folder())
        .await
        .map_err(|_| "Directory picker failed".to_string())?;
    Ok(picked.map(|p| p.display().to_string()))
}

#[tauri::command]
fn cancel_scan(state: State<'_, Arc<ScanManager>>) -> Result<(), String> {
    state.cancel_current();
    Ok(())
}

#[tauri::command]
fn scan_directory(
    app: AppHandle,
    state: State<'_, Arc<ScanManager>>,
    path: String,
) -> Result<(), String> {
    let root = PathBuf::from(path);
    let root_meta = std::fs::metadata(&root).map_err(|_| "Path does not exist".to_string())?;
    if !root_meta.is_dir() {
        return Err("Path is not a directory".to_string());
    }

    // Cancel any existing scan.
    state.cancel_current();

    let dir_mtime = scanner::dir_mtime(&root).unwrap_or(std::time::SystemTime::UNIX_EPOCH);
    let cache_key = ScanCache::key(&root, dir_mtime);
    if let Some(cached) = state.cache.get(&cache_key) {
        // Fast path: emit cached data and return immediately.
        let _ = app.emit(
            "scan:directory_complete",
            DirectoryCompletePayload {
                path: cached.root.path.clone(),
                node_data: cached.root.clone(),
                total_scanned: cached.total_scanned,
            },
        );
        let _ = app.emit(
            "scan:complete",
            crate::events::ScanCompletePayload {
                root: cached.root,
                total_scanned: cached.total_scanned,
            },
        );
        return Ok(());
    }

    let cancel = Arc::new(AtomicBool::new(false));
    state.set_active(ActiveScan { cancel: cancel.clone() });

    // Limit rayon threads to 80% CPU cores, at least 1.
    let threads = ((num_cpus::get() as f32) * 0.8).ceil() as usize;
    let threads = threads.max(1);
    let pool = ThreadPoolBuilder::new()
        .num_threads(threads)
        .build()
        .map_err(|e| format!("Failed to create thread pool: {}", e))?;

    let app_for_task = app.clone();
    let state_for_task = state.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let result = scanner::scan_tree_streaming(app_for_task.clone(), root.clone(), pool, cancel);
        if let Some((root_node, total_scanned)) = result {
            state_for_task.cache.put(
                cache_key,
                CachedScan {
                    root: root_node,
                    total_scanned,
                },
            );
        }
        state_for_task.clear_active();
    });

    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(Arc::new(ScanManager::new()))
        .invoke_handler(tauri::generate_handler![
            scan_directory,
            cancel_scan,
            get_home_dir,
            pick_directory
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
