import Foundation

let CORES = ProcessInfo.processInfo.activeProcessorCount

final class Node: @unchecked Sendable {
    var size: Int64 = 0; var children: [Node] = []
}
final class Gate: @unchecked Sendable {
    private let lock = NSLock(); private var active = 0; let limit: Int
    init(_ l: Int) { limit = l }
    func tryAcquire() -> Bool { lock.lock(); defer { lock.unlock() }
        if active < limit { active += 1; return true }; return false }
    func release() { lock.lock(); active -= 1; lock.unlock() }
}

// ===== A) Current app scanner: Foundation contentsOfDirectory + resourceValues, gated =====
let keys: Set<URLResourceKey> =
    [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
func fmBuild(_ url: URL, _ node: Node, _ gate: Gate) async {
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: Array(keys), options: [])) ?? []
    var kids: [Node] = []
    await withTaskGroup(of: Node.self) { g in
        for u in contents {
            let v = try? u.resourceValues(forKeys: keys)
            let isDir = v?.isDirectory ?? false, isLink = v?.isSymbolicLink ?? false
            let child = Node()
            if isDir && !isLink {
                if gate.tryAcquire() { g.addTask { await fmBuild(u, child, gate); gate.release(); return child } }
                else { await fmBuild(u, child, gate); kids.append(child) }
            } else {
                child.size = Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
                kids.append(child)
            }
        }
        for await n in g { kids.append(n) }
    }
    node.children = kids; node.size = kids.reduce(0) { $0 + $1.size }
}
func fmScan(_ p: String) async -> Node { let n = Node(); await fmBuild(URL(fileURLWithPath: p), n, Gate(CORES)); return n }

// ===== B) getattrlistbulk scanner, gated =====
let ATTR_BIT_MAP_COUNT: UInt16 = 5
let ATTR_CMN_RETURNED_ATTRS: UInt32 = 0x80000000
let ATTR_CMN_NAME: UInt32          = 0x00000001
let ATTR_CMN_OBJTYPE: UInt32       = 0x00000008
let ATTR_FILE_ALLOCSIZE: UInt32    = 0x00000004
let VDIR_T: UInt32 = 2, VLNK_T: UInt32 = 5      // from <sys/vnode.h> vtype

struct DirEntry { var name: String; var isDir: Bool; var isLink: Bool; var size: Int64 }

func listBulk(_ path: String) -> [DirEntry] {
    let fd = open(path, O_RDONLY, 0)
    if fd < 0 { return [] }
    defer { close(fd) }

    var al = attrlist()
    al.bitmapcount = ATTR_BIT_MAP_COUNT
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE
    al.fileattr = ATTR_FILE_ALLOCSIZE

    let bufSize = 256 * 1024
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
    defer { buf.deallocate() }

    var out: [DirEntry] = []
    while true {
        let n = withUnsafeMutablePointer(to: &al) { alp in
            getattrlistbulk(fd, alp, buf, bufSize, 0)
        }
        if n <= 0 { break }
        var p = UnsafeRawPointer(buf)
        for _ in 0..<n {
            let entryStart = p
            let len = entryStart.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            var c = entryStart + 4
            // returned attribute_set_t (5 x u32)
            let retCommon = c.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            let retFile   = c.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            c += 20
            var name = ""; var objtype: UInt32 = 0; var size: Int64 = 0
            if retCommon & ATTR_CMN_NAME != 0 {
                let off = c.loadUnaligned(fromByteOffset: 0, as: Int32.self)
                let nameP = c + Int(off)
                name = String(cString: nameP.assumingMemoryBound(to: CChar.self))
                c += 8   // attrreference_t
            }
            if retCommon & ATTR_CMN_OBJTYPE != 0 {
                objtype = c.loadUnaligned(fromByteOffset: 0, as: UInt32.self); c += 4
            }
            if retFile & ATTR_FILE_ALLOCSIZE != 0 {
                size = c.loadUnaligned(fromByteOffset: 0, as: Int64.self); c += 8
            }
            let isDir = objtype == VDIR_T, isLink = objtype == VLNK_T
            if name != "." && name != ".." {
                out.append(DirEntry(name: name, isDir: isDir, isLink: isLink, size: size))
            }
            p = entryStart + Int(len)
        }
    }
    return out
}

func bulkBuild(_ path: String, _ node: Node, _ gate: Gate) async {
    let entries = listBulk(path)
    var kids: [Node] = []
    await withTaskGroup(of: Node.self) { g in
        for e in entries {
            let child = Node()
            if e.isDir && !e.isLink {
                let sub = path + "/" + e.name
                if gate.tryAcquire() { g.addTask { await bulkBuild(sub, child, gate); gate.release(); return child } }
                else { await bulkBuild(sub, child, gate); kids.append(child) }
            } else {
                child.size = e.size; kids.append(child)
            }
        }
        for await n in g { kids.append(n) }
    }
    node.children = kids; node.size = kids.reduce(0) { $0 + $1.size }
}
func bulkScan(_ p: String) async -> Node { let n = Node(); await bulkBuild(p, n, Gate(CORES)); return n }

func time(_ label: String, _ body: () async -> Node) async -> Int64 {
    let t0 = Date(); let n = await body(); let dt = Date().timeIntervalSince(t0)
    print(String(format: "  %-6@ %7.3fs   size=%@", label as NSString, dt,
                 ByteCountFormatter.string(fromByteCount: n.size, countStyle: .file)))
    return n.size
}

let path = CommandLine.arguments.dropFirst().first ?? NSHomeDirectory()
print("Scanning: \(path)  cores=\(CORES)\n")
_ = await bulkScan(path)   // warm cache
var sizes: [Int64] = []
for _ in 0..<2 { sizes.append(await time("fm", { await fmScan(path) })) }
for _ in 0..<2 { sizes.append(await time("bulk", { await bulkScan(path) })) }
print(String(format: "\nsize delta: fm=%ld bulk=%ld  (%.2f%% diff)",
             sizes[0], sizes[2], Double(abs(sizes[0]-sizes[2])) / Double(max(1,sizes[0])) * 100))
