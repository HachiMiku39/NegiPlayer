import Foundation
import CSQLite
import LibraryDomain
import LyricCore

public struct StoreError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public actor LibraryDatabase {
    private var db: OpaquePointer?
    public let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw StoreError(message: "无法打开 SQLite 数据库") }
        sqlite3_busy_timeout(db, 5_000)
        let schema = """
        PRAGMA foreign_keys=ON;
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS library_roots(id TEXT PRIMARY KEY, path TEXT UNIQUE NOT NULL, document TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS releases(id TEXT PRIMARY KEY, title TEXT NOT NULL, album_artist TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS discs(id TEXT PRIMARY KEY, release_id TEXT REFERENCES releases(id), number INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS tracks(id TEXT PRIMARY KEY, disc_id TEXT REFERENCES discs(id), title TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS media_files(id TEXT PRIMARY KEY, root_id TEXT REFERENCES library_roots(id), track_id TEXT REFERENCES tracks(id), path TEXT NOT NULL, available INTEGER NOT NULL, document TEXT NOT NULL, UNIQUE(root_id,path));
        CREATE TABLE IF NOT EXISTS artists(id TEXT PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS credits(track_id TEXT REFERENCES tracks(id), artist_id TEXT REFERENCES artists(id), role TEXT NOT NULL, ordinal INTEGER NOT NULL, display TEXT NOT NULL, PRIMARY KEY(track_id,role,ordinal));
        CREATE TABLE IF NOT EXISTS tag_snapshots(media_id TEXT PRIMARY KEY REFERENCES media_files(id), document TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS user_overrides(media_id TEXT REFERENCES media_files(id), field TEXT, document TEXT, PRIMARY KEY(media_id,field));
        CREATE TABLE IF NOT EXISTS playlists(id TEXT PRIMARY KEY, name TEXT NOT NULL, rules TEXT);
        CREATE TABLE IF NOT EXISTS playlist_items(playlist_id TEXT REFERENCES playlists(id), track_id TEXT REFERENCES tracks(id), media_id TEXT REFERENCES media_files(id), ordinal INTEGER, PRIMARY KEY(playlist_id,ordinal));
        CREATE TABLE IF NOT EXISTS lyric_documents(media_id TEXT PRIMARY KEY REFERENCES media_files(id), document TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS lyric_revisions(media_id TEXT, revision INTEGER, document TEXT, PRIMARY KEY(media_id,revision));
        CREATE TABLE IF NOT EXISTS file_jobs(id TEXT PRIMARY KEY, phase TEXT NOT NULL, document TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS analysis_cache(media_id TEXT, parameters TEXT, document TEXT, PRIMARY KEY(media_id,parameters));
        CREATE INDEX IF NOT EXISTS media_root_path ON media_files(root_id,path);
        PRAGMA user_version=1;
        """
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, schema, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "数据库迁移失败"
            sqlite3_free(error); sqlite3_close(db); db = nil; throw StoreError(message: message)
        }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(i+1), value, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func query(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(i+1), value, -1, transient) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
        }
        return result
    }
    private func failure() -> StoreError { StoreError(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库已关闭") }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    public func roots() throws -> [LibraryRoot] { try query("SELECT document FROM library_roots ORDER BY path").map { try decoder.decode(LibraryRoot.self, from: Data($0[0].utf8)) } }
    public func save(root: LibraryRoot) throws {
        try execute("INSERT INTO library_roots(id,path,document) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,document=excluded.document", [root.id, root.path, try json(root)])
    }
    public func files(rootID: String? = nil) throws -> [MediaFile] {
        let rows = try rootID.map { try query("SELECT document,available FROM media_files WHERE root_id=? ORDER BY path", [$0]) } ?? query("SELECT document,available FROM media_files ORDER BY path")
        return try rows.map { var f = try decoder.decode(MediaFile.self, from: Data($0[0].utf8)); f.available = $0[1] == "1"; return f }
    }
    /// A completed enumeration is required; partial/cancelled scans never mark files missing.
    public func commitScan(rootID: String, files: [MediaFile]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("UPDATE media_files SET available=0 WHERE root_id=?", [rootID])
            let stored = Dictionary(uniqueKeysWithValues: try self.files(rootID: rootID).map { ($0.id, $0) })
            for item in files {
                var f = item
                if f.audioIdentity == nil, let existing = stored[f.id], existing.size == f.size, existing.modified == f.modified {
                    f.audioIdentity = existing.audioIdentity
                }
                let release = f.releaseKey.isEmpty ? f.id : f.releaseKey
                let disc = release + ":disc:\(f.discNumber)"
                try execute("INSERT INTO releases VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,album_artist=excluded.album_artist", [release, f.album, f.albumArtist])
                try execute("INSERT OR IGNORE INTO discs VALUES(?,?,?)", [disc, release, String(f.discNumber)])
                try execute("INSERT INTO tracks VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET disc_id=excluded.disc_id,title=excluded.title", [f.id, disc, f.title])
                try execute("INSERT INTO media_files VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path,available=excluded.available,document=excluded.document", [f.id, rootID, f.id, f.relativePath, f.available ? "1" : "0", try json(f)])
                try execute("DELETE FROM credits WHERE track_id=?", [f.id])
                for (i, artist) in f.artists.enumerated() {
                    try execute("INSERT OR IGNORE INTO artists VALUES(?,?)", [artist, artist])
                    try execute("INSERT INTO credits VALUES(?,?,?,?,?)", [f.id, artist, "performer", String(i), artist])
                }
                try execute("INSERT INTO tag_snapshots VALUES(?,?) ON CONFLICT(media_id) DO UPDATE SET document=excluded.document", [f.id, try json(f.tags)])
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func setOffline(rootID: String) throws { try execute("UPDATE media_files SET available=0 WHERE root_id=?", [rootID]) }
    /// Store a lazily computed fingerprint only while the indexed source version still matches.
    public func saveAudioIdentity(_ identity: String, for media: MediaFile) throws {
        guard let row = try query("SELECT document FROM media_files WHERE id=?", [media.id]).first else { throw StoreError(message: "曲目不在音乐库中") }
        var stored = try decoder.decode(MediaFile.self, from: Data(row[0].utf8))
        guard stored.size == media.size, stored.modified == media.modified else { throw StoreError(message: "音频文件版本已改变，请重新扫描") }
        stored.audioIdentity = identity
        try execute("UPDATE media_files SET document=? WHERE id=?", [try json(stored), media.id])
    }
    public func draft(mediaID: String) throws -> LyricDocument? {
        guard let row = try query("SELECT document FROM lyric_documents WHERE media_id=?", [mediaID]).first else { return nil }
        return try decoder.decode(LyricDocument.self, from: Data(row[0].utf8))
    }
    public func saveDraft(_ d: LyricDocument, mediaID: String) throws {
        try LyricFormats.validate(d)
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try json(d)
            try execute("INSERT INTO lyric_documents VALUES(?,?) ON CONFLICT(media_id) DO UPDATE SET document=excluded.document", [mediaID, value])
            try execute("INSERT OR REPLACE INTO lyric_revisions VALUES(?,?,?)", [mediaID, String(d.revision), value])
            try execute("DELETE FROM lyric_revisions WHERE media_id=? AND revision < ?", [mediaID, String(max(0,d.revision-100))])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func integrityCheck() throws -> String { try query("PRAGMA integrity_check").map { $0[0] }.joined(separator: "\n") }
    public func backup(to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".backup-\(UUID().uuidString).sqlite")
        var target: OpaquePointer?
        guard sqlite3_open(temporary.path, &target) == SQLITE_OK else { throw StoreError(message: "无法创建备份") }
        defer { sqlite3_close(target); try? FileManager.default.removeItem(at: temporary) }
        guard let backup = sqlite3_backup_init(target, "main", db, "main") else { throw failure() }
        let status = sqlite3_backup_step(backup, -1); let end = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, end == SQLITE_OK else { throw StoreError(message: "SQLite 一致备份失败，原数据库未改动") }
        guard FileManager.default.fileExists(atPath: destination.path) == false else { throw StoreError(message: "备份目标已存在，请另选文件名") }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
