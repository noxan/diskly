# Diskly - Disk Space Analyzer

A fast, cross-platform disk space visualization app built with Tauri + Svelte.

## Features

- **Fast Parallel Scanning**: Multi-threaded directory traversal using Rayon (80% CPU cores)
- **Event-Driven Updates**: Progressive UI updates as directories complete scanning
- **Smart File Handling**: 
  - Handles permission errors gracefully
  - Counts hard links only once
  - Treats symlinks as files
- **Tree Visualization**: Interactive collapsible tree view sorted by size
- **LRU Cache**: Intelligent caching of last 3 scans with automatic invalidation
- **Clean UI**: Minimal, macOS-inspired design with Tailwind CSS

## Tech Stack

- **Backend**: Rust + Tauri (async with tokio, parallel scanning with rayon)
- **Frontend**: Svelte 5 + Tailwind CSS
- **Build**: Vite

## Prerequisites

### System Dependencies (Linux)

```bash
sudo apt-get update
sudo apt-get install -y \
  libgtk-3-dev \
  libwebkit2gtk-4.1-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev \
  libglib2.0-dev
```

### Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Node.js & npm

Version 18+ recommended.

## Development

Install dependencies:

```bash
npm install
```

Run in development mode:

```bash
npm run tauri dev
```

## Build

Production build:

```bash
npm run tauri build
```

The built app will be in `src-tauri/target/release/bundle/`.

## Usage

1. Launch the app
2. Click "Scan Home Folder" or "Choose Directory"
3. Watch real-time progress as directories are scanned
4. Click folders in the tree to expand/collapse
5. Click "New Scan" to analyze another directory

## Architecture

### Backend (Rust)

- `scanner.rs`: Async/parallel directory traversal with event emission
- `cache.rs`: LRU cache (3 entries) with mtime-based invalidation
- `lib.rs`: Tauri commands and event setup

### Frontend (Svelte)

- `stores/scan.js`: Reactive store managing scan state and event listeners
- `components/Scanner.svelte`: Home screen with scan controls
- `components/Progress.svelte`: Live progress indicator
- `components/TreeView.svelte`: Main tree display with stats
- `components/TreeNode.svelte`: Recursive tree node component

### Event Flow

1. Frontend calls `scan_directory(path)` command
2. Rust spawns async task, begins parallel scan
3. Rust emits `scan:directory_complete` events as each directory finishes
4. Frontend Svelte store listens and updates tree progressively
5. On completion, `scan:complete` event finalizes state
6. Result cached in Rust for instant re-access

## Performance Notes

- Uses 80% of available CPU cores for scanning
- Never blocks the main thread
- Handles directories with 100k+ files smoothly
- Virtual scrolling for large trees (via CSS overflow)
- Progressive rendering as data arrives

## License

MIT
