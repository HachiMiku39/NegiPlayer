import XCTest
import Foundation
import MusicEnrichment
import LibraryDomain
import LibraryStore
import MediaIO
import AppKit

final class EnrichmentTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NegiEnrichment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func testSensMeWithoutTempoStillCachesAndTransfersAnalysis() throws {
        let noTempo = chunk("STBF", Data(repeating: 0, count: 36)) + chunk("STMM", Data([1,2,3,4]))
        let result = try CachedSensMe(sourceSHA256: "source", engineVersion: "test", blob: noTempo)
        XCTAssertNil(result.summary.bpm)
        XCTAssertEqual(try JSONDecoder().decode(CachedSensMe.self, from: JSONEncoder().encode(result)).blob, noTempo)
        let source = folder.appendingPathComponent("no-tempo.mp3"), target = folder.appendingPathComponent("copy-no-tempo.mp3")
        _ = try mp3(source)
        let original = try Data(contentsOf: source)
        try TaggedMusicCopy.write(source: source, destination: target, enrichment: .init(sourceSHA256: SourceDigest.sha256(source), sensme: noTempo))
        XCTAssertNotNil(try Data(contentsOf: target).range(of: noTempo))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testShortNonemptyAudioReachesTheSonyAnalysisBoundaryUnchanged() throws {
        let pcm = Data(repeating: 0, count: 44100 * 4 * 4)
        let fmt = Data([1,0,2,0]) + le(44100) + le(176400) + Data([4,0,16,0])
        let body = Data("WAVEfmt ".utf8) + le(16) + fmt + Data("data".utf8) + le(pcm.count) + pcm
        let source = folder.appendingPathComponent("four-seconds.wav")
        let original = Data("RIFF".utf8) + le(body.count) + body
        try original.write(to: source)
        let output = folder.appendingPathComponent("short.s16le")
        XCTAssertEqual(try SensMePCM.decode(source: source, destination: output), 176400)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: output).count, pcm.count)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func be(_ n: Int, count: Int = 4) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
    private func le(_ n: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
    private func chunk(_ name: String, _ payload: Data) -> Data { Data((name + "STAEMMLW").utf8) + Data([1, 0, 128, 0]) + be(payload.count) + payload }
    private var blob: Data { chunk("GBPM", be(Int(Float(120).bitPattern))) + chunk("STMM", Data([1,2,3,4,5])) }
    private func mp3(_ url: URL, version: UInt8 = 3) throws -> Data {
        // Container-level fixture: unknown ID3 frame plus unchanged MPEG-like payload.
        let payload = Data([255,251,144,100]) + Data(repeating: 17, count: 1024)
        let unknown = Data("PRIV".utf8) + be(7) + Data([0,0]) + Data("kept\0xx".utf8)
        let header = Data("ID3".utf8) + Data([version,0,0,0,0,0,UInt8(unknown.count)])
        try (header + unknown + payload).write(to: url); return payload
    }
    func testSMFMFValidatesFramingAndTempo() throws {
        let result = try SMFMFSummary.parse(blob)
        XCTAssertEqual(result.bpm, 120); XCTAssertEqual(result.chunks.map(\.name), ["GBPM", "STMM"])
        XCTAssertThrowsError(try SMFMFSummary.parse(Data()))
        XCTAssertThrowsError(try SMFMFSummary.parse(blob.dropLast()))
        var corrupt = blob; corrupt[8] = 0
        XCTAssertThrowsError(try SMFMFSummary.parse(corrupt))
        XCTAssertThrowsError(try SMFMFSummary.parse(chunk("GBPM", be(Int(Float(120).bitPattern)))))
        let nan = try SMFMFSummary.parse(chunk("GBPM", be(Int(Float.nan.bitPattern))) + chunk("STMM", Data([0])))
        XCTAssertNil(nan.bpm)
    }
    func testMP3CopyPreservesAudioUnknownTagsAndAddsUnicodeAndSensMe() throws {
        for version: UInt8 in [3,4] {
            let source = folder.appendingPathComponent("source\(version).mp3"), target = folder.appendingPathComponent("copy\(version).mp3")
            let payload = try mp3(source, version: version), original = try Data(contentsOf: source)
            let patch = MetadataPatch(title: "初音未来", artist: "ryo", album: "テスト", track: "3", year: "2008")
            let digest = try SourceDigest.sha256(source)
            try TaggedMusicCopy.write(source: source, destination: target, enrichment: .init(sourceSHA256: digest, sensme: blob, metadata: patch))
            let bytes = try Data(contentsOf: target)
            XCTAssertEqual(bytes.suffix(payload.count), payload); XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertNotNil(bytes.range(of: Data("kept\0xx".utf8))); XCTAssertNotNil(bytes.range(of: Data("USR_SMFMF\0".utf8) + blob))
            XCTAssertNotNil(bytes.range(of: version == 4 ? Data("初音未来".utf8) : "初音未来".data(using: .utf16LittleEndian)!))
            XCTAssertEqual(try AudioIdentity.digest(source), try AudioIdentity.digest(target))
            XCTAssertThrowsError(try TaggedMusicCopy.write(source: source, destination: source, enrichment: .init(sourceSHA256: digest, sensme: blob)))
            XCTAssertThrowsError(try TaggedMusicCopy.write(source: source, destination: target, enrichment: .init(sourceSHA256: digest, sensme: blob)))
        }
    }
    func testFLACCopyPreservesPayloadAndOtherCommentsAndReplacesOldSensMe() throws {
        let source = folder.appendingPathComponent("source.flac"), target = folder.appendingPathComponent("copy.flac")
        let payload = Data([255,248,144,100]) + Data(repeating: 27, count: 2048)
        let comments = ["TITLE=Old", "REPLAYGAIN_TRACK_GAIN=-6 dB", "CUSTOM_FIELD=preserve me"]
        let vorbis = le(4) + Data("test".utf8) + le(comments.count) + comments.reduce(Data()) { $0 + le($1.utf8.count) + Data($1.utf8) }
        let oldBlob = chunk("GBPM", be(Int(Float(90).bitPattern))) + chunk("STMM", Data([8]))
        var original = Data("fLaC".utf8) + Data([0,0,0,34]) + Data(repeating: 0, count: 34)
        original += Data([4]) + be(vorbis.count, count: 3) + vorbis
        original += Data([130]) + be(4 + oldBlob.count, count: 3) + Data("SMFM".utf8) + oldBlob
        original += payload
        try original.write(to: source)
        try TaggedMusicCopy.write(source: source, destination: target, enrichment: .init(sourceSHA256: SourceDigest.sha256(source), sensme: blob, metadata: MetadataPatch(title: "新标题", artist: "初音未来")))
        let bytes = try Data(contentsOf: target)
        XCTAssertEqual(bytes.suffix(payload.count), payload); XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try FLACMetadata.read(target)["title"], ["新标题"])
        XCTAssertNotNil(bytes.range(of: Data("REPLAYGAIN_TRACK_GAIN=-6 dB".utf8)))
        XCTAssertNotNil(bytes.range(of: Data("CUSTOM_FIELD=preserve me".utf8)))
        XCTAssertNotNil(bytes.range(of: Data("SMFM".utf8) + blob)); XCTAssertNil(bytes.range(of: oldBlob))
        XCTAssertEqual(try AudioIdentity.digest(source), try AudioIdentity.digest(target))
    }
    func testStaleAnalysisAndUnsupportedID3AreRejectedWithoutSourceChanges() throws {
        let source = folder.appendingPathComponent("source.mp3"), target = folder.appendingPathComponent("copy.mp3")
        _ = try mp3(source); let digest = try SourceDigest.sha256(source)
        var data = try Data(contentsOf: source); data[data.count-1] = 99; try data.write(to: source)
        XCTAssertThrowsError(try TaggedMusicCopy.write(source: source, destination: target, enrichment: .init(sourceSHA256: digest, sensme: blob)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        data[5] = 128; try data.write(to: source)
        XCTAssertThrowsError(try TaggedMusicCopy.write(source: source, destination: target, enrichment: .init(sourceSHA256: SourceDigest.sha256(source), sensme: blob)))
        XCTAssertEqual(try Data(contentsOf: source), data); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testMetadataOverridePersistsAndNeverPollutesOriginalScanSnapshot() async throws {
        let db = try LibraryDatabase(url: folder.appendingPathComponent("library.sqlite"))
        let root = LibraryRoot(id: "root", path: folder.path, bookmark: Data())
        try await db.save(root: root)
        var original = MediaFile(id: "one", rootID: root.id, relativePath: "song.mp3", title: "Original", artists: ["Original Artist"], album: "Original Album")
        original.tags = ["title": ["Original"]]
        try await db.commitScan(rootID: root.id, files: [original])
        try await db.saveMetadataOverride(.init(title: "Confirmed title", artist: "Confirmed artist"), mediaID: original.id)
        let visible = try await db.files(), raw = try await db.files(applyingOverrides: false)
        XCTAssertEqual(visible.first?.title, "Confirmed title"); XCTAssertEqual(raw.first?.title, "Original")
        try await db.commitScan(rootID: root.id, files: [original])
        let again = try await db.files(), rawAgain = try await db.files(applyingOverrides: false)
        XCTAssertEqual(again.first?.title, "Confirmed title"); XCTAssertEqual(rawAgain.first?.tags["title"], ["Original"])
    }
    func testProcessDeadlineAndCancellation() async throws {
        let job = folder.appendingPathComponent("timeout")
        let start = Date()
        XCTAssertThrowsError(try EnrichmentProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], job: job, timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let cancelledJob = folder.appendingPathComponent("cancelled")
        let work = Task.detached { try EnrichmentProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], job: cancelledJob, timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000); work.cancel()
        do { try await work.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCredentialImporterRejectsUnknownExecutable() throws {
        let source = folder.appendingPathComponent("unverified.exe"), target = folder.appendingPathComponent("private.json")
        try Data("not an installer".utf8).write(to: source)
        XCTAssertThrowsError(try MediaGoCredentials.importExecutable(source, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    private func cover(_ red: CGFloat) throws -> EnrichmentArtwork {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for x in 0..<12 { for y in 0..<8 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = UInt8(red * 255); pixels[offset + 1] = 64; pixels[offset + 2] = 76; pixels[offset + 3] = 255
        } }
        return try EnrichmentArtwork(data: XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
    }
    func testLegacyMetadataAndSelectiveExtendedFields() throws {
        let legacy = try JSONDecoder().decode(MetadataPatch.self, from: Data(#"{"title":"Old","artist":"Artist","album":"Album","track":"1","disc":"1","year":"2000","genre":"Pop","gracenoteID":""}"#.utf8))
        XCTAssertTrue(legacy.additionalFields.isEmpty)
        let patch = MetadataPatch(title: "Replacement", year: "1982", additionalFields: ["LABEL":"Epic", "ALBUMARTIST":"Album Artist", "TRACKTOTAL":"9"])
        let selected = patch.selecting([.year, .label])
        let original = MediaFile(rootID: "root", relativePath: "song.mp3", title: "Keep title", artists: ["Keep artist"])
        let result = selected.applying(to: original)
        XCTAssertEqual(result.title, "Keep title"); XCTAssertEqual(result.artists, ["Keep artist"])
        XCTAssertEqual(result.tags["date"], ["1982"]); XCTAssertEqual(result.tags["label"], ["Epic"])
        XCTAssertEqual(selected.vorbisFields, ["DATE":"1982", "LABEL":"Epic"])
        XCTAssertEqual(legacy.merging(selected).title, "Old")
    }
    func testCoverValidationAndContentURLs() throws {
        let image = try cover(0.7)
        XCTAssertEqual(image.width, 12); XCTAssertEqual(image.height, 8); XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertThrowsError(try EnrichmentArtwork(data: Data("not an image".utf8)))
        XCTAssertThrowsError(try EnrichmentArtwork(data: Data(repeating: 0, count: EnrichmentArtwork.maximumBytes + 1)))
        XCTAssertEqual(try GracenoteArtworkDownload.validatedURL("akamai-b.cdn.cddbp.net/cds/2.0/cover/a.jpg").scheme, "https")
        for address in ["file:///tmp/a.jpg", "http://127.0.0.1/cds/a", "https://a.cddbp.net.evil.test/cds/a", "https://user:secret@a.cddbp.net/cds/a", "https://a.cddbp.net:8888/cds/a"] {
            XCTAssertThrowsError(try GracenoteArtworkDownload.validatedURL(address))
        }
    }
    func testExtendedMP3TagsAndSelectedCoverReplaceOnlyNewCopies() throws {
        for version: UInt8 in [3, 4] {
            let source = folder.appendingPathComponent("cover-source\(version).mp3"), first = folder.appendingPathComponent("cover-first\(version).mp3"), second = folder.appendingPathComponent("cover-second\(version).mp3")
            _ = try mp3(source, version: version); let digest = try SourceDigest.sha256(source)
            let art = try cover(0.7), replacement = try cover(0.2)
            let patch = MetadataPatch(track: "6", disc: "1", year: "1982", additionalFields: ["ALBUMARTIST":"Michael Jackson", "TRACKTOTAL":"9", "DISCTOTAL":"1", "LABEL":"Epic", "BARCODE":"12345", "COMPOSER":"Composer"])
            try TaggedMusicCopy.write(source: source, destination: first, enrichment: .init(sourceSHA256: digest, metadata: patch, artwork: art))
            XCTAssertEqual(try EmbeddedArtwork.read(first), art.data)
            let data = try Data(contentsOf: first)
            for frame in ["TPE2", "TRCK", "TPOS", "TPUB", "TCOM", "TXXX"] { XCTAssertNotNil(data.range(of: Data(frame.utf8))) }
            let trackText = version == 4 ? Data("6/9".utf8) : "6/9".data(using: .utf16LittleEndian)!
            XCTAssertNotNil(data.range(of: trackText))
            try TaggedMusicCopy.write(source: first, destination: second, enrichment: .init(sourceSHA256: SourceDigest.sha256(first), metadata: .init(year: "2001", additionalFields:["TRACKTOTAL":"12"]), artwork: replacement))
            XCTAssertEqual(try EmbeddedArtwork.read(second), replacement.data)
            XCTAssertNil(try Data(contentsOf: second).range(of: art.data))
            XCTAssertEqual(try SourceDigest.sha256(source), digest)
            XCTAssertEqual(try AudioIdentity.digest(source), try AudioIdentity.digest(second))
            let combined = version == 4 ? Data("6/12".utf8) : "6/12".data(using: .utf16LittleEndian)!
            XCTAssertNotNil(try Data(contentsOf: second).range(of: combined))
        }
    }
    func testFLACExtendedFieldsAndCoverRoundTrip() throws {
        let source = folder.appendingPathComponent("bare.flac"), first = folder.appendingPathComponent("art.flac"), second = folder.appendingPathComponent("art2.flac")
        let original = Data("fLaC".utf8) + Data([128,0,0,34]) + Data(repeating: 0, count: 34) + Data([255,248,144,100,1,2,3])
        try original.write(to: source)
        let art = try cover(0.7), replacement = try cover(0.2)
        try TaggedMusicCopy.write(source: source, destination: first, enrichment: .init(sourceSHA256: SourceDigest.sha256(source), metadata: .init(year:"1982",additionalFields:["LABEL":"Epic", "TRACKTOTAL":"9"]), artwork: art))
        XCTAssertEqual(try EmbeddedArtwork.read(first), art.data)
        XCTAssertEqual(try FLACMetadata.read(first)["LABEL"], ["Epic"])
        try TaggedMusicCopy.write(source: first, destination: second, enrichment: .init(sourceSHA256: SourceDigest.sha256(first), artwork: replacement))
        XCTAssertEqual(try EmbeddedArtwork.read(second), replacement.data)
        XCTAssertEqual(try FLACMetadata.read(second)["DATE"], ["1982"])
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try AudioIdentity.digest(source), try AudioIdentity.digest(second))
    }
    func testRealAlbumDetailsAndCover() async throws {
        let runtime = try configuredRuntime()
        guard let path = ProcessInfo.processInfo.environment["NEGI_TEST_MEDIA_GO"] else { throw XCTSkip("Optional real album cover query") }
        let credentials = folder.appendingPathComponent("Private/credentials.json")
        try MediaGoCredentials.importExecutable(URL(fileURLWithPath: path), to: credentials)
        let response = try GracenoteEngine.query(title:"Billie Jean",artist:"Michael Jackson",album:"Thriller",runtime:runtime,credentials:credentials,workingDirectory:folder.appendingPathComponent("Jobs"))
        let candidate = try XCTUnwrap(response.candidates.first { $0.metadata.album == "Thriller" && !$0.covers.isEmpty })
        let detail = try GracenoteEngine.query(title:candidate.metadata.title,artist:candidate.metadata.artist,album:candidate.metadata.album,runtime:runtime,credentials:credentials,workingDirectory:folder.appendingPathComponent("Jobs"),detail:candidate)
        let full = try XCTUnwrap(detail.candidates.first)
        XCTAssertEqual(full.fullResult, true); XCTAssertEqual(full.metadata.year, "1982")
        XCTAssertEqual(full.metadata[.label], "Epic"); XCTAssertEqual(full.metadata[.trackTotal], "9")
        XCTAssertFalse(full.metadata.genre.isEmpty)
        let asset = try XCTUnwrap(full.covers.first { $0.width == 720 })
        let art = try await GracenoteArtworkDownload.download(asset)
        XCTAssertEqual(art.width,720); XCTAssertEqual(art.height,720)
        print("REAL album details: year 1982, Epic, track \(full.metadata.track)/\(full.metadata[.trackTotal]), genre \(full.metadata.genre), HTTPS cover \(art.width)x\(art.height), \(art.data.count) bytes; credentials withheld")
    }
    private func configuredRuntime() throws -> EnrichmentRuntime {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NEGI_TEST_ENGINE_HOME"], let helpers = env["NEGI_TEST_ENGINE_HELPERS"] else { throw XCTSkip("Optional real Gracenote SDK verification") }
        return .init(directory: URL(fileURLWithPath: path), prefix: env["NEGI_TEST_ENGINE_PREFIX"].map { URL(fileURLWithPath: $0) } ?? folder.appendingPathComponent("WinePrefix"), helpers: URL(fileURLWithPath: helpers))
    }
    func testNativeSensMeStreamsGeneratedWAVWithoutExternalRuntime() throws {
        let rate = 48000, seconds = 40
        var pcm = Data(capacity: rate * seconds * 2)
        for i in 0..<rate*seconds {
            let t = Double(i) / Double(rate), phase = t.truncatingRemainder(dividingBy: 0.5)
            let value = Int16(15000 * exp(-phase * 42) * (sin(2 * .pi * 110 * t) + 0.35 * sin(2 * .pi * 330 * t)))
            pcm.append(UInt8(truncatingIfNeeded: value)); pcm.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        let fmt = Data([1,0,1,0]) + le(rate) + le(rate*2) + Data([2,0,16,0])
        let body = Data("WAVEfmt ".utf8) + le(16) + fmt + Data("data".utf8) + le(pcm.count) + pcm
        let source = folder.appendingPathComponent("rhythm.wav"); try (Data("RIFF".utf8) + le(body.count) + body).write(to: source)
        let before = try SourceDigest.sha256(source)
        let result = try SensMeEngine.analyze(source: source)
        XCTAssertEqual(result.summary.bpm ?? 0, 120, accuracy: 1); XCTAssertEqual(result.sourceSHA256, before)
        XCTAssertEqual(try SourceDigest.sha256(source), before); XCTAssertEqual(result.engineVersion, SensMeEngine.version)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Jobs").path))
        print("Native SensMe: generated 48k mono WAV -> streamed 44.1k stereo, BPM \(result.summary.bpm ?? 0), \(result.summary.bytes) SMFMF bytes; no external runtime or PCM file")
    }
    func testRealGracenoteMediaGoAuthorizationAndPublicQuery() throws {
        let runtime = try configuredRuntime()
        guard let path = ProcessInfo.processInfo.environment["NEGI_TEST_MEDIA_GO"] else { throw XCTSkip("Optional local Media Go executable for authorization") }
        let credentials = folder.appendingPathComponent("Private/credentials.json")
        try MediaGoCredentials.importExecutable(URL(fileURLWithPath: path), to: credentials)
        let permissions = try FileManager.default.attributesOfItem(atPath: credentials.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let response = try GracenoteEngine.query(title: "Billie Jean", artist: "Michael Jackson", runtime: runtime, credentials: credentials, workingDirectory: folder.appendingPathComponent("Jobs"))
        XCTAssertTrue(response.ready); XCTAssertFalse(response.candidates.isEmpty)
        XCTAssertTrue(response.candidates.contains { $0.metadata.album == "Thriller" && $0.metadata.artist == "Michael Jackson" })
        print("REAL Gracenote: SDK \(response.sdkVersion), public text query returned \(response.candidates.count) candidates; credentials withheld")
    }
    func testRealGeneratedMP3AndFLACTaggedCopiesRemainPlayable() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEGI_TEST_TAG_FIXTURES"], let blobPath = ProcessInfo.processInfo.environment["NEGI_TEST_SMFMF"] else { throw XCTSkip("Optional generated codec fixtures") }
        let realBlob = try Data(contentsOf: URL(fileURLWithPath: blobPath))
        for ext in ["mp3", "flac"] {
            let source = URL(fileURLWithPath: path).appendingPathComponent("rhythm." + ext), target = folder.appendingPathComponent("tagged." + ext)
            let before = try MediaProbe.detect(source), digest = try SourceDigest.sha256(source)
            try TaggedMusicCopy.write(source: source, destination: target, enrichment: .init(sourceSHA256: digest, sensme: realBlob, metadata: .init(title: "初音テスト", artist: "NegiPlayer", album: "Generated Test", track: "3", year: "2026", additionalFields:["ALBUMARTIST":"Album Artist", "LABEL":"Test Label", "TRACKTOTAL":"9"]), artwork: cover(0.7)))
            let after = try MediaProbe.detect(target)
            XCTAssertEqual(before.codec, after.codec); XCTAssertEqual(before.rate, after.rate); XCTAssertEqual(before.duration, after.duration, accuracy: 0.001)
            let tags = await MediaProbe.metadata(target)
            XCTAssertEqual(tags["title"]?.first, "初音テスト")
            XCTAssertEqual(try EmbeddedArtwork.read(target), try cover(0.7).data)
            XCTAssertEqual(try SourceDigest.sha256(source), digest)
            XCTAssertEqual(try AudioIdentity.digest(source), try AudioIdentity.digest(target))
            print("REAL tagged \(ext): Unicode title read back, source intact, duration \(after.duration)s")
        }
    }
}
