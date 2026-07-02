# Diskly

A fast, native macOS disk usage visualizer.

Pick a folder and Diskly draws a squarified treemap of what's eating your space,
with a sortable size breakdown alongside it. Mark the junk, review it, send it to
the Trash in one pass.

<p>
  <a href="https://github.com/noxan/diskly/releases/latest">
    <img src="https://img.shields.io/badge/⬇%20Download%20Diskly-000000?style=for-the-badge&logo=apple" alt="Download Diskly">
  </a>
</p>

## Screenshots

<table>
  <tr>
    <td><img src="assets/screenshot-home.png" alt="Home" width="480"></td>
    <td><img src="assets/screenshot-scan.png" alt="Scan" width="480"></td>
    <td><img src="assets/screenshot-delete.png" alt="Delete" width="480"></td>
  </tr>
  <tr>
    <td align="center"><sub>Home</sub></td>
    <td align="center"><sub>Scan</sub></td>
    <td align="center"><sub>Delete</sub></td>
  </tr>
</table>

## Performance

Diskly scans in parallel across cores, reads directory entries in bulk via
`getattrlistbulk(2)` — one syscall per batch instead of one `stat` per file —
and walks the tree with `openat(2)` relative to each parent directory, so the
kernel resolves one path component per directory instead of the whole path.
Scans also never trigger iCloud downloads (dataless files are measured, not
materialized).

On a 2024 MacBook Pro (M4, 11 cores) it walks `~/Library` (≈849k items,
≈104 GB) **2–3× faster** than `du`, `ncdu`, and `find + stat` in a
back-to-back comparison, and repeat scans complete in as little as ~4s:

| tool             | time    | items     | MB/s   | vs Diskly |
| ---------------- | ------- | --------- | ------ | --------- |
| **Diskly**       | 12.3s   | 849,067   | 8,445  | 1.00×     |
| `du -sk`         | 25.4s   | —         | 4,057  | 2.06×     |
| `ncdu -1 -o -`   | 30.4s   | —         | 3,415  | 2.47×     |
| `find + stat`    | 39.0s   | 849,067   | 2,664  | 3.17×     |

Reproduce on your own machine:

```sh
make bench                          # cross-tool comparison (default: ~/Library)
make bench BENCH_PATH=~/Developer   # any folder
./bench/bench --quick ~/Library     # Diskly only, best of 3
```

A warm-up scan fills the page cache first, so every tool benefits equally
from kernel caching. Numbers will vary with disk, file-tree shape, core
count, and background load — the relative speedup holds. The optimization
history lives in [bench/PERF_LOG.md](bench/PERF_LOG.md).

## Install

1. **Download** the latest build from [GitHub releases][releases].
2. **Unzip** it and **drag Diskly to Applications**.

Recent releases are signed and notarized, so macOS won't block them. If you hit an
older unsigned build that shows "Apple could not verify it is free of malware":
right-click Diskly in Applications → **Open** → **Open** in the prompt, or go to
**System Settings → Privacy & Security** and click **Open Anyway**.

[releases]: https://github.com/noxan/diskly/releases/latest

## Features

- **Treemap** — every file sized by disk usage, colored by type; click to select,
  double-click or the chevron to drill in, breadcrumb to navigate back.
- **Size breakdown** — sidebar list of the current folder's contents, largest first.
- **Mark & clean** — stage items for deletion (shown in red), review the total, then
  Move to Trash together.
- **Fast scans** — directories scanned in parallel across cores, with a live item
  count and Cancel.
- **Automatic updates** — checks for new versions in the background and offers to
  install on quit (via [Sparkle](https://sparkle-project.org)). A "Check for
  Updates…" item lives in the app menu.

## Build & run

```sh
make open      # build and launch
make share     # build a zip to share with others
make dist      # signed + notarized release (needs config.mk)
```

Requires macOS 26+ and Xcode 26+. The app is sandboxed and only accesses folders
you explicitly choose.
