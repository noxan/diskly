//
//  Scanner.swift
//  Diskly
//
//  Core scanner primitives — shareable between the app and the benchmark.
//  No AppKit, no FileNode, no UI dependencies. The app fills in the
//  tree-builder in Model.swift via `extension Scanner`; the benchmark
//  compiles this file alongside bench.swift and supplies its own simpler
//  Node type to drive the same `entries(of:)` and `DirRegistry`.
//

import Foundation
import Darwin
import os
import Synchronization

/// Caps how many directory subtrees scan concurrently. Unbounded fan-out
/// (one task per directory) regresses on trees with many tiny dirs — e.g.
/// node_modules — where scheduler overhead swamps the work; bounded to
/// ~core count it's ~2× faster on deep trees with no regression on wide ones.
nonisolated final class ScanGate: @unchecked Sendable {
    private let active = Mutex(0)
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func tryAcquire() -> Bool {
        active.withLock { a in
            if a < limit { a += 1; return true }
            return false
        }
    }
    func release() { active.withLock { $0 -= 1 } }
}

/// (device, inode) key for a filesystem directory. Firmlinks and bind mounts
/// expose the same physical directory via multiple paths; this lets the scanner
/// recognize "already walked" regardless of which path led there.
nonisolated private struct InodeKey: Hashable, Sendable {
    let dev: UInt64; let ino: UInt64
}

/// Guards against walking the same physical directory twice. macOS Catalina+
/// splits the boot disk into a read-only System volume ("/") and a writable
/// Data volume ("/System/Volumes/Data") connected by firmlinks: every path
/// "/System/Volumes/Data/<X>" is also reachable as "/<X>" — same device, same
/// inode. Without this guard, scanning "/" walks the Data volume twice and the
/// reported total exceeds the disk size. The firmlink source (e.g. "/Users")
/// is the canonical, user-facing path, so we always skip its Data-volume
/// counterpart; the (dev, ino) set also catches bind mounts and "/Volumes"
/// re-entry loops.
nonisolated final class DirRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<InodeKey> = []
    /// Subpaths of the Data volume that have a firmlink source at "/" — these
    /// are walked via their firmlink path, never via the Data mount path.
    private let firmlinkTargets: Set<String>
    private let skipMountedVolumes: Bool
    private let rootPath: String

    init(rootPath: String) {
        self.rootPath = rootPath
        self.firmlinkTargets = Self.loadFirmlinkTargets()
        self.skipMountedVolumes = rootPath == "/"
    }

    /// True if the directory open at `fd` (full path `path`) should be
    /// recursed into. Returns false for:
    /// - the Data-volume side of a firmlink (the "/" side handles it), and
    /// - any directory whose (device, inode) was already walked.
    /// Identity comes from fstat(2) on the open fd — no path re-resolution.
    func shouldWalk(path: String, fd: Int32) -> Bool {
        if skipMountedVolumes, path == "/Volumes" { return false }
        // Nix's dedup index contains hard links to files already represented
        // by normal store paths. Walking it is slow and double-counts storage.
        if path == "/nix/store/.links", path != rootPath { return false }
        let dataMount = "/System/Volumes/Data/"
        if path.hasPrefix(dataMount) {
            let rest = String(path.dropFirst(dataMount.count))
            // Exact match on the firmlink target (right column of
            // /usr/share/firmlinks) — handles nested targets like
            // "System/Library/Caches", not just top-level ones.
            if firmlinkTargets.contains(rest) { return false }
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return true } // unreadable → just walk it
        let key = InodeKey(dev: UInt64(st.st_dev), ino: UInt64(st.st_ino))
        lock.lock(); defer { lock.unlock() }
        return seen.insert(key).inserted
    }

    /// Targets (right column) of "/usr/share/firmlinks", loaded once per scan.
    static func loadFirmlinkTargets() -> Set<String> {
        guard let text = try? String(contentsOfFile: "/usr/share/firmlinks",
                                      encoding: .utf8) else { return [] }
        var out = Set<String>()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            out.insert(String(parts[1]))
        }
        return out
    }
}

// MARK: - Scanner primitives

nonisolated enum Scanner {
    private static let log = Logger(subsystem: "com.diskly.app", category: "scan")

    static func reportSlow(_ action: String, path: String, since start: Date,
                           threshold: TimeInterval = 1) {
        let seconds = Date().timeIntervalSince(start)
        if seconds >= threshold {
            log.notice("Slow scan \(action, privacy: .public): \(seconds, format: .fixed(precision: 2))s \(path, privacy: .public)")
        }
    }

    /// One-time process setup for scanning, triggered on first directory open:
    /// - Never materialize dataless (iCloud / file-provider) files: open() on
    ///   a dataless directory otherwise blocks on a network recall — a disk
    ///   scanner must measure, not download. Constants from sys/resource.h
    ///   (not exposed to Swift by name).
    /// - Raise RLIMIT_NOFILE: the openat-based walk holds one fd per
    ///   in-progress directory (≈ parallel chains × tree depth), which can
    ///   exceed the default 256 soft limit.
    static let scanSetup: Void = {
        _ = setiopolicy_np(3 /* IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES */,
                           0 /* IOPOL_SCOPE_PROCESS */,
                           1 /* IOPOL_MATERIALIZE_DATALESS_FILES_OFF */)
        var rl = rlimit()
        if getrlimit(RLIMIT_NOFILE, &rl) == 0 {
            rl.rlim_cur = min(10240, rl.rlim_max)   // rlim_max may be "infinity" (huge) — min handles it
            _ = setrlimit(RLIMIT_NOFILE, &rl)
        }
    }()

    /// Open a directory for scanning. Returns -1 on error.
    static func openDir(_ path: String) -> Int32 {
        _ = scanSetup
        let start = Date()
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        reportSlow("open", path: path, since: start)
        return fd
    }

    /// Open a subdirectory relative to an already-open parent directory.
    /// openat(2) resolves only the single final component — the parent chain
    /// was resolved once when the parent was opened. Profiling showed the
    /// scan bottlenecked in full-path open(), which re-resolves every path
    /// component for every directory.
    static func openDir(at parent: Int32, _ name: String, path: String) -> Int32 {
        let start = Date()
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY)
        reportSlow("open", path: path, since: start)
        return fd
    }

    /// One directory entry: name, type, and allocated size — everything the scan
    /// needs, all from a single bulk syscall (no per-file stat).
    struct DirEntry { let name: String; let isDir: Bool; let isLink: Bool; let size: Int64 }

    /// Read a directory in one `getattrlistbulk(2)` syscall per batch — name,
    /// object type, and allocated size for many entries at once, with no
    /// per-`URL` object or per-file `resourceValues` bridging. ~2–4× faster
    /// than `contentsOfDirectory` + `resourceValues` on large trees (measured).
    /// Symlinks report size 0 (their own storage is negligible; we don't follow
    /// them). Returns empty on any open error (permissions, races).
    static func entries(of path: String) -> [DirEntry] {
        let fd = openDir(path)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        return entries(fd: fd, path: path)
    }

    /// Core bulk read from an already-open directory fd. Does NOT close `fd`.
    static func entries(fd: Int32, path: String) -> [DirEntry] {
        let start = Date()
        defer { reportSlow("enumerate", path: path, since: start) }
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
}
