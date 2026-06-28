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

nonisolated enum Scanner {
    private static let keys: Set<URLResourceKey> =
        [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    /// Scan a directory tree. Top-level children are scanned in parallel across
    /// cores; each subtree is built synchronously.
    static func scan(_ root: URL, progress: ScanProgress) async -> FileNode {
        let node = FileNode(url: root, name: root.lastPathComponent,
                            isDirectory: true, parent: nil)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [])) ?? []
        progress.add(contents.count)

        var kids: [FileNode] = []
        await withTaskGroup(of: FileNode?.self) { group in
            for child in contents {
                group.addTask { build(child, parent: node, progress: progress) }
            }
            for await c in group where c != nil { kids.append(c!) }
        }
        node.children = kids
        node.size = kids.reduce(0) { $0 + $1.size }
        return node
    }

    private static func build(_ url: URL, parent: FileNode, progress: ScanProgress) -> FileNode? {
        let v = try? url.resourceValues(forKeys: keys)
        let isDir = v?.isDirectory ?? false
        let isLink = v?.isSymbolicLink ?? false
        let node = FileNode(url: url, name: url.lastPathComponent,
                            isDirectory: isDir, parent: parent)

        // Don't follow symlinks — avoids loops and double-counting.
        if isDir && !isLink {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(keys),
                options: [])) ?? []
            progress.add(contents.count)
            var total: Int64 = 0
            var kids: [FileNode] = []
            kids.reserveCapacity(contents.count)
            for child in contents {
                if let c = build(child, parent: node, progress: progress) {
                    kids.append(c)
                    total += c.size
                }
            }
            node.children = kids
            node.size = total
        } else {
            node.size = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return node
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

    func open() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to analyze"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
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

    /// Root we hold a security-scoped access grant on (from the open panel), so
    /// reads and trashing work across the session. Released on next scan.
    private var accessedURL: URL?

    private func scan(_ url: URL) {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
        isScanning = true
        scannedCount = 0
        selected = nil
        marked.removeAll()
        let progress = ScanProgress()
        Task.detached(priority: .userInitiated) {
            let tree = await Scanner.scan(url, progress: progress)
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
