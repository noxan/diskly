//
//  Model.swift
//  Diskly
//
//  Disk scanning model + app state.
//

import Foundation
import AppKit
import Synchronization

// MARK: - Display name

/// Resolve a human-friendly name for `url`. For a volume root (the boot
/// volume "/", or any mounted volume under /Volumes), return the volume's
/// localized name (e.g. "Macintosh HD") instead of the literal path.
func displayName(for url: URL) -> String {
    // Volume roots: "/" (boot) and "/Volumes/<name>" (mounted). For these,
    // lastPathComponent is "/" or the volume name but we want the volume's
    // own localized label, not the bare path component.
    let keys: Set<URLResourceKey> = [.isVolumeKey, .volumeLocalizedNameKey]
    if let v = try? url.resourceValues(forKeys: keys),
       v.isVolume == true,
       let name = v.volumeLocalizedName, !name.isEmpty {
        return name
    }
    let leaf = url.lastPathComponent
    return leaf.isEmpty ? "/" : leaf
}

// MARK: - File tree

/// A node in the scanned file tree. Plain class (not observed) — the tree is
/// large; the UI observes `AppModel` and reads `AppModel.version` to refresh.
nonisolated final class FileNode: Identifiable, Equatable, @unchecked Sendable {
    let name: String
    let isDirectory: Bool
    var size: Int64
    var children: [FileNode]
    unowned let parent: FileNode?
    /// Set only on parentless roots and the synthetic aggregate node. Every
    /// other node derives its URL from the parent chain on demand — eagerly
    /// building and storing a URL per node cost ~1.5s CPU per 850k nodes
    /// (measured; 16× the cost of string concat) plus a URL object per node.
    private let fixedURL: URL?

    var url: URL { fixedURL ?? parent!.url.appendingPathComponent(name) }

    // Set on the synthetic "Other" node that merges the small-item tail.
    var isAggregate = false
    var aggregatedCount = 0

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }

    init(name: String, isDirectory: Bool, size: Int64 = 0,
         children: [FileNode] = [], parent: FileNode?, fixedURL: URL? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
        self.parent = parent
        self.fixedURL = fixedURL
    }

    private var _sorted: [FileNode]?
    private var _display: [FileNode]?

    /// Children worth showing, largest first. Cached; call `invalidate()` after
    /// mutating `children`.
    var sortedChildren: [FileNode] {
        if let s = _sorted { return s }
        let s = children.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        _sorted = s
        return s
    }

    /// Display children: big items individually, the small tail merged into one
    /// "Other" node. Drives the treemap and the list identically. Cached.
    ///
    /// "Small" is dynamic: under 1% of this folder's size. Only kicks in for
    /// busy folders (>12 children) and when it actually merges ≥2 items.
    var displayChildren: [FileNode] {
        if let d = _display { return d }
        let kids = sortedChildren
        let result: [FileNode]
        // Don't re-group inside an already-aggregated node — that would nest
        // "Other" inside "Other" forever; show its items in full instead.
        if !isAggregate, kids.count > 12, size > 0 {
            let threshold = Int64(Double(size) * 0.01)
            let bigCount = kids.prefix { $0.size >= threshold }.count
            let small = kids[bigCount...]
            if small.count >= 2 {
                let other = FileNode.aggregate(of: Array(small), parent: self)
                result = Array(kids[..<bigCount]) + [other]
            } else {
                result = kids
            }
        } else {
            result = kids
        }
        _display = result
        return result
    }

    func invalidate() { _sorted = nil; _display = nil }

    /// The synthetic node standing in for the merged small-item tail. It carries
    /// the real children, so it opens like any other folder.
    static func aggregate(of children: [FileNode], parent: FileNode) -> FileNode {
        let total = children.reduce(Int64(0)) { $0 + $1.size }
        let n = FileNode(name: "Other", isDirectory: true,
                         size: total, children: children, parent: parent,
                         fixedURL: parent.url.appendingPathComponent(".__diskly_other__"))
        n.isAggregate = true
        n.aggregatedCount = children.count
        return n
    }
}

// MARK: - Scan progress + node buffer

/// Live item counter shared with the running scan. Locked per directory (not
/// per file) so counting adds no measurable cost to the hot path.
nonisolated final class ScanProgress: @unchecked Sendable {
    private struct State { var count = 0; var bytes: Int64 = 0 }
    private let state = Mutex(State())
    func add(_ n: Int, bytes: Int64 = 0) {
        state.withLock { $0.count += n; $0.bytes += bytes }
    }
    var count: Int { state.withLock { $0.count } }
    var bytes: Int64 { state.withLock { $0.bytes } }
}

/// Holds fully-built top-level subtrees emitted by a streaming scan until the
/// main actor drains them into the live tree. Each node is finished (immutable)
/// before it lands here, so the published tree never races the scanner.
nonisolated final class NodeBuffer: @unchecked Sendable {
    private let items = Mutex([FileNode]())
    func append(_ n: FileNode) { items.withLock { $0.append(n) } }
    func drain() -> [FileNode] {
        items.withLock { buf in
            let out = buf
            buf.removeAll()
            return out
        }
    }
}

// MARK: - Scanner tree builder
//
// `Scanner` itself, plus `ScanGate`, `DirRegistry`, and the bulk-read primitive
// `entries(of:)`, live in Scanner.swift so the benchmark can compile those
// against bench.swift without pulling in `FileNode` or any AppKit. The
// tree-builder below binds those primitives to the live UI tree via `FileNode`,
// so it stays here with the rest of the app state.

extension Scanner {

    /// Scan `root`'s contents, emitting each top-level child to `onChild` the
    /// moment its whole subtree is built — so the UI can fill in progressively.
    /// `parent` is the live root node the children attach to; the scanner only
    /// ever hands back finished, immutable subtrees, so it never touches the
    /// published tree (the caller appends them on the main actor).
    /// ponytail: one task per top-level entry — fine for normal roots; a root
    /// with tens of thousands of loose top-level files would over-spawn.
    // @concurrent: the target builds with default-MainActor isolation +
    // approachable concurrency, under which these async funcs (and every
    // task-group child they spawn) otherwise run ON THE MAIN THREAD — a
    // profiler showed 85% of main-thread time inside the scan, serializing
    // it and freezing the UI. @concurrent pins them to the global executor.
    @concurrent
    static func scanStreaming(_ root: URL, parent: FileNode, progress: ScanProgress,
                              onChild: @escaping @Sendable (FileNode) -> Void) async {
        let gate = ScanGate(limit: ProcessInfo.processInfo.activeProcessorCount)
        let registry = DirRegistry()        // kills firmlink / bind-mount double counts
        let rootPath = root.path
        let rootFD = openDir(rootPath)
        guard rootFD >= 0 else { return }
        defer { close(rootFD) }             // group is awaited below, so fd outlives all openats
        let contents = entries(fd: rootFD)
        progress.add(contents.count, bytes: contents.reduce(Int64(0)) { $0 + $1.size })
        await withTaskGroup(of: Void.self) { group in
            for e in contents {
                group.addTask {
                    if Task.isCancelled { return }
                    let child = FileNode(name: e.name, isDirectory: e.isDir, parent: parent)
                    if e.isDir && !e.isLink {
                        await build(child, parentFD: rootFD, name: e.name,
                                    path: rootPath + "/" + e.name,
                                    gate: gate, progress: progress, registry: registry)
                    } else {
                        child.size = e.size
                    }
                    if Task.isCancelled { return }
                    onChild(child)
                }
            }
        }
    }

    /// Populate a directory node: plain files inline; subdirectories in parallel
    /// while gate slots are free, otherwise recursed inline. The directory is
    /// opened via openat(2) relative to the parent's fd (single-component path
    /// resolution — full-path open() was the measured scan bottleneck); the fd
    /// stays open until the subtree finishes so children can do the same.
    @concurrent
    private static func build(_ node: FileNode, parentFD: Int32, name: String,
                              path: String,
                              gate: ScanGate, progress: ScanProgress,
                              registry: DirRegistry) async {
        if Task.isCancelled { return }       // bail fast when the scan is cancelled
        let fd = openDir(at: parentFD, name)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // Skip a physical directory we've already walked. Firmlinks expose the
        // same inode via multiple paths (e.g. /Users and /System/Volumes/Data/Users);
        // recursing into both double-counts every byte on the Data volume. The
        // node stays in the tree (path visible) but its subtree is not walked,
        // so its size stays 0. `path` is threaded down as a plain string —
        // deriving it from node.url would rebuild the URL chain per directory.
        guard registry.shouldWalk(path: path, fd: fd) else { return }
        let contents = entries(fd: fd)
        progress.add(contents.count, bytes: contents.reduce(Int64(0)) { $0 + $1.size })

        var kids: [FileNode] = []
        kids.reserveCapacity(contents.count)

        // Files inline; collect subdirs first so leaf dirs (most dirs) and
        // single-subdir chains never pay for task-group setup. Symlinks are
        // never followed — avoids loops and double-counting.
        var dirs: [DirEntry] = []
        for e in contents {
            if e.isDir && !e.isLink {
                dirs.append(e)
            } else {
                let child = FileNode(name: e.name, isDirectory: e.isDir, parent: node)
                child.size = e.size
                kids.append(child)
            }
        }
        if dirs.count == 1 {
            // One subdir: nothing to run in parallel with — recurse inline.
            let e = dirs[0]
            let child = FileNode(name: e.name, isDirectory: true, parent: node)
            await build(child, parentFD: fd, name: e.name, path: path + "/" + e.name,
                        gate: gate, progress: progress, registry: registry)
            kids.append(child)
        } else if dirs.count > 1 {
            await withTaskGroup(of: FileNode.self) { group in
                for e in dirs {
                    let child = FileNode(name: e.name, isDirectory: true, parent: node)
                    let childPath = path + "/" + e.name
                    if gate.tryAcquire() {
                        group.addTask {
                            await build(child, parentFD: fd, name: e.name, path: childPath,
                                        gate: gate, progress: progress, registry: registry)
                            gate.release()
                            return child
                        }
                    } else {
                        await build(child, parentFD: fd, name: e.name, path: childPath,
                                    gate: gate, progress: progress, registry: registry)
                        kids.append(child)
                    }
                }
                for await c in group { kids.append(c) }
            }
        }
        node.children = kids
        node.size = kids.reduce(0) { $0 + $1.size }
    }
}

// MARK: - App state

@Observable
final class AppModel {
    var root: FileNode?
    var path: [FileNode] = []          // navigation stack; last == folder on screen
    var selected: FileNode?
    var hovered: FileNode?             // shared hover (sidebar ↔ treemap)
    var isScanning = false
    var scannedCount = 0               // live item count during a scan
    var scannedBytes: Int64 = 0        // live bytes seen during a scan
    var version = 0                    // bumped on tree mutation to force redraw
    var previewing = false             // Quick Look panel open (tracks `selected`)

    var current: FileNode? { path.last ?? root }

    init() { loadRecents() }

    /// Show the folder picker, optionally pre-pointed near `start` so a quick
    /// location is one click away.
    func open(at start: URL? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to analyze"
        // Point at the parent so the target folder is selectable in one click.
        if let start { panel.directoryURL = start.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }

    /// Scan a quick location. If any prior grant covers it — the folder itself
    /// or an ancestor (e.g. Home granted once covers Desktop/Downloads) — scan
    /// instantly; otherwise open the picker to ask for access this once.
    func openQuick(_ url: URL) {
        if grantedBookmark(for: url) != nil {
            scan(url)
        } else {
            open(at: url)
        }
    }

    /// A stored bookmark that grants access to `target` — the folder itself or
    /// an ancestor we were previously given access to.
    private func grantedBookmark(for target: URL) -> Data? {
        let t = target.standardizedFileURL.path
        for r in recents {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: r.bookmark,
                                      options: .withSecurityScope,
                                      relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            let rp = root.standardizedFileURL.path
            if rp == t || rp == "/" || t.hasPrefix(rp.hasSuffix("/") ? rp : rp + "/") {
                return r.bookmark
            }
        }
        return nil
    }

    /// Begin accessing whichever granted root covers `target`; returns that root
    /// (to stop later), or nil if no prior grant exists.
    func beginGrantedAccess(for target: URL) -> URL? {
        guard let data = grantedBookmark(for: target) else { return nil }
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
              root.startAccessingSecurityScopedResource() else { return nil }
        return root
    }

    /// Scan a folder dropped onto the welcome screen. Ignores files.
    func scan(dropped url: URL) {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { return }
        scan(url)
    }

    func rescan() {
        guard let url = root?.url else { return }
        scan(url)
    }

    /// Return to the welcome screen, discarding the current scan. Recents persist.
    func goHome() {
        scanTask?.cancel()
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        root = nil
        path = []
        selected = nil
        hovered = nil
        marked.removeAll()
        isScanning = false
    }

    /// Root we hold a security-scoped access grant on (from the open panel), so
    /// reads and trashing work across the session. Released on next scan.
    private var accessedURL: URL?

    private var scanTask: Task<Void, Never>?

    private func scan(_ url: URL) {
        scanTask?.cancel()
        accessedURL?.stopAccessingSecurityScopedResource()
        // Prefer an existing grant (self or ancestor); else this is a fresh
        // user selection from the picker, which is itself granted.
        accessedURL = beginGrantedAccess(for: url)
            ?? (url.startAccessingSecurityScopedResource() ? url : nil)
        rememberRecent(url)        // bookmark while access is active
        isScanning = true
        scannedCount = 0
        scannedBytes = 0
        selected = nil
        hovered = nil
        marked.removeAll()
        // Publish an empty root now so results show as they stream in.
        let tree = FileNode(name: displayName(for: url),
                            isDirectory: true, parent: nil, fixedURL: url)
        root = tree
        path = []
        version += 1
        let progress = ScanProgress()
        let buffer = NodeBuffer()
        scanTask = Task.detached(priority: .userInitiated) {
            await Scanner.scanStreaming(url, parent: tree, progress: progress) {
                buffer.append($0)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                self.attach(buffer.drain(), to: tree)   // final flush
                self.isScanning = false
                self.version += 1
            }
        }
        // Drain finished subtrees into the live tree (and poll the counter)
        // on the main actor, coalescing redraws to ~10fps.
        Task { @MainActor in
            while isScanning {
                scannedCount = progress.count
                scannedBytes = progress.bytes
                attach(buffer.drain(), to: tree)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Append freshly-built subtrees to the live root, growing its size and
    /// refreshing the views. No-op when nothing new arrived.
    private func attach(_ children: [FileNode], to root: FileNode) {
        guard !children.isEmpty else { return }
        root.children.append(contentsOf: children)
        root.size += children.reduce(0) { $0 + $1.size }
        root.invalidate()
        version += 1
    }

    /// Cancel an in-flight scan, keeping whatever was on screen before it.
    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        // Re-grant access to the still-displayed root (the cancelled scan may
        // have swapped the security scope to a different folder).
        accessedURL?.stopAccessingSecurityScopedResource()
        if let u = root?.url, u.startAccessingSecurityScopedResource() {
            accessedURL = u
        } else {
            accessedURL = nil
        }
    }

    // MARK: Recent folders (security-scoped bookmarks)

    private static let recentsKey = "recentBookmarks"

    var recents: [RecentFolder] = []

    private func loadRecents() {
        let datas = UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data] ?? []
        // Dedup on load — keep the newest (first) entry per folder. Stale
        // dupes can lurk in UserDefaults from earlier URL-comparison misses.
        var seen = Set<String>()
        recents = datas.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
            else { return nil }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return RecentFolder(url: url, bookmark: data)
        }
        if recents.map(\.bookmark) != datas { saveRecents() }
    }

    private func saveRecents() {
        UserDefaults.standard.set(recents.map(\.bookmark), forKey: Self.recentsKey)
    }

    /// Bookmark a freshly scanned folder so it re-opens instantly later.
    func rememberRecent(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        // Compare by path string, not URL equality — bookmark-resolved and
        // panel-picked URLs for the same folder can differ in internal form.
        let key = url.standardizedFileURL.path
        recents.removeAll { $0.url.standardizedFileURL.path == key }
        recents.insert(RecentFolder(url: url, bookmark: data), at: 0)
        if recents.count > 8 { recents.removeLast(recents.count - 8) }
        saveRecents()
    }

    func scanRecent(_ r: RecentFolder) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: r.bookmark,
                                 options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            recents.removeAll { $0.id == r.id }       // bookmark went dead
            saveRecents()
            return
        }
        scan(url)
    }

    func drill(into node: FileNode) {
        guard node.isDirectory, !node.children.isEmpty else { return }
        path.append(node)
        selected = nil
    }

    /// Pop the navigation stack back to `node` (a breadcrumb), or to root if nil.
    func navigate(to node: FileNode?) {
        guard let node else { path = []; selected = nil; return }
        if let i = path.firstIndex(where: { $0 === node }) {
            path.removeSubrange((i + 1)...)
        }
        selected = nil
    }

    var breadcrumbs: [FileNode] {
        guard let root else { return [] }
        return [root] + path
    }

    func reveal(_ node: FileNode) {
        guard !node.isAggregate else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    // MARK: Quick Look preview

    /// Toggle the preview panel on the current selection. Space when open closes
    /// it; space when closed opens it for the selected node (if previewable).
    func togglePreview() {
        if previewing { previewing = false }
        else if let s = selected, !s.isAggregate { previewing = true }
    }

    func closePreview() { previewing = false }

    /// Open the preview for a specific node (from the context menu). Selects the
    /// node first so arrow-key navigation continues from it while the panel is open.
    func startPreview(_ node: FileNode) {
        guard !node.isAggregate else { return }
        selected = node
        previewing = true
    }

    // MARK: Mark-for-deletion flow

    /// Items staged for trashing, keyed by node identity (marks reference
    /// live nodes of the current tree, so identity is the natural key).
    var marked: [ObjectIdentifier: FileNode] = [:]
    var lastError: String?

    func isMarked(_ node: FileNode) -> Bool { marked[node.id] != nil }

    func toggleMark(_ node: FileNode) {
        guard node.parent != nil, !node.isAggregate else { return }
        if marked[node.id] != nil { marked[node.id] = nil }
        else { marked[node.id] = node }
        version += 1
    }

    func clearMarks() { marked.removeAll(); version += 1 }

    var markedTotal: Int64 { marked.values.reduce(0) { $0 + $1.size } }

    /// Move every marked item to the Trash. Deepest paths first so trashing a
    /// folder never invalidates a child we haven't processed yet.
    func cleanMarked() {
        let nodes = marked.values.sorted {
            $0.url.pathComponents.count > $1.url.pathComponents.count
        }
        var failures: [String] = []
        for node in nodes {
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                remove(node)
            } catch {
                failures.append("\(node.name): \(error.localizedDescription)")
            }
        }
        marked.removeAll()
        if selected != nil && selected?.parent == nil { /* keep */ }
        lastError = failures.isEmpty ? nil
            : "Couldn't trash \(failures.count) item(s):\n" + failures.joined(separator: "\n")
        version += 1
    }

    /// Detach a node from the tree and subtract its size up the chain.
    private func remove(_ node: FileNode) {
        guard let parent = node.parent,
              let idx = parent.children.firstIndex(where: { $0 === node }) else { return }
        parent.children.remove(at: idx)
        parent.invalidate()
        var p: FileNode? = parent
        while let n = p { n.size -= node.size; p = n.parent }
        if selected === node { selected = nil }
    }
}

extension Int64 {
    var byteString: String { formatted(.byteCount(style: .file)) }

    /// Fixed one-decimal byte string (e.g. "12.30 MB") — width-stable for
    /// live counters where unit transitions and integer/decimal flips would
    /// otherwise make the pill jump.
    var byteStringFixed: String {
        Self.fixedFormatter.string(fromByteCount: self)
    }

    private static let fixedFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .usePB]
        f.zeroPadsFractionDigits = true
        return f
    }()
}

/// A previously scanned folder, re-openable via its security-scoped bookmark.
struct RecentFolder: Identifiable {
    let url: URL
    let bookmark: Data
    var id: URL { url }
}

/// A mounted volume, with capacity read straight from the filesystem (no scan
/// or access grant needed).
struct DiskVolume: Identifiable {
    let url: URL
    let name: String
    let total: Int64
    let used: Int64
    var id: URL { url }

    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static var all: [DiskVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsBrowsableKey, .volumeIsLocalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.volumeIsBrowsable == true, v.volumeIsLocal == true,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let avail = v.volumeAvailableCapacity ?? 0
            return DiskVolume(url: url, name: v.volumeName ?? url.lastPathComponent,
                              total: Int64(total), used: Int64(total - avail))
        }
    }
}

/// Common starting points shown on the welcome screen.
struct QuickLocation: Identifiable {
    let name: String
    let icon: String
    let url: URL
    var id: String { name }

    /// The user's *real* home. In a sandbox, FileManager reports the container
    /// path instead, so read it from the password database.
    static var realHome: URL {
        if let pw = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var all: [QuickLocation] {
        let home = realHome
        return [
            .init(name: "Home", icon: "house", url: home),
            .init(name: "Desktop", icon: "menubar.dock.rectangle", url: home.appending(path: "Desktop")),
            .init(name: "Downloads", icon: "arrow.down.circle", url: home.appending(path: "Downloads")),
            .init(name: "Applications", icon: "square.grid.2x2", url: URL(filePath: "/Applications")),
        ]
    }
}
