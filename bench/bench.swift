//
//  bench/bench.swift
//  Diskly — cross-tool scan speed comparison.
//
//  Times Diskly's production scanner (getattrlistbulk + parallel TaskGroup)
//  against external disk analyzers so the speedup is visible at the command
//  line. Run it whenever you want a reproducible number for the README or a
//  release tweet.
//
//  The scanner primitives (`Scanner.entries`, `ScanGate`, `DirRegistry`) are
//  compiled in from Diskly/Scanner.swift — the same file the app uses. Improve
//  them once and both the app and the benchmark pick up the change. This file
//  only adds a simpler `Node` to drive that same engine, then times `du`,
//  `ncdu`, and `find + stat` as subprocesses for comparison.
//
//  Build + run (the binary is gitignored):
//      make bench                          # default: ~/Library
//      make bench BENCH_PATH=~/Developer
//
//  Or compile manually:
//      swiftc -O bench/bench.swift Diskly/Scanner.swift -o bench/bench
//      ./bench/bench ~/Library
//

import Foundation
import Darwin
import Synchronization

// MARK: - Tree builder (uses the shared scanner primitives)

/// Bench-only tree node: just byte size and children. Skips the UI caching
/// (`_sorted`, `displayChildren`, `invalidate`) that `FileNode` carries —
/// the bench only needs the total and the item count, not a redrawable tree.
final class Node: @unchecked Sendable {
    var size: Int64 = 0
    var children: [Node] = []
}

/// Live item counter, locked per directory (mirrors Diskly/Model.swift
/// ScanProgress).
let itemCount = Mutex(0)

let CORES = ProcessInfo.processInfo.activeProcessorCount

/// Diskly's parallel tree builder: plain files inline; subdirectories in
/// parallel while gate slots are free, otherwise recursed inline. Mirrors
/// Diskly/Model.swift:Scanner.build but drives a simpler `Node`.
/// The directory is opened via openat(2) relative to the parent's open fd —
/// single-component resolution — and the fd stays open until the subtree is
/// walked so children can do the same.
func disklyBuild(parentFD: Int32, name: String, path: String, _ node: Node,
                 _ gate: ScanGate, _ registry: DirRegistry) async {
    let fd = Scanner.openDir(at: parentFD, name, path: path)
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard registry.shouldWalk(path: path, fd: fd) else { return }
    let contents = Scanner.entries(fd: fd, path: path)
    itemCount.withLock { $0 += contents.count }
    var kids: [Node] = []
    kids.reserveCapacity(contents.count)
    // Files inline; collect subdirs first so leaf dirs (most dirs) and
    // single-subdir chains never pay for task-group setup — profiling showed
    // withTaskGroup machinery as the top non-syscall cost.
    var dirs: [Scanner.DirEntry] = []
    for e in contents {
        if e.isDir && !e.isLink {
            dirs.append(e)
        } else {
            let child = Node()
            child.size = e.size
            kids.append(child)
        }
    }
    if dirs.count == 1 {
        // One subdir: nothing to run in parallel with — recurse inline.
        let e = dirs[0]
        let child = Node()
        await disklyBuild(parentFD: fd, name: e.name, path: path + "/" + e.name,
                          child, gate, registry)
        kids.append(child)
    } else if dirs.count > 1 {
        await withTaskGroup(of: Node.self) { group in
            for e in dirs {
                let child = Node()
                let childPath = path + "/" + e.name
                if gate.tryAcquire() {
                    group.addTask {
                        defer { gate.release() }
                        await disklyBuild(parentFD: fd, name: e.name,
                                          path: childPath, child, gate, registry)
                        return child
                    }
                } else {
                    await disklyBuild(parentFD: fd, name: e.name,
                                      path: childPath, child, gate, registry)
                    kids.append(child)
                }
            }
            for await n in group { kids.append(n) }
        }
    }
    node.children = kids
    node.size = kids.reduce(0) { $0 + $1.size }
}

func disklyScan(_ root: URL) async -> Node {
    itemCount.withLock { $0 = 0 }
    let n = Node()
    let rootPath = root.path
    let rootFD = Scanner.openDir(rootPath)
    guard rootFD >= 0 else { return n }
    defer { close(rootFD) }
    let gate = ScanGate(limit: CORES)
    let registry = DirRegistry(rootPath: rootPath)
    let childPath: (String) -> String = { rootPath == "/" ? "/" + $0 : rootPath + "/" + $0 }
    guard registry.shouldWalk(path: rootPath, fd: rootFD) else { return n }
    let top = Scanner.entries(fd: rootFD, path: rootPath)
    itemCount.withLock { $0 += top.count }
    await withTaskGroup(of: Node.self) { group in
        for e in top {
            let child = Node()
            if e.isDir && !e.isLink, gate.tryAcquire() {
                group.addTask {
                    defer { gate.release() }
                    let start = Date()
                    await disklyBuild(parentFD: rootFD, name: e.name,
                                      path: childPath(e.name),
                                      child, gate, registry)
                    Scanner.reportSlow("top-level folder", path: childPath(e.name),
                                       since: start)
                    return child
                }
            } else if e.isDir && !e.isLink {
                let start = Date()
                await disklyBuild(parentFD: rootFD, name: e.name,
                                  path: childPath(e.name),
                                  child, gate, registry)
                Scanner.reportSlow("top-level folder", path: childPath(e.name),
                                   since: start)
                n.children.append(child)
            } else {
                child.size = e.size
                n.children.append(child)
            }
        }
        for await n0 in group { n.children.append(n0) }
    }
    n.size = n.children.reduce(0) { $0 + $1.size }
    return n
}

// MARK: - Timing helpers

func fmtTime(_ s: Double) -> String {
    String(format: "%.2fs", s)
}
func fmtBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

/// Run a shell command and return (wallSeconds, stdoutTrimmed, exitCode).
func runShell(_ cmd: String) -> (Double, String, Int32) {
    let t = Date()
    let p = Process()
    p.launchPath = "/bin/sh"
    p.arguments = ["-c", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle()  // discard
    do { try p.run() } catch {
        return (Date().timeIntervalSince(t), "", -1)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let dt = Date().timeIntervalSince(t)
    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines) ?? ""
    return (dt, out, p.terminationStatus)
}

func which(_ name: String) -> String? {
    let (_, out, code) = runShell("/usr/bin/which \(name)")
    return code == 0 && !out.isEmpty ? out : nil
}

// MARK: - Column helpers — built by interpolation, not sprintf, so Swift
// strings and non-ASCII glyphs ("\u{00D7}" etc.) are safe.

func pad(_ s: String, _ w: Int, _ alignRight: Bool = false) -> String {
    if s.count >= w { return s }
    let blanks = String(repeating: " ", count: w - s.count)
    return alignRight ? blanks + s : s + blanks
}
func fmtMBps(_ b: Double) -> String { String(format: "%.0f", b) }
func fmtX(_ x: Double) -> String { String(format: "%.2f\u{00D7}", x) }
func row(_ tool: String, _ time: String, _ items: String, _ mbps: Double, _ x: Double) -> String {
    "\(pad(tool, 20))  \(pad(time, 8, true))   \(pad(items, 8, true))  " +
    "\(pad(fmtMBps(mbps), 6, true))   \(fmtX(x))"
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Entry point

@main
struct Bench {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        // --quick: Diskly scan only (best of 3), no external tools. For
        // iterating on scanner performance without paying for du/find/ncdu.
        let quick = args.contains("--quick")
        let once = args.contains("--once")
        args.removeAll { $0 == "--quick" || $0 == "--once" }
        let arg = args.first ?? NSHomeDirectory() + "/Library"
        let path = (arg as NSString).standardizingPath
        let url = URL(fileURLWithPath: path)

        if once {
            let t = Date()
            let root = await disklyScan(url)
            let dt = Date().timeIntervalSince(t)
            let items = itemCount.withLock { $0 }
            print("one scan  path: \(path)  cores: \(CORES)")
            print("items: \(items)  bytes: \(fmtBytes(root.size))")
            print("time: \(fmtTime(dt))  (\(fmtMBps(Double(root.size) / dt / 1_000_000)) MB/s)")
            return
        }

        if quick {
            _ = await disklyScan(url)   // warm page cache
            var times: [Double] = []
            var items = 0; var bytes: Int64 = 0
            for _ in 0..<3 {
                let t = Date()
                let root = await disklyScan(url)
                times.append(Date().timeIntervalSince(t))
                items = itemCount.withLock { $0 }
                bytes = root.size
            }
            let best = times.min()!
            print("quick bench  path: \(path)  cores: \(CORES)")
            print("items: \(items)  bytes: \(fmtBytes(bytes))")
            print("runs: " + times.map { fmtTime($0) }.joined(separator: "  "))
            print("best: \(fmtTime(best))  (\(fmtMBps(Double(bytes) / best / 1_000_000)) MB/s)")
            return
        }

        print("Diskly scan benchmark")
        print("path:  \(path)")
        print("cores: \(CORES)\n")

        // Warm the page cache so the first run isn't penalized relative to the
        // external tools (which the kernel also caches for after the first scan).
        _ = await disklyScan(url)

        // Diskly scan — production algorithm.
        let dT = Date()
        let dRoot = await disklyScan(url)
        let dDt = Date().timeIntervalSince(dT)
        let items = itemCount.withLock { $0 }
        let bytes = dRoot.size

        // du -sk: classic single-threaded baseline.
        let (duDt, duOut, _) = runShell("du -sk \(shellQuote(path)) 2>/dev/null")
        let duKB = Int64(duOut.split(separator: "\t").first.flatMap { Int64($0) } ?? 0)

        // find + stat: same logical work as Diskly (one stat per file) but single
        // threaded and per-file process spawns via xargs. Use allocated blocks
        // (`%b` * 512) so the byte total matches Diskly's ATTR_FILE_ALLOCSIZE —
        // `%z` would count sparse-file logical size, inflating MB/s unfairly.
        let (findDt, findOut, _) = runShell(
            "find \(shellQuote(path)) -type f -print0 2>/dev/null | " +
            "xargs -0 stat -f '%b' 2>/dev/null | awk '{s+=$1*512} END{print s}'")
        let findBytes = Int64(findOut) ?? 0
        let findItems = items  // find handles file count; reusing Diskly's count

        // ncdu: full interactive-equivalent scan, export-only mode (`-1`
        // one-shot, `-o -` dump JSON to stdout, no TUI).
        var ncduDt: Double? = nil
        if which("ncdu") != nil {
            let (dt, _, _) = runShell("ncdu -1 -o - \(shellQuote(path)) 2>/dev/null")
            ncduDt = dt
        } else {
            print("(ncdu not installed — skipped. brew install ncdu to include it.)")
        }

        // MARK: Report

        let mbpsDiskly = dDt > 0 ? Double(bytes) / dDt / 1_000_000 : 0
        let mbpsDu     = duDt > 0 ? Double(duKB * 1024) / duDt / 1_000_000 : 0
        let mbpsFind   = findDt > 0 ? Double(findBytes) / findDt / 1_000_000 : 0

        print("Scanned    \(items) items, \(fmtBytes(bytes))\n")

        let header = "\(pad("tool", 20))  \(pad("time", 8, true))   " +
                     "\(pad("items", 8, true))  \(pad("MB/s", 6, true))   vs Diskly"
        print(header)
        print(String(repeating: "\u{2500}", count: header.count))

        print(row("Diskly (this scan)", fmtTime(dDt), String(items), mbpsDiskly, 1.0))
        print(row("du -sk", fmtTime(duDt), "\u{2014}", mbpsDu, duDt / max(dDt, 0.0001)))
        print(row("find + stat", fmtTime(findDt), String(findItems), mbpsFind, findDt / max(dDt, 0.0001)))
        if let nd = ncduDt {
            let mbpsN = nd > 0 ? Double(bytes) / nd / 1_000_000 : 0
            print(row("ncdu -1 -o -", fmtTime(nd), "\u{2014}", mbpsN, nd / max(dDt, 0.0001)))
        }

        print("\nFairness notes:")
        print("  - du counts blocks (kilobytes); Diskly counts ATTR_FILE_ALLOCSIZE.")
        print("    Numbers won't match exactly, but the wall time is comparable.")
        print("  - find + stat does one stat per file single-threaded; the closest")
        print("    apples-to-apples work match to Diskly, which batches via")
        print("    getattrlistbulk(2) and fans out across cores.")
        print("  - One warm-up scan ran first to fill the page cache, so every tool")
        print("    benefits equally from kernel caching.")
    }
}
