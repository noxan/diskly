# Changelog

## v0.9.0 — 2026-09-01

### Added
- Per-folder rescan: right-click a folder to rescan just that subtree
- Ejected disks automatically removed from the welcome screen

### Changed
- Optimized disk scanning performance, especially for Nix packages

### Fixed
- Scanner task stalls and slow full-disk scans
- Volume usage accounting to match macOS behavior


## v0.8.0 — 2026-08-07

### Added
- display lifetime reclaimed space history with per-origin breakdown and 30/90/365-day charts


## v0.7.2 — 2026-08-06

### Added
- add safe browser caches


## v0.7.1 — 2026-08-06

### Added
- add cleanup feedback link
- add more package and build caches


## v0.7.0 — 2026-08-06

### Added
- split cleanup into safe and prune modes
- add common app cache targets

### Changed
- move prune mode into advanced menu


## v0.6.0 — 2026-08-06

### Added
- Bun, Docker, Homebrew, and common developer cache cleanup targets
- cache size preview for cleanup operations
- cleanup target grouping and full cleanup option

### Changed
- redesigned cleanup interface with full-screen view, scrollable targets, and improved navigation
- multi-directory cache target support

### Fixed
- cleanup scan oversubscription and performance
- error display for cleanup operations
- locate tools and caches in non-standard installation paths
- improve cache cleanup in Trash and sandbox environments


## v0.5.0 — 2026-07-02

### Changed
- scanning is ~3-4x faster with optimized directory traversal and concurrent operations

### Fixed
- distribution archive output path in release builds
- version bumping now uses full semantic versions (X.Y.Z)


## v0.4.1 — 2026-07-01

### Added
- add automatic background update checking with a "Check for Updates…" menu item

