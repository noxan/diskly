use lru::LruCache;
use std::num::NonZeroUsize;
use std::path::Path;
use std::sync::Mutex;
use std::time::SystemTime;
use crate::scanner::DirNode;

pub struct ScanCache {
    cache: Mutex<LruCache<String, CacheEntry>>,
}

struct CacheEntry {
    node: DirNode,
    mtime: SystemTime,
}

impl ScanCache {
    pub fn new() -> Self {
        Self {
            cache: Mutex::new(LruCache::new(NonZeroUsize::new(3).unwrap())),
        }
    }

    pub fn get(&self, path: &str) -> Option<DirNode> {
        let path_obj = Path::new(path);
        
        // Get current mtime
        let current_mtime = std::fs::metadata(path_obj)
            .and_then(|m| m.modified())
            .ok()?;

        let mut cache = self.cache.lock().unwrap();
        
        if let Some(entry) = cache.get(path) {
            // Check if mtime matches
            if entry.mtime == current_mtime {
                return Some(entry.node.clone());
            } else {
                // Invalidate if modified
                cache.pop(path);
            }
        }

        None
    }

    #[allow(dead_code)]
    pub fn put(&self, path: String, node: DirNode) {
        let path_obj = Path::new(&path);
        
        // Get mtime
        if let Ok(metadata) = std::fs::metadata(path_obj) {
            if let Ok(mtime) = metadata.modified() {
                let entry = CacheEntry { node, mtime };
                let mut cache = self.cache.lock().unwrap();
                cache.put(path, entry);
            }
        }
    }
}
