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

nonisolated enum Scanner {
    private static let keys: Set<URLResourceKey> =
        [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    /// Scan a directory tree. Top-level children are scanned in parallel across
    /// cores; each subtree is built synchronously.
    static func scan(_ root: URL) async -> FileNode {
        let node = FileNode(url: root, name: root.lastPathComponent,
                            isDirectory: true, parent: nil)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [])) ?? []

        var kids: [FileNode] = []
        await withTaskGroup(of: FileNode?.self) { group in
            for child in contents {
                group.addTask { build(child, parent: node) }
            }
            for await c in group where c != nil { kids.append(c!) }
        }
        node.children = kids
        node.size = kids.reduce(0) { $0 + $1.size }
        return node
    }

    private static func build(_ url: URL, parent: FileNode) -> FileNode? {
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
            var total: Int64 = 0
            var kids: [FileNode] = []
            kids.reserveCapacity(contents.count)
            for child in contents {
                if let c = build(child, parent: node) {
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

    func rescan() {
        guard let url = root?.url else { return }
        scan(url)
    }

    private func scan(_ url: URL) {
        isScanning = true
        selected = nil
        Task.detached(priority: .userInitiated) {
            let tree = await Scanner.scan(url)
            await MainActor.run {
                self.root = tree
                self.path = []
                self.isScanning = false
                self.version += 1
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

    func trash(_ node: FileNode) {
        guard node.parent != nil else { return }   // never trash the scan root
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            NSSound.beep()
            return
        }
        // Detach from parent and subtract its size up the chain.
        if let parent = node.parent,
           let idx = parent.children.firstIndex(where: { $0 === node }) {
            parent.children.remove(at: idx)
            parent.invalidate()
            var p: FileNode? = parent
            while let n = p { n.size -= node.size; p = n.parent }
        }
        if selected === node { selected = nil }
        version += 1
    }
}

extension Int64 {
    var byteString: String { formatted(.byteCount(style: .file)) }
}
