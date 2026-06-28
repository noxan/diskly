//
//  Model.swift
//  Diskly
//
//  Disk scanning model + app state.
//

import Foundation
import AppKit

// MARK: - File tree

/// A node in the scanned file tree. Plain class (not observed) — the tree is
/// large; the UI observes `AppModel` and reads `AppModel.version` to refresh.
nonisolated final class FileNode: Identifiable, @unchecked Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var size: Int64
    var children: [FileNode]
    unowned let parent: FileNode?

    var id: URL { url }

    init(url: URL, name: String, isDirectory: Bool, size: Int64 = 0,
         children: [FileNode] = [], parent: FileNode?) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
        self.parent = parent
    }

    private var _sorted: [FileNode]?

    /// Children worth showing, largest first. Cached; call `invalidate()` after
    /// mutating `children`.
    var sortedChildren: [FileNode] {
        if let s = _sorted { return s }
        let s = children.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        _sorted = s
        return s
    }

    func invalidate() { _sorted = nil }
}

// MARK: - Scanner

/// Live item counter shared with the running scan. Locked per directory (not
/// per file) so counting adds no measurable cost to the hot path.
nonisolated final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func add(_ n: Int) { lock.lock(); _count += n; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}

/// Caps how many directory subtrees scan concurrently. Unbounded fan-out
/// (one task per directory) regresses on trees with many tiny dirs — e.g.
/// node_modules — where scheduler overhead swamps the work; bounded to
/// ~core count it's ~2× faster on deep trees with no regression on wide ones.
nonisolated final class ScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if active < limit { active += 1; return true }
        return false
    }
    func release() { lock.lock(); active -= 1; lock.unlock() }
}

nonisolated enum Scanner {
    private static let keys: Set<URLResourceKey> =
        [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    /// Scan a directory tree. Directory subtrees scan concurrently (bounded by
    /// `ScanGate`), so one large subtree no longer pins a single core.
    static func scan(_ root: URL, progress: ScanProgress) async -> FileNode {
        let node = FileNode(url: root, name: root.lastPathComponent,
                            isDirectory: true, parent: nil)
        let gate = ScanGate(limit: ProcessInfo.processInfo.activeProcessorCount)
        await build(node, gate: gate, progress: progress)
        return node
    }

    /// Populate a directory node: plain files inline; subdirectories in parallel
    /// while gate slots are free, otherwise recursed inline.
    private static func build(_ node: FileNode, gate: ScanGate, progress: ScanProgress) async {
        if Task.isCancelled { return }       // bail fast when the scan is cancelled
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: node.url, includingPropertiesForKeys: Array(keys),
            options: [])) ?? []
        progress.add(contents.count)

        var kids: [FileNode] = []
        kids.reserveCapacity(contents.count)

        await withTaskGroup(of: FileNode.self) { group in
            for url in contents {
                let v = try? url.resourceValues(forKeys: keys)
                let isDir = v?.isDirectory ?? false
                let isLink = v?.isSymbolicLink ?? false
                let child = FileNode(url: url, name: url.lastPathComponent,
                                     isDirectory: isDir, parent: node)
                // Don't follow symlinks — avoids loops and double-counting.
                if isDir && !isLink {
                    if gate.tryAcquire() {
                        group.addTask {
                            await build(child, gate: gate, progress: progress)
                            gate.release()
                            return child
                        }
                    } else {
                        await build(child, gate: gate, progress: progress)
                        kids.append(child)
                    }
                } else {
                    child.size = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
                    kids.append(child)
                }
            }
            for await c in group { kids.append(c) }
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
    var version = 0                    // bumped on tree mutation to force redraw

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
    private func beginGrantedAccess(for target: URL) -> URL? {
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
        selected = nil
        marked.removeAll()
        let progress = ScanProgress()
        scanTask = Task.detached(priority: .userInitiated) {
            let tree = await Scanner.scan(url, progress: progress)
            if Task.isCancelled { return }       // discard a cancelled scan
            await MainActor.run {
                self.root = tree
                self.path = []
                self.isScanning = false
                self.version += 1
            }
        }
        // Poll the counter on the main actor while the scan runs.
        Task { @MainActor in
            while isScanning {
                scannedCount = progress.count
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
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
        recents = datas.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
            else { return nil }
            return RecentFolder(url: url, bookmark: data)
        }
    }

    private func saveRecents() {
        UserDefaults.standard.set(recents.map(\.bookmark), forKey: Self.recentsKey)
    }

    /// Bookmark a freshly scanned folder so it re-opens instantly later.
    private func rememberRecent(_ url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        recents.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
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
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    // MARK: Mark-for-deletion flow

    /// Items staged for trashing, keyed by URL.
    var marked: [URL: FileNode] = [:]
    var lastError: String?

    func isMarked(_ node: FileNode) -> Bool { marked[node.url] != nil }

    func toggleMark(_ node: FileNode) {
        guard node.parent != nil else { return }    // never stage the scan root
        if marked[node.url] != nil { marked[node.url] = nil }
        else { marked[node.url] = node }
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
