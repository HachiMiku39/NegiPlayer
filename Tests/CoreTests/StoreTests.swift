import XCTest
import LibraryStore
import LibraryDomain
import LyricCore
import MediaIO
import AVFoundation

final class StoreTests: XCTestCase {
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lmp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testWALBackupRestartOfflineAndDraftSurviveScan() async throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let db = try LibraryDatabase(url: folder.appendingPathComponent("Library.sqlite"))
        let root = LibraryRoot(path: "/test", bookmark: Data([1,2,3]))
        try await db.save(root: root)
        let f = MediaFile(rootID: root.id, relativePath: "test.wav", title: "原文", artists: ["AC/DC", "A & B"], albumArtist: "Various", album: "专辑", codec: "PCM", releaseKey: "edition-A")
        try await db.commitScan(rootID: root.id, files: [f])
        var d = try LyricFormats.plain("未打点\n0秒")
        d.mediaID = f.id; d.rows[1].start = .init(nanoseconds: 0)
        try await db.saveDraft(d, mediaID: f.id)
        let backup = folder.appendingPathComponent("backup.sqlite")
        try await db.backup(to: backup)
        let copy = try LibraryDatabase(url: backup)
        let integrity = try await copy.integrityCheck(); XCTAssertEqual(integrity, "ok")
        let files = try await copy.files(); XCTAssertEqual(files[0].artists, ["AC/DC", "A & B"])
        let restored = try await copy.draft(mediaID: f.id); XCTAssertEqual(restored, d)
        try await db.commitScan(rootID: root.id, files: [])
        let offline = try await db.files(); XCTAssertFalse(offline[0].available)
        let retained = try await db.draft(mediaID: f.id); XCTAssertEqual(retained, d)
        try await db.commitScan(rootID: root.id, files: [f])
        let again = try await db.files(); XCTAssertEqual(again[0].id, f.id); XCTAssertTrue(again[0].available)
    }
    func testActualWAVIncrementalScanAndCancellation() async throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("真实 WAV.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for c in 0..<2 { for i in 0..<4410 { buffer.floatChannelData![c][i] = 0 } }
        try file.write(from: buffer)
        let p = try MediaProbe.detect(url); XCTAssertEqual(p.rate, 44100); XCTAssertEqual(p.channels, 2)
        let root = LibraryRoot(path: folder.path, bookmark: Data())
        let first = try await LibraryScanner.scan(root: root, url: folder, previous: []) { _, _ in }
        XCTAssertEqual(first.count, 1)
        XCTAssertNil(first.first?.audioIdentity, "Import must not read the entire payload")
        let next = try await LibraryScanner.scan(root: root, url: folder, previous: first) { _, _ in }
        XCTAssertEqual(next.first?.id, first.first?.id)
        let task = Task { try await LibraryScanner.scan(root: root, url: folder, previous: first) { _, _ in } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testReadOnlyReferenceExportGuardAndLazyBinding() async throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let music = folder.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let alias = folder.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: music)
        XCTAssertThrowsError(try ReferenceLibraryPolicy.validateExport(music.appendingPathComponent("lyrics.lrc"), musicRoots: [music]))
        XCTAssertThrowsError(try ReferenceLibraryPolicy.validateExport(alias.appendingPathComponent("lyrics.lrc"), musicRoots: [music]))
        XCTAssertNoThrow(try ReferenceLibraryPolicy.validateExport(folder.appendingPathComponent("Music-backup.sqlite"), musicRoots: [music]))
        let db = try LibraryDatabase(url: folder.appendingPathComponent("Library.sqlite"))
        let root = LibraryRoot(path: music.path, bookmark: Data())
        try await db.save(root: root)
        var f = MediaFile(rootID: root.id, relativePath: "test.flac", title: "Test", size: 100, modified: 1)
        try await db.commitScan(rootID: root.id, files: [f])
        try await db.saveAudioIdentity("payload-sha256:test", for: f)
        try await db.commitScan(rootID: root.id, files: [f])
        let unchanged = try await db.files(); XCTAssertEqual(unchanged.first?.audioIdentity,"payload-sha256:test")
        f.modified = 2
        try await db.commitScan(rootID: root.id, files: [f])
        let changed = try await db.files(); XCTAssertNil(changed.first?.audioIdentity)
    }
}
