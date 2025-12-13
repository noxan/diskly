use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::Emitter;
use walkdir::WalkDir;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileNode {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub is_dir: bool,
    pub child_count: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScanProgress {
    pub current_path: String,
    pub total_scanned: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScanComplete {
    pub root_path: String,
    pub total_scanned: u64,
    pub total_size: u64,
}

pub type ScanStateData = Arc<Mutex<HashMap<String, Vec<FileNode>>>>;

pub struct ScanState {
    pub data: ScanStateData,
    pub cancelled: Arc<AtomicBool>,
}

impl Default for ScanState {
    fn default() -> Self {
        Self::new()
    }
}

impl ScanState {
    pub fn new() -> Self {
        Self {
            data: Arc::new(Mutex::new(HashMap::new())),
            cancelled: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn reset(&self) {
        self.data.lock().unwrap().clear();
        self.cancelled.store(false, Ordering::SeqCst);
    }
}

pub fn scan_folder(
    root_path: String,
    state: ScanStateData,
    cancelled: Arc<AtomicBool>,
    app: tauri::AppHandle,
) -> Result<(u64, u64), String> {
    let root = PathBuf::from(&root_path);
    
    if !root.exists() {
        return Err("Path does not exist".to_string());
    }
    
    if !root.is_dir() {
        return Err("Path is not a directory".to_string());
    }

    // Clear previous state
    state.lock().unwrap().clear();
    
    let mut dir_sizes: HashMap<String, u64> = HashMap::new();
    let mut dir_child_counts: HashMap<String, usize> = HashMap::new();
    let mut total_scanned = 0u64;
    let mut inode_tracker: HashMap<(u64, u64), PathBuf> = HashMap::new();
    
    // First pass: collect all files and calculate sizes
    for entry in WalkDir::new(&root)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if cancelled.load(Ordering::SeqCst) {
            return Err("Scan cancelled".to_string());
        }

        let path = entry.path();
        let path_str = path.to_string_lossy().to_string();
        
        // Emit progress every 1000 items
        total_scanned += 1;
        if total_scanned.is_multiple_of(1000) {
            let _ = app.emit(
                "scan:progress",
                ScanProgress {
                    current_path: path_str.clone(),
                    total_scanned,
                },
            );
        }

        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };

        let size = if metadata.is_file() {
            get_file_size(path, &metadata, &mut inode_tracker)
        } else {
            0
        };

        // Update parent directory size
        if let Some(parent) = path.parent() {
            let parent_str = parent.to_string_lossy().to_string();
            *dir_sizes.entry(parent_str.clone()).or_insert(0) += size;
            *dir_child_counts.entry(parent_str).or_insert(0) += 1;
        }

        // Propagate size up the tree
        let mut current = path.parent();
        while let Some(p) = current {
            if p == root {
                break;
            }
            let parent_str = p.to_string_lossy().to_string();
            *dir_sizes.entry(parent_str).or_insert(0) += size;
            current = p.parent();
        }
    }

    // Second pass: build the HashMap structure
    let mut parent_map: HashMap<String, Vec<FileNode>> = HashMap::new();
    
    for entry in WalkDir::new(&root)
        .follow_links(false)
        .max_depth(usize::MAX)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if cancelled.load(Ordering::SeqCst) {
            return Err("Scan cancelled".to_string());
        }

        let path = entry.path();
        let path_str = path.to_string_lossy().to_string();
        
        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };

        let is_dir = metadata.is_dir();
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
            .to_string();

        let size = if is_dir {
            *dir_sizes.get(&path_str).unwrap_or(&0)
        } else {
            get_file_size(path, &metadata, &mut inode_tracker)
        };

        let child_count = *dir_child_counts.get(&path_str).unwrap_or(&0);

        let node = FileNode {
            path: path_str.clone(),
            name,
            size,
            is_dir,
            child_count,
        };

        // Add to parent's children list
        if let Some(parent) = path.parent() {
            let parent_str = parent.to_string_lossy().to_string();
            parent_map.entry(parent_str).or_default().push(node);
        }
    }

    // Sort children by size (descending)
    for children in parent_map.values_mut() {
        children.sort_by(|a, b| b.size.cmp(&a.size));
    }

    let total_size = *dir_sizes.get(&root_path).unwrap_or(&0);
    
    // Store in shared state
    *state.lock().unwrap() = parent_map;

    Ok((total_scanned, total_size))
}

#[cfg(unix)]
fn get_file_size(
    path: &Path,
    metadata: &fs::Metadata,
    inode_tracker: &mut HashMap<(u64, u64), PathBuf>,
) -> u64 {
    use std::os::unix::fs::MetadataExt;

    let dev = metadata.dev();
    let ino = metadata.ino();
    let nlink = metadata.nlink();

    // Handle hard links - count only once
    if nlink > 1 {
        let key = (dev, ino);
        if inode_tracker.contains_key(&key) {
            return 0;
        }
        inode_tracker.insert(key, path.to_path_buf());
    }

    // Use actual disk usage
    metadata.blocks() * 512
}

#[cfg(not(unix))]
fn get_file_size(
    _path: &Path,
    metadata: &fs::Metadata,
    _inode_tracker: &mut HashMap<(u64, u64), PathBuf>,
) -> u64 {
    metadata.len()
}
