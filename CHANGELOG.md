# Changelog

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

