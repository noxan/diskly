# Diskly

A fast, native macOS disk usage visualizer.

Pick a folder and Diskly draws a squarified treemap of what's eating your space,
with a sortable size breakdown alongside it. Mark the junk, review it, send it to
the Trash in one pass.

## Features

- **Treemap** — every file sized by disk usage, colored by type; click to select,
  double-click or the chevron to drill in, breadcrumb to navigate back.
- **Size breakdown** — sidebar list of the current folder's contents, largest first.
- **Mark & clean** — stage items for deletion (shown in red), review the total, then
  Move to Trash together.
- **Fast scans** — directories scanned in parallel across cores, with a live item
  count and Cancel.

## Build & run

Open `Diskly.xcodeproj` in Xcode and run (⌘R), or:

```sh
xcodebuild -project Diskly.xcodeproj -scheme Diskly -configuration Debug build
```

Requires macOS 26+ and Xcode 26+. The app is sandboxed and only accesses folders
you explicitly choose.
