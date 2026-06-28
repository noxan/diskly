//
//  DiskCache.swift
//  Diskly
//
//  Persistent scan cache. One global SQLite index lets scans of parent folders
//  make later scans of child folders instant.
//

import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated enum DiskCache {
    private static let schemaVersion = 1

    private static var dbURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Diskly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scan-cache.sqlite")
    }

    static func restore(_ url: URL) -> FileNode? {
        let path = url.standardizedFileURL.path
        guard let row = row(path), row.isDir, row.childrenScanned else { return nil }
        let root = FileNode(url: URL(fileURLWithPath: row.path), name: row.name,
                            isDirectory: true, size: row.size, parent: nil)
        root.cachedChildCount = row.childCount
        root.children = loadChildren(of: root)
        root.childrenLoaded = true
        root.cachedChildCount = root.children.count
        root.invalidate()
        return root
    }

    static func loadChildren(of parent: FileNode) -> [FileNode] {
        guard let db = openDB(readonly: true) else { return [] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = """
            SELECT path, name, is_dir, size, child_count, children_scanned
            FROM nodes
            WHERE parent_path = ?
            ORDER BY size DESC
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, parent.url.standardizedFileURL.path)

        var out: [FileNode] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = text(stmt, 0)
            let isDir = sqlite3_column_int(stmt, 2) != 0
            let childCount = Int(sqlite3_column_int(stmt, 4))
            let childrenScanned = sqlite3_column_int(stmt, 5) != 0
            let node = FileNode(url: URL(fileURLWithPath: path),
                                name: text(stmt, 1),
                                isDirectory: isDir,
                                size: sqlite3_column_int64(stmt, 3),
                                parent: parent)
            node.cachedChildCount = childCount
            node.childrenLoaded = !(isDir && childrenScanned && childCount > 0)
            out.append(node)
        }
        return out
    }

    static func save(_ root: FileNode) {
        guard let db = openDB(readonly: false) else { return }
        defer { sqlite3_close(db) }
        guard migrate(db) else { return }

        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        deleteSubtree(root.url.standardizedFileURL.path, db)

        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO nodes
            (path, parent_path, name, is_dir, size, child_count, children_scanned, scanned_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }

        let now = Int64(Date().timeIntervalSince1970)
        insert(root, parentPath: nil, stmt: stmt, scannedAt: now)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private struct Row {
        let path: String
        let name: String
        let isDir: Bool
        let size: Int64
        let childCount: Int
        let childrenScanned: Bool
    }

    private static func row(_ path: String) -> Row? {
        guard let db = openDB(readonly: true) else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = """
            SELECT path, name, is_dir, size, child_count, children_scanned
            FROM nodes
            WHERE path = ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, path)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Row(path: text(stmt, 0),
                   name: text(stmt, 1),
                   isDir: sqlite3_column_int(stmt, 2) != 0,
                   size: sqlite3_column_int64(stmt, 3),
                   childCount: Int(sqlite3_column_int(stmt, 4)),
                   childrenScanned: sqlite3_column_int(stmt, 5) != 0)
    }

    private static func openDB(readonly: Bool) -> OpaquePointer? {
        guard let path = dbURL?.path else { return nil }
        var db: OpaquePointer?
        let flags = readonly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        if !readonly, !migrate(db!) {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func migrate(_ db: OpaquePointer) -> Bool {
        let sql = """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS nodes (
                path TEXT PRIMARY KEY,
                parent_path TEXT,
                name TEXT NOT NULL,
                is_dir INTEGER NOT NULL,
                size INTEGER NOT NULL,
                child_count INTEGER NOT NULL,
                children_scanned INTEGER NOT NULL,
                scanned_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS nodes_parent_idx
                ON nodes(parent_path, size DESC);
            INSERT OR REPLACE INTO meta(key, value)
                VALUES ('schema_version', \(schemaVersion));
            """
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func deleteSubtree(_ path: String, _ db: OpaquePointer) {
        var stmt: OpaquePointer?
        let sql = "DELETE FROM nodes WHERE path = ? OR substr(path, 1, ?) = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        bind(stmt, 1, path)
        sqlite3_bind_int(stmt, 2, Int32(prefix.count))
        bind(stmt, 3, prefix)
        sqlite3_step(stmt)
    }

    private static func insert(_ node: FileNode, parentPath: String?,
                               stmt: OpaquePointer?, scannedAt: Int64) {
        guard !node.isAggregate else { return }
        let path = node.url.standardizedFileURL.path
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        bind(stmt, 1, path)
        if let parentPath { bind(stmt, 2, parentPath) }
        else { sqlite3_bind_null(stmt, 2) }
        bind(stmt, 3, node.name)
        sqlite3_bind_int(stmt, 4, node.isDirectory ? 1 : 0)
        sqlite3_bind_int64(stmt, 5, node.size)
        sqlite3_bind_int(stmt, 6, Int32(node.children.count))
        sqlite3_bind_int(stmt, 7, node.isDirectory ? 1 : 0)
        sqlite3_bind_int64(stmt, 8, scannedAt)
        sqlite3_step(stmt)

        for child in node.children {
            insert(child, parentPath: path, stmt: stmt, scannedAt: scannedAt)
        }
    }

    private static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }
}
