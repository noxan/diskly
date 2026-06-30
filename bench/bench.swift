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
func disklyBuild(_ url: URL, _ node: Node, _ gate: ScanGate,
                 _ registry: DirRegistry) async {
    guard registry.shouldWalk(url) else { return }
    let contents = Scanner.entries(of: url.path)
    itemCount.withLock { $0 += contents.count }
    var kids: [Node] = []
    kids.reserveCapacity(contents.count)
    await withTaskGroup(of: Node.self) { group in
        for e in contents {
            let child = Node()
            if e.isDir && !e.isLink {
                let childURL = url.appendingPathComponent(e.name)
                if gate.tryAcquire() {
                    group.addTask {
                        await disklyBuild(childURL, child, gate, registry)
                        gate.release()
                        return child
                    }
                } else {
                    await disklyBuild(childURL, child, gate, registry)
                    kids.append(child)
                }
            } else {
                child.size = e.size
                kids.append(child)
            }
        }
        for await n in group { kids.append(n) }
    }
    node.children = kids
    node.size = kids.reduce(0) { $0 + $1.size }
}

func disklyScan(_ root: URL) async -> Node {
    itemCount.withLock { $0 = 0 }
    let n = Node()
    let top = Scanner.entries(of: root.path)
    itemCount.withLock { $0 += top.count }
    let gate = ScanGate(limit: CORES)
    let registry = DirRegistry()
    await withTaskGroup(of: Node.self) { group in
        for e in top {
            let child = Node()
            if e.isDir && !e.isLink {
                let childURL = root.appendingPathComponent(e.name)
                group.addTask {
                    await disklyBuild(childURL, child, gate, registry)
                    return child
                }
            } else {
                child.size = e.size
                group.addTask { return child }
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
        let arg = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : NSHomeDirectory() + "/Library"
        let path = (arg as NSString).standardizingPath
        let url = URL(fileURLWithPath: path)

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