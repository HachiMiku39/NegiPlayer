import XCTest
import Foundation
import Darwin
import CryptoKit
@testable import MusicEnrichment

final class SensMeApplicationQueueTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SensMeQueue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private final class Tracker: @unchecked Sendable {
        let lock = NSLock()
        var active = 0, maximum = 0, calls = 0
        func start() { lock.lock(); active += 1; calls += 1; maximum = max(active, maximum); lock.unlock() }
        func finish() { lock.lock(); active -= 1; lock.unlock() }
        func snapshot() -> (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (active, maximum, calls) }
    }
    private actor Checkpoints {
        var ids = Set<String>()
        func save(_ outcome: SensMeBatchOutcome, folder: URL) throws {
            let text: String
            switch outcome.value {
            case .analyzed: text = "analyzed"
            case .cached: text = "cached"
            case .failed(let error): text = "failed:" + error
            }
            try Data(text.utf8).write(to: folder.appendingPathComponent(outcome.id + ".checkpoint"), options: .atomic)
            ids.insert(outcome.id)
        }
        var count: Int { ids.count }
    }
    private func fixtureBlob() -> Data {
        Data("STMMSTAEMMLW".utf8) + Data([1,0,128,0,0,0,0,4,1,2,3,4])
    }
    private func sources(_ count: Int) throws -> [SensMeBatchInput] {
        try (0..<count).map { i in
            let source = folder.appendingPathComponent("source-\(i)")
            try Data("original-\(i)".utf8).write(to: source)
            return .init(id: String(i), source: source)
        }
    }
    func testBoundedParallelWorkPersistsFailuresAndContinuesOtherTracks() async throws {
        let inputs = try sources(12), tracker = Tracker(), checkpoints = Checkpoints(), directory = folder!, blob = fixtureBlob()
        let summary = try await SensMeBatchAnalyzer.run(inputs, workers: 3, analyze: { source in
            tracker.start(); defer { tracker.finish() }
            usleep(30_000)
            if source.lastPathComponent == "source-3" { throw EnrichmentError("generated decode failure") }
            return try CachedSensMe(sourceSHA256: SourceDigest.sha256(source), engineVersion: SensMeEngine.version, blob: blob)
        }, checkpoint: { try await checkpoints.save($0, folder: directory) })
        XCTAssertEqual(summary.analyzed, 11); XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.completed, 12); XCTAssertEqual(tracker.snapshot().1, 3)
        let count = await checkpoints.count; XCTAssertEqual(count, 12)
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("3.checkpoint"), encoding: .utf8).hasPrefix("failed:"))
        for input in inputs { XCTAssertEqual(try String(contentsOf: input.source, encoding: .utf8), "original-\(input.id)") }
    }
    func testResumeChecksSourceAndBlobEvenWhenFileMetadataIsPreserved() async throws {
        let inputs = try sources(1), source = try XCTUnwrap(inputs.first).source, tracker = Tracker(), blob = fixtureBlob()
        let cached = try CachedSensMe(sourceSHA256: SourceDigest.sha256(source), engineVersion: SensMeEngine.version, blob: blob)
        let analyze: @Sendable (URL) throws -> CachedSensMe = { url in
            tracker.start(); defer { tracker.finish() }
            return try CachedSensMe(sourceSHA256: SourceDigest.sha256(url), engineVersion: SensMeEngine.version, blob: blob)
        }
        let first = try await SensMeBatchAnalyzer.run([.init(id: "one", source: source, cached: cached)], analyze: analyze, checkpoint: { _ in })
        XCTAssertEqual(first.cached, 1); XCTAssertEqual(tracker.snapshot().2, 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        try Data("modified-0".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(attributes[.modificationDate])], ofItemAtPath: source.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int, attributes[.size] as? Int)
        let changed = try await SensMeBatchAnalyzer.run([.init(id: "one", source: source, cached: cached)], analyze: analyze, checkpoint: { _ in })
        XCTAssertEqual(changed.analyzed, 1)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cached)) as? [String: Any])
        value["sourceSHA256"] = try SourceDigest.sha256(source)
        value["blobSHA256"] = "incorrect"
        let corrupt = try JSONDecoder().decode(CachedSensMe.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertFalse(corrupt.hasValidBlobChecksum)
        let reanalyzed = try await SensMeBatchAnalyzer.run([.init(id: "one", source: source, cached: corrupt)], analyze: analyze, checkpoint: { _ in })
        XCTAssertEqual(reanalyzed.analyzed, 1); XCTAssertEqual(tracker.snapshot().2, 2)
    }
    func testCancellationKeepsCompletedCheckpointsAndStopsScheduling() async throws {
        let inputs = try sources(10), tracker = Tracker(), checkpoints = Checkpoints(), directory = folder!, blob = fixtureBlob()
        let work = Task {
            try await SensMeBatchAnalyzer.run(inputs, workers: 2, analyze: { source in
                tracker.start(); defer { tracker.finish() }
                if source.lastPathComponent != "source-0" {
                    while !Task.isCancelled { usleep(10_000) }
                    throw CancellationError()
                }
                return try CachedSensMe(sourceSHA256: SourceDigest.sha256(source), engineVersion: SensMeEngine.version, blob: blob)
            }, checkpoint: { try await checkpoints.save($0, folder: directory) })
        }
        let deadline = Date().addingTimeInterval(5)
        while await checkpoints.count == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        work.cancel()
        do { _ = try await work.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(tracker.snapshot().0, 0); XCTAssertLessThan(tracker.snapshot().2, 10)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("0.checkpoint"), encoding: .utf8), "analyzed")
    }
    func testCheckpointFailureStopsTheQueue() async throws {
        let inputs = try sources(10), blob = fixtureBlob(), tracker = Tracker()
        do {
            _ = try await SensMeBatchAnalyzer.run(inputs, workers: 1, analyze: { source in
                tracker.start(); defer { tracker.finish() }
                return try CachedSensMe(sourceSHA256: SourceDigest.sha256(source), engineVersion: SensMeEngine.version, blob: blob)
            }, checkpoint: { _ in throw EnrichmentError("generated disk failure") })
            XCTFail("Expected persistence failure")
        } catch { XCTAssertEqual(error.localizedDescription, "generated disk failure") }
        XCTAssertEqual(tracker.snapshot().2, 1)
    }

    private struct RealCase: Decodable, Sendable {
        let id, sourcePath, sourceSHA256, resultSHA256: String
    }
    private struct RealCases: Decodable { let cases: [RealCase] }
    private actor RealResults {
        var rows = [[String: String]]()
        func add(_ row: [String: String]) { rows.append(row) }
        var snapshot: [[String: String]] { rows }
    }
    func testLocalMusicFormatsThroughTheApplicationBatch() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEGI_SENSME_APP_INPUTS"] else {
            throw XCTSkip("Optional private, read-only local music validation")
        }
        let cases = try JSONDecoder().decode(RealCases.self, from: Data(contentsOf: URL(fileURLWithPath: path))).cases
        let expected = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) }), results = RealResults(), directory = folder!
        let summary = try await SensMeBatchAnalyzer.run(cases.map { .init(id: $0.id, source: URL(fileURLWithPath: $0.sourcePath)) }) { outcome in
            let item = try XCTUnwrap(expected[outcome.id])
            switch outcome.value {
            case .analyzed(let result), .cached(let result):
                let hash = SHA256.hash(data: result.blob).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(result.sourceSHA256, item.sourceSHA256, outcome.id)
                XCTAssertEqual(hash, item.resultSHA256, outcome.id)
                XCTAssertTrue(result.hasValidBlobChecksum, outcome.id)
                let key = SHA256.hash(data: Data(outcome.id.utf8)).map { String(format: "%02x", $0) }.joined()
                let checkpoint = directory.appendingPathComponent(key + ".json")
                try JSONEncoder().encode(result).write(to: checkpoint, options: .atomic)
                XCTAssertTrue(try JSONDecoder().decode(CachedSensMe.self, from: Data(contentsOf: checkpoint)).hasValidBlobChecksum)
                await results.add(["id": outcome.id, "sourceSHA256": result.sourceSHA256, "resultSHA256": hash, "engineVersion": result.engineVersion])
            case .failed(let error):
                XCTFail(outcome.id + ": " + error)
                await results.add(["id": outcome.id, "error": error])
            }
        }
        XCTAssertEqual(summary.analyzed, cases.count); XCTAssertEqual(summary.failed, 0)
        if let output = ProcessInfo.processInfo.environment["NEGI_SENSME_APP_REPORT"] {
            let rows = await results.snapshot
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
