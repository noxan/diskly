use std::{path::Path, sync::{Mutex, MutexGuard}, time::SystemTime};

use lru::LruCache;

use crate::events::FsNode;

#[derive(Debug, Clone)]
pub struct CachedScan {
    pub root: FsNode,
    pub total_scanned: u64,
}

#[derive(Debug)]
pub struct ScanCache {
    inner: Mutex<LruCache<String, CachedScan>>,
}

impl ScanCache {
    pub fn new() -> Self {
        // last 3 scans
        Self {
            inner: Mutex::new(LruCache::new(std::num::NonZeroUsize::new(3).unwrap())),
        }
    }

    fn lock(&self) -> MutexGuard<'_, LruCache<String, CachedScan>> {
        self.inner.lock().expect("scan cache mutex poisoned")
    }

    pub fn key(path: &Path, dir_mtime: SystemTime) -> String {
        // SystemTime isn't stable printable across platforms; we only need it to vary on change.
        // Use duration since UNIX_EPOCH, clamped to 0 on error.
        let ts = dir_mtime
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        format!("{}|{}", path.display(), ts)
    }

    pub fn get(&self, key: &str) -> Option<CachedScan> {
        self.lock().get(key).cloned()
    }

    pub fn put(&self, key: String, value: CachedScan) {
        self.lock().put(key, value);
    }
}

