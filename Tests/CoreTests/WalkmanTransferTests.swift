import XCTest
import FileOperations

final class WalkmanTransferTests: XCTestCase {
    private var folder: URL!
    private var music: URL { folder.appendingPathComponent("Device/MUSIC") }
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NegiTransfer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Device"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func source(_ name: String = "song.flac", data: Data = Data("original music and tags".utf8), relative: String = "艺人/专辑/song.flac") throws -> MusicTransferItem {
        let url = folder.appendingPathComponent(name); try data.write(to: url)
        return try MusicTransferItem(source: url, relativePath: relative)
    }
    private func transfer(_ items: [MusicTransferItem], policy: TransferCollisionPolicy = .skipExisting) async throws -> MusicTransferResult {
        try await MusicTransfer.run(items: items, musicDirectory: music, policy: policy, validateDestination: { Int64.max }, progress: { _ in })
    }
    private func partialFiles() throws -> [String] {
        (FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".part") }
    }
    func testCopyPreservesOriginalBytesAndHierarchy() async throws {
        let data = Data((0..<2_600_000).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let item = try source(data: data)
        let result = try await transfer([item])
        XCTAssertEqual(result.copied, 1); XCTAssertEqual(result.bytes, Int64(data.count))
        XCTAssertEqual(try Data(contentsOf: music.appendingPathComponent(item.relativePath)), data)
        XCTAssertEqual(try Data(contentsOf: item.source), data)
        XCTAssertEqual(try partialFiles(), [])
    }
    func testCollisionSkipsOrKeepsBothWithoutOverwriting() async throws {
        let first = try source(data: Data("existing".utf8))
        _ = try await transfer([first])
        let second = try source("different.flac", data: Data("new track".utf8))
        let skipped = try await transfer([second]); XCTAssertEqual(skipped.skipped, 1); XCTAssertEqual(skipped.copied, 0)
        XCTAssertEqual(try Data(contentsOf: music.appendingPathComponent(first.relativePath)), Data("existing".utf8))
        let copied = try await transfer([second], policy: .keepBoth); XCTAssertEqual(copied.copied, 1)
        XCTAssertEqual(try Data(contentsOf: music.appendingPathComponent("艺人/专辑/song (2).flac")), Data("new track".utf8))
    }
    func testCancellationKeepsCompletedFilesAndRemovesPartial() async throws {
        let first = try source("first.mp3", relative: "Album/first.mp3")
        let second = try source("second.mp3", data: Data(repeating: 7, count: 3_000_000), relative: "Album/second.mp3")
        let directory = music
        let work = Task {
            try await MusicTransfer.run(items: [first, second], musicDirectory: directory, validateDestination: { Int64.max }) { p in
                if p.filename.hasSuffix("second.mp3"), p.completedBytes > first.size * 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await work.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: music.appendingPathComponent("Album/first.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: music.appendingPathComponent("Album/second.mp3").path))
        XCTAssertEqual(try partialFiles(), [])
    }
    func testUnplugDoesNotRecreateMissingDevicePath() async throws {
        let item = try source(data: Data(repeating: 2, count: 2_500_000))
        let device = folder.appendingPathComponent("Device")
        do {
            _ = try await MusicTransfer.run(items: [item], musicDirectory: music, validateDestination: {
                guard FileManager.default.fileExists(atPath: device.path) else { throw MusicTransferError("Device disconnected") }
                return Int64.max
            }) { p in
                if p.completedBytes == 1_048_576 { try? FileManager.default.removeItem(at: device) }
            }
            XCTFail("Expected disconnect")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disconnected")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: device.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.source.path))
    }
    func testInsufficientSpaceDoesNotCreateMusicDirectory() async throws {
        let item = try source()
        do {
            _ = try await MusicTransfer.run(items: [item], musicDirectory: music, validateDestination: { 1 }, progress: { _ in })
            XCTFail("Expected capacity error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("空间不足")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: music.path))
    }
    func testPathTraversalAndSymlinkEscapeAreRejected() async throws {
        for path in ["../outside.mp3", "/outside.mp3", "Album/../../outside.mp3", "Album//song.mp3"] {
            XCTAssertThrowsError(try MusicTransfer.safeRelativePath(path))
        }
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let outside = folder.appendingPathComponent("Outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: music.appendingPathComponent("艺人"), withDestinationURL: outside)
        do { _ = try await transfer([source()]); XCTFail("Expected symlink rejection") } catch { XCTAssertTrue(error.localizedDescription.contains("符号链接")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testSourceChangeBeforeOrDuringCopyIsRejected() async throws {
        let item = try source(data: Data(repeating: 3, count: 2_500_000))
        do {
            _ = try await MusicTransfer.run(items: [item], musicDirectory: music, validateDestination: { Int64.max }) { p in
                if p.completedBytes == 1_048_576 { try? Data("changed".utf8).write(to: item.source) }
            }
            XCTFail("Expected source mutation error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("源文件改变")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: music.appendingPathComponent(item.relativePath).path))
        XCTAssertEqual(try partialFiles(), [])
        do { _ = try await transfer([item]); XCTFail("Expected stale selection error") } catch { XCTAssertTrue(error.localizedDescription.contains("源文件已改变")) }
    }
    func testVerificationDetectsDamagedCopy() async throws {
        let item = try source(data: Data(repeating: 1, count: 2_000_000))
        let directory = music
        do {
            _ = try await MusicTransfer.run(items: [item], musicDirectory: directory, validateDestination: { Int64.max }) { p in
                if p.phase == .copying, p.completedBytes == item.size,
                   let paths = FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String],
                   let temporary = paths.first(where: { $0.hasSuffix(".part") }) {
                    let url = directory.appendingPathComponent(temporary)
                    if let file = try? FileHandle(forWritingTo: url) { try? file.write(contentsOf: Data([255])); try? file.close() }
                }
            }
            XCTFail("Expected verification error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("校验失败")) }
        XCTAssertEqual(try partialFiles(), [])
    }
    func testPortableNamesPreserveUnicodeAndExtension() throws {
        XCTAssertEqual(try MusicTransfer.safeRelativePath("初音未来/Album:Live?/CON.flac"), "初音未来/Album_Live_/_CON.flac")
        let long = try MusicTransfer.safeRelativePath(String(repeating: "初音", count: 120) + ".flac")
        XCTAssertTrue(long.hasSuffix(".flac")); XCTAssertLessThanOrEqual(long.utf16.count, 180)
    }
    func testOfflineDirectoryIsNotTreatedAsMountedDevice() throws {
        XCTAssertThrowsError(try WalkmanVolume.inspect(folder.appendingPathComponent("Device")))
    }
    func testSourceAlreadyOnTargetIsRejected() async throws {
        let item = try source(); _ = try await transfer([item])
        let onDevice = try MusicTransferItem(source: music.appendingPathComponent(item.relativePath), relativePath: "Again/song.flac")
        do { _ = try await transfer([onDevice]); XCTFail("Expected target source rejection") } catch { XCTAssertTrue(error.localizedDescription.contains("已在目标")) }
    }
    func testConnectedDeviceDiscoveryReadOnly() throws {
        let volumes = WalkmanVolume.discover()
        let expected = ["WALKMAN", "SDCARD"].filter { FileManager.default.fileExists(atPath: "/Volumes/\($0)/default-capability.xml") }
        for name in expected {
            let volume = try XCTUnwrap(volumes.first { $0.name == name })
            XCTAssertEqual(volume.isCard, name == "SDCARD"); XCTAssertGreaterThan(try volume.validateMounted(), 0)
            XCTAssertTrue(volume.extensions.contains("flac")); XCTAssertFalse(volume.extensions.contains("lrc"))
            print("READ-ONLY Walkman discovery: \(volume.name), \(volume.model), available \(volume.availableBytes) bytes")
        }
    }
}
