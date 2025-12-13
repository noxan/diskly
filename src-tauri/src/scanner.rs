use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::SystemTime,
};

use dashmap::DashSet;
use rayon::prelude::*;
use rayon::ThreadPool;
use tauri::{AppHandle, Emitter};

use crate::events::{DirectoryCompletePayload, FsNode, ScanCompletePayload, ScanErrorPayload};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct FileId {
    dev: u64,
    ino: u64,
}

#[cfg(unix)]
fn file_id(meta: &fs::Metadata) -> Option<FileId> {
    use std::os::unix::fs::MetadataExt;
    Some(FileId {
        dev: meta.dev(),
        ino: meta.ino(),
    })
}

#[cfg(windows)]
fn file_id(meta: &fs::Metadata) -> Option<FileId> {
    use std::os::windows::fs::MetadataExt;
    Some(FileId {
        dev: meta.volume_serial_number().unwrap_or(0) as u64,
        ino: ((meta.file_index_high() as u64) << 32) | (meta.file_index_low() as u64),
    })
}

#[cfg(not(any(unix, windows)))]
fn file_id(_meta: &fs::Metadata) -> Option<FileId> {
    None
}

fn emit_error(app: &AppHandle, message: impl Into<String>) {
    let _ = app.emit("scan:error", ScanErrorPayload { message: message.into() });
}

fn is_symlink(meta: &fs::Metadata) -> bool {
    meta.file_type().is_symlink()
}

fn node_name(path: &Path) -> String {
    path.file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| path.display().to_string())
}

fn scan_file_size_once(
    meta: &fs::Metadata,
    seen: &DashSet<FileId>,
) -> u64 {
    // Best effort: only de-dupe if we can identify the file.
    if let Some(id) = file_id(meta) {
        if seen.insert(id) {
            meta.len()
        } else {
            0
        }
    } else {
        meta.len()
    }
}

fn scan_dir(
    app: &AppHandle,
    pool: &ThreadPool,
    path: &Path,
    seen: &DashSet<FileId>,
    cancel: &AtomicBool,
    total_scanned: &AtomicU64,
) -> FsNode {
    if cancel.load(Ordering::Relaxed) {
        return FsNode {
            name: node_name(path),
            path: path.display().to_string(),
            size: 0,
            children: Vec::new(),
        };
    }

    let mut children: Vec<FsNode> = Vec::new();
    let mut child_dirs: Vec<PathBuf> = Vec::new();

    let read_dir = match fs::read_dir(path) {
        Ok(rd) => rd,
        Err(e) => {
            emit_error(app, format!("Failed to read dir '{}': {}", path.display(), e));
            return FsNode {
                name: node_name(path),
                path: path.display().to_string(),
                size: 0,
                children: Vec::new(),
            };
        }
    };

    for entry in read_dir {
        if cancel.load(Ordering::Relaxed) {
            break;
        }

        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                emit_error(app, format!("Dir entry error in '{}': {}", path.display(), e));
                continue;
            }
        };

        total_scanned.fetch_add(1, Ordering::Relaxed);
        let child_path = entry.path();

        let meta = match fs::symlink_metadata(&child_path) {
            Ok(m) => m,
            Err(e) => {
                emit_error(
                    app,
                    format!("Failed to stat '{}': {}", child_path.display(), e),
                );
                continue;
            }
        };

        if is_symlink(&meta) {
            // Treat symlink as a file (do not follow).
            children.push(FsNode {
                name: node_name(&child_path),
                path: child_path.display().to_string(),
                size: meta.len(),
                children: Vec::new(),
            });
            continue;
        }

        if meta.is_dir() {
            child_dirs.push(child_path);
            continue;
        }

        // File (or other non-dir). Count hard links once when possible.
        let size = scan_file_size_once(&meta, seen);
        children.push(FsNode {
            name: node_name(&child_path),
            path: child_path.display().to_string(),
            size,
            children: Vec::new(),
        });
    }

    // Scan subdirectories in parallel, then append results.
    let mut dir_nodes: Vec<FsNode> = pool.install(|| {
        child_dirs
            .par_iter()
            .map(|p| scan_dir(app, pool, p, seen, cancel, total_scanned))
            .collect()
    });

    children.append(&mut dir_nodes);

    // Sort by size (desc), stable tie-break by name.
    children.sort_by(|a, b| b.size.cmp(&a.size).then_with(|| a.name.cmp(&b.name)));

    let size = children.iter().map(|c| c.size).sum();
    let node = FsNode {
        name: node_name(path),
        path: path.display().to_string(),
        size,
        children,
    };

    let payload = DirectoryCompletePayload {
        path: node.path.clone(),
        node_data: node.clone(),
        total_scanned: total_scanned.load(Ordering::Relaxed),
    };
    let _ = app.emit("scan:directory_complete", payload);

    node
}

pub fn dir_mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).ok().and_then(|m| m.modified().ok())
}

pub fn scan_tree_streaming(
    app: AppHandle,
    root: PathBuf,
    pool: ThreadPool,
    cancel: Arc<AtomicBool>,
) -> Option<(FsNode, u64)> {
    let total_scanned = AtomicU64::new(0);
    let seen = DashSet::<FileId>::new();

    let root_node = scan_dir(&app, &pool, &root, &seen, &cancel, &total_scanned);

    if cancel.load(Ordering::Relaxed) {
        emit_error(&app, "Scan cancelled");
        return None;
    }

    let payload = ScanCompletePayload {
        root: root_node.clone(),
        total_scanned: total_scanned.load(Ordering::Relaxed),
    };
    let _ = app.emit("scan:complete", payload);
    Some((root_node, total_scanned.load(Ordering::Relaxed)))
}

