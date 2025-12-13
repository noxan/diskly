use crate::scanner::DirNode;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::time::SystemTime;

const MAX_CACHE_SIZE: usize = 3;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CacheEntry {
    data: DirNode,
    timestamp: SystemTime,
    total_scanned: u64,
}

pub struct LruCache {
    entries: HashMap<String, CacheEntry>,
    access_order: Vec<String>,
}

impl LruCache {
    pub fn new() -> Self {
        Self {
            entries: HashMap::new(),
            access_order: Vec::new(),
        }
    }

    pub fn get(&mut self, path: &str) -> Option<(DirNode, u64)> {
        if !self.entries.contains_key(path) {
            return None;
        }

        // Validate cache entry is still valid
        if !self.is_valid(path) {
            self.invalidate(path);
            return None;
        }

        // Update access order
        if let Some(pos) = self.access_order.iter().position(|p| p == path) {
            self.access_order.remove(pos);
        }
        self.access_order.push(path.to_string());

        // Return cached data
        self.entries
            .get(path)
            .map(|entry| (entry.data.clone(), entry.total_scanned))
    }

    pub fn put(&mut self, path: String, data: DirNode, total_scanned: u64) {
        // Evict least recently used if at capacity
        if self.entries.len() >= MAX_CACHE_SIZE && !self.entries.contains_key(&path) {
            if let Some(lru_path) = self.access_order.first().cloned() {
                self.entries.remove(&lru_path);
                self.access_order.remove(0);
            }
        }

        // Update or insert entry
        let entry = CacheEntry {
            data,
            timestamp: SystemTime::now(),
            total_scanned,
        };

        self.entries.insert(path.clone(), entry);

        // Update access order
        if let Some(pos) = self.access_order.iter().position(|p| p == &path) {
            self.access_order.remove(pos);
        }
        self.access_order.push(path);
    }

    pub fn invalidate(&mut self, path: &str) {
        self.entries.remove(path);
        if let Some(pos) = self.access_order.iter().position(|p| p == path) {
            self.access_order.remove(pos);
        }
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.access_order.clear();
    }

    fn is_valid(&self, path: &str) -> bool {
        let Some(entry) = self.entries.get(path) else {
            return false;
        };

        // Check if path still exists
        let path_obj = Path::new(path);
        if !path_obj.exists() {
            return false;
        }

        // Check if directory has been modified
        if let Ok(metadata) = fs::metadata(path_obj) {
            if let Ok(modified) = metadata.modified() {
                if modified > entry.timestamp {
                    return false;
                }
            }
        }

        true
    }
}

impl Default for LruCache {
    fn default() -> Self {
        Self::new()
    }
}
