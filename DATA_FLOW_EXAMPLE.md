# Data Flow Example

## Scenario: User scans `/home/user/projects` with 3 levels

### Directory Structure
```
/home/user/projects/
├── app/
│   ├── main.rs (10 MB)
│   └── lib.rs (2 MB)
├── docs/
│   └── README.md (1 KB)
└── config.toml (500 B)
```

---

## Phase 1: Scanning

### User Action
```typescript
scanStore.startScan("/home/user/projects");
```

### Backend Processing

**scan_folder()** walks the tree and builds HashMap:

```rust
HashMap {
  "/home/user/projects" => [
    FileNode { path: "/home/user/projects/app", name: "app", size: 12MB, is_dir: true, child_count: 2 },
    FileNode { path: "/home/user/projects/docs", name: "docs", size: 1KB, is_dir: true, child_count: 1 },
    FileNode { path: "/home/user/projects/config.toml", name: "config.toml", size: 500B, is_dir: false, child_count: 0 }
  ],
  "/home/user/projects/app" => [
    FileNode { path: "/home/user/projects/app/main.rs", name: "main.rs", size: 10MB, is_dir: false, child_count: 0 },
    FileNode { path: "/home/user/projects/app/lib.rs", name: "lib.rs", size: 2MB, is_dir: false, child_count: 0 }
  ],
  "/home/user/projects/docs" => [
    FileNode { path: "/home/user/projects/docs/README.md", name: "README.md", size: 1KB, is_dir: false, child_count: 0 }
  ]
}
```

**Emits**: 
```typescript
{
  event: "scan:complete",
  payload: {
    root_path: "/home/user/projects",
    total_scanned: 6,
    total_size: 12000500  // 12MB + 1KB + 500B
  }
}
```

---

## Phase 2: Initial Display

### Frontend Action
```typescript
// TreeView component effect triggers
rootChildren = await getChildren("/home/user/projects");
```

### Backend Response
```typescript
// get_children("/home/user/projects") returns:
[
  { path: "/home/user/projects/app", name: "app", size: 12582912, is_dir: true, child_count: 2 },
  { path: "/home/user/projects/docs", name: "docs", size: 1024, is_dir: true, child_count: 1 },
  { path: "/home/user/projects/config.toml", name: "config.toml", size: 500, is_dir: false, child_count: 0 }
]
```

### UI Renders
```
/home/user/projects (12 MB, 6 items)

▶ 📁 app (2)                    12 MB  ████████████████
▶ 📁 docs (1)                    1 KB  |
  📄 config.toml                500 B  |
```

---

## Phase 3: User Expands "app" Folder

### User Action
Clicks on "app" folder

### Frontend Code
```typescript
// TreeNode.toggleExpand() called
if (!node.children) {
  node.children = await getChildren("/home/user/projects/app");
}
expanded = true;
```

### Backend Response
```typescript
// get_children("/home/user/projects/app") returns:
[
  { path: "/home/user/projects/app/main.rs", name: "main.rs", size: 10485760, is_dir: false, child_count: 0 },
  { path: "/home/user/projects/app/lib.rs", name: "lib.rs", size: 2097152, is_dir: false, child_count: 0 }
]
```

### UI Updates
```
/home/user/projects (12 MB, 6 items)

▼ 📁 app (2)                    12 MB  ████████████████
  |
  ├─ 📄 main.rs                 10 MB  █████████████
  └─ 📄 lib.rs                   2 MB  ███

▶ 📁 docs (1)                    1 KB  |
  📄 config.toml                500 B  |
```

---

## Phase 4: User Collapses "app" Folder

### User Action
Clicks on "app" folder again

### Frontend Code
```typescript
// TreeNode.toggleExpand() called
// node.children already exists (cached)
expanded = false;
```

### Backend Response
None! Children are cached in frontend

### UI Updates
```
/home/user/projects (12 MB, 6 items)

▶ 📁 app (2)                    12 MB  ████████████████
▶ 📁 docs (1)                    1 KB  |
  📄 config.toml                500 B  |
```

---

## Network/IPC Traffic Comparison

### Old Approach (Sending Full Tree)
**1 large payload on scan complete:**
```typescript
{
  event: "scan:complete",
  payload: {
    root: {
      path: "/home/user/projects",
      children: [
        {
          path: "/home/user/projects/app",
          children: [
            { path: "/home/user/projects/app/main.rs", ... },
            { path: "/home/user/projects/app/lib.rs", ... }
          ]
        },
        {
          path: "/home/user/projects/docs",
          children: [
            { path: "/home/user/projects/docs/README.md", ... }
          ]
        },
        { path: "/home/user/projects/config.toml", ... }
      ]
    }
  }
}
```
**Problem**: For 70k files, this could be 50-100+ MB of JSON

### New Approach (Lazy Loading)
**Multiple small payloads:**

1. Scan complete: ~100 bytes
2. Get root children: ~300 bytes (3 items)
3. Get /app children: ~200 bytes (2 items)
4. Get /docs children: ~100 bytes (1 item)

**Total**: ~700 bytes (vs 50+ MB)
**Benefit**: Only fetches what user views

---

## Performance Characteristics

### Memory Usage (Frontend)
- **Old**: O(n) where n = total files (always all files in memory)
- **New**: O(v) where v = visible nodes (typically < 100)

### Initial Display Time
- **Old**: 5-30 seconds for large trees (parsing huge JSON)
- **New**: < 100ms (just root level)

### Expansion Time
- **Old**: Instant (already in memory) but UI frozen during initial load
- **New**: ~50-100ms per folder (network + render)

### Scalability
- **Old**: Breaks at ~50k files (JSON parsing limit)
- **New**: Works with millions of files (HashMap lookup is O(1))
