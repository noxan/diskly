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

    // Set on the synthetic "Other" node that merges the small-item tail.
    var isAggregate = false
    var aggregatedCount = 0

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
        let url = parent.url.appendingPathComponent(".__diskly_other__")
        let total = children.reduce(Int64(0)) { $0 + $1.size }
        let n = FileNode(url: url, name: "Other", isDirectory: true,
                         size: total, children: children, parent: parent)
        n.isAggregate = true
        n.aggregatedCount = children.count
        return n
    }
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

/// Holds fully-built top-level subtrees emitted by a streaming scan until the
/// main actor drains them into the live tree. Each node is finished (immutable)
/// before it lands here, so the published tree never races the scanner.
nonisolated final class NodeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FileNode] = []
    func append(_ n: FileNode) { lock.lock(); items.append(n); lock.unlock() }
    func drain() -> [FileNode] {
        lock.lock(); defer { items.removeAll(); lock.unlock() }
        return items
    }
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
    /// One directory entry: name, type, and allocated size — everything the scan
    /// needs, all from a single bulk syscall (no per-file stat).
    struct DirEntry { let name: String; let isDir: Bool; let isLink: Bool; let size: Int64 }

    /// Read a directory in one `getattrlistbulk(2)` syscall per batch — name,
    /// object type, and allocated size for many entries at once, with no
    /// per-`URL` object or per-file `resourceValues` bridging. ~2–4× faster than
    /// `contentsOfDirectory` + `resourceValues` on large trees (measured).
    /// Symlinks report size 0 (their own storage is negligible; we don't follow
    /// them). Returns empty on any open error (permissions, races).
    static func entries(of path: String) -> [DirEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR)
                                    | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE))
        al.fileattr = attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE))

        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }

        var out: [DirEntry] = []
        while true {
            let n = getattrlistbulk(fd, &al, buf, bufSize, 0)
            if n <= 0 { break }                       // 0 = done, <0 = error
            var entry = buf
            for _ in 0..<n {
                // Each entry: u_int32 length, then attrs packed in bitmap order.
                let length = entry.loadUnaligned(as: UInt32.self)
                var f = entry + MemoryLayout<UInt32>.size
                let returned = f.loadUnaligned(as: attribute_set_t.self)
                f += MemoryLayout<attribute_set_t>.size

                var err: UInt32 = 0
                if returned.commonattr & attrgroup_t(UInt32(ATTR_CMN_ERROR)) != 0 {
                    err = f.loadUnaligned(as: UInt32.self); f += MemoryLayout<UInt32>.size
                }
                var name = ""
                if returned.commonattr & attrgroup_t(UInt32(ATTR_CMN_NAME)) != 0 {
                    let ref = f.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (f + Int(ref.attr_dataoffset))
                        .assumingMemoryBound(to: CChar.self))
                    f += MemoryLayout<attrreference_t>.size
                }
                var objType: UInt32 = 0
                if returned.commonattr & attrgroup_t(UInt32(ATTR_CMN_OBJTYPE)) != 0 {
                    objType = f.loadUnaligned(as: UInt32.self)
                    f += MemoryLayout<fsobj_type_t>.size
                }
                var size: Int64 = 0      // absent for non-files (dirs, symlinks)
                if returned.fileattr & attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
                    size = f.loadUnaligned(as: off_t.self)
                }
                // VDIR=2, VLNK=5 (BSD vnode.h object types — stable ABI).
                if err == 0, !name.isEmpty, name != ".", name != ".." {
                    out.append(DirEntry(name: name, isDir: objType == 2,
                                        isLink: objType == 5, size: size))
                }
                entry += Int(length)
            }
        }
        return out
    }

    /// Scan `root`'s contents, emitting each top-level child to `onChild` the
    /// moment its whole subtree is built — so the UI can fill in progressively.
    /// `parent` is the live root node the children attach to; the scanner only
    /// ever hands back finished, immutable subtrees, so it never touches the
    /// published tree (the caller appends them on the main actor).
    /// ponytail: one task per top-level entry — fine for normal roots; a root
    /// with tens of thousands of loose top-level files would over-spawn.
    static func scanStreaming(_ root: URL, parent: FileNode, progress: ScanProgress,
                              onChild: @escaping @Sendable (FileNode) -> Void) async {
        let gate = ScanGate(limit: ProcessInfo.processInfo.activeProcessorCount)
        let contents = entries(of: root.path)
        progress.add(contents.count)
        await withTaskGroup(of: Void.self) { group in
            for e in contents {
                group.addTask {
                    if Task.isCancelled { return }
                    let child = FileNode(url: root.appendingPathComponent(e.name),
                                         name: e.name, isDirectory: e.isDir, parent: parent)
                    if e.isDir && !e.isLink {
                        await build(child, gate: gate, progress: progress)
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
    /// while gate slots are free, otherwise recursed inline.
    private static func build(_ node: FileNode, gate: ScanGate, progress: ScanProgress) async {
        if Task.isCancelled { return }       // bail fast when the scan is cancelled
        let contents = entries(of: node.url.path)
        progress.add(contents.count)

        var kids: [FileNode] = []
        kids.reserveCapacity(contents.count)

        await withTaskGroup(of: FileNode.self) { group in
            for e in contents {
                let child = FileNode(url: node.url.appendingPathComponent(e.name),
                                     name: e.name, isDirectory: e.isDir, parent: node)
                // Don't follow symlinks — avoids loops and double-counting.
                if e.isDir && !e.isLink {
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
                    child.size = e.size
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
        hovered = nil
        marked.removeAll()
        // Publish an empty root now so results show as they stream in.
        let tree = FileNode(url: url, name: url.lastPathComponent,
                            isDirectory: true, parent: nil)
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
        guard !node.isAggregate else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    // MARK: Mark-for-deletion flow

    /// Items staged for trashing, keyed by URL.
    var marked: [URL: FileNode] = [:]
    var lastError: String?

    func isMarked(_ node: FileNode) -> Bool { marked[node.url] != nil }

    func toggleMark(_ node: FileNode) {
        guard node.parent != nil, !node.isAggregate else { return }
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
