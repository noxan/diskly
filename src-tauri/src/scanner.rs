use dashmap::DashMap;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tauri::{AppHandle, Emitter};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirNode {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub children: Vec<DirNode>,
    pub is_file: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScanProgress {
    pub path: String,
    pub node_data: DirNode,
    pub total_scanned: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScanComplete {
    pub root: DirNode,
    pub total_scanned: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScanError {
    pub message: String,
}

pub struct Scanner {
    app: AppHandle,
    cancelled: Arc<AtomicBool>,
    total_scanned: Arc<AtomicU64>,
    inode_tracker: Arc<DashMap<(u64, u64), PathBuf>>,
}

impl Scanner {
    pub fn new(app: AppHandle) -> Self {
        Self {
            app,
            cancelled: Arc::new(AtomicBool::new(false)),
            total_scanned: Arc::new(AtomicU64::new(0)),
            inode_tracker: Arc::new(DashMap::new()),
        }
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn scan_directory(&self, path: String) -> Result<(), String> {
        let path_buf = PathBuf::from(&path);

        if !path_buf.exists() {
            return Err("Path does not exist".to_string());
        }

        if !path_buf.is_dir() {
            return Err("Path is not a directory".to_string());
        }

        // Reset state
        self.cancelled.store(false, Ordering::SeqCst);
        self.total_scanned.store(0, Ordering::SeqCst);
        self.inode_tracker.clear();

        // Start scan
        match self.scan_recursive(&path_buf) {
            Ok(root) => {
                let total = self.total_scanned.load(Ordering::SeqCst);
                let _ = self.app.emit(
                    "scan:complete",
                    ScanComplete {
                        root,
                        total_scanned: total,
                    },
                );
                Ok(())
            }
            Err(e) => {
                let _ = self
                    .app
                    .emit("scan:error", ScanError { message: e.clone() });
                Err(e)
            }
        }
    }

    fn scan_recursive(&self, path: &Path) -> Result<DirNode, String> {
        if self.cancelled.load(Ordering::SeqCst) {
            return Err("Scan cancelled".to_string());
        }

        let metadata = match fs::metadata(path) {
            Ok(m) => m,
            Err(_) => {
                // Skip on permission errors
                return Ok(DirNode {
                    name: path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("unknown")
                        .to_string(),
                    path: path.to_string_lossy().to_string(),
                    size: 0,
                    children: vec![],
                    is_file: false,
                });
            }
        };

        // Handle files (including symlinks as files)
        if !metadata.is_dir() {
            let size = self.get_file_size(path, &metadata);
            self.total_scanned.fetch_add(1, Ordering::SeqCst);

            return Ok(DirNode {
                name: path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("unknown")
                    .to_string(),
                path: path.to_string_lossy().to_string(),
                size,
                children: vec![],
                is_file: true,
            });
        }

        // Read directory entries
        let entries: Vec<PathBuf> = match fs::read_dir(path) {
            Ok(entries) => entries.filter_map(|e| e.ok().map(|e| e.path())).collect(),
            Err(_) => {
                // Skip on permission errors
                return Ok(DirNode {
                    name: path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("unknown")
                        .to_string(),
                    path: path.to_string_lossy().to_string(),
                    size: 0,
                    children: vec![],
                    is_file: false,
                });
            }
        };

        // Scan children in parallel
        let children: Vec<DirNode> = entries
            .par_iter()
            .filter_map(|entry| {
                if self.cancelled.load(Ordering::SeqCst) {
                    return None;
                }
                self.scan_recursive(entry).ok()
            })
            .collect();

        // Calculate total size
        let total_size: u64 = children.iter().map(|c| c.size).sum();

        let node = DirNode {
            name: path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("unknown")
                .to_string(),
            path: path.to_string_lossy().to_string(),
            size: total_size,
            children,
            is_file: false,
        };

        // Emit directory complete event
        let total = self.total_scanned.load(Ordering::SeqCst);
        let _ = self.app.emit(
            "scan:directory_complete",
            ScanProgress {
                path: path.to_string_lossy().to_string(),
                node_data: node.clone(),
                total_scanned: total,
            },
        );

        Ok(node)
    }

    #[cfg(unix)]
    fn get_file_size(&self, path: &Path, metadata: &fs::Metadata) -> u64 {
        use std::os::unix::fs::MetadataExt;

        let dev = metadata.dev();
        let ino = metadata.ino();
        let nlink = metadata.nlink();

        // Handle hard links - count only once
        if nlink > 1 {
            let key = (dev, ino);

            if self.inode_tracker.contains_key(&key) {
                return 0; // Already counted this inode at a different path
            }

            self.inode_tracker.insert(key, path.to_path_buf());
            return metadata.len();
        }

        metadata.len()
    }

    #[cfg(not(unix))]
    fn get_file_size(&self, _path: &Path, metadata: &fs::Metadata) -> u64 {
        metadata.len()
    }
}
