import XCTest
import MediaIO

/// Opt-in integration with a locally selected corpus. Paths and media never enter the repository.
final class SelectedLibraryTests: XCTestCase {
    func testReadOnlyArtworkLyricsAndSACDHeaders() async throws {
        guard let input = ProcessInfo.processInfo.environment["NEGI_PRESENTATION_REAL_INPUT"] else {
            throw XCTSkip("Optional: set NEGI_PRESENTATION_REAL_INPUT to local JSON with root, flac, mp3, lyricAudio, sacd and optional wav paths")
        }
        let config = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:input)))
        func url(_ key: String) throws -> URL { URL(fileURLWithPath:try XCTUnwrap(config[key])) }
        let root = try url("root"), flac = try url("flac"), mp3 = try url("mp3"), audio = try url("lyricAudio"), sacd = try url("sacd")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("negi-selected-cache-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let wav = config["wav"].map { URL(fileURLWithPath:$0) }
        let sources = [flac,mp3,audio,sacd]+(wav.map { [$0]+ArtworkRepository.folderCandidates(for:$0,root:root) } ?? [])
        let before = try sources.map { try FileManager.default.attributesOfItem(atPath:$0.path) }
        XCTAssertNotNil(try EmbeddedArtwork.read(flac)); XCTAssertNotNil(try EmbeddedArtwork.read(mp3))
        if let wav {
            let artwork = await ArtworkRepository(cacheDirectory:cache).artwork(sources:[wav],root:root)
            XCTAssertNotNil(artwork)
        }
        let lyrics = try XCTUnwrap(SidecarLyrics.load(for:audio,title:audio.deletingPathExtension().lastPathComponent,root:root))
        XCTAssertFalse(lyrics.document.rows.isEmpty); XCTAssertNotNil(lyrics.document.rows.first?.start)
        let lrc = audio.deletingLastPathComponent().appendingPathComponent(lyrics.filename)
        let originalLRC = try Data(contentsOf:lrc)
        _ = try SidecarLyrics.load(for:audio,title:audio.deletingPathExtension().lastPathComponent,root:root)
        XCTAssertEqual(try Data(contentsOf:lrc),originalLRC)
        XCTAssertEqual(try DiscImageProbe.inspect(sacd).kind,"SACD ISO")
        for (i,source) in sources.enumerated() {
            let after = try FileManager.default.attributesOfItem(atPath:source.path)
            for key in [FileAttributeKey.size,.modificationDate,.systemFileNumber] {
                XCTAssertEqual(String(describing:after[key]),String(describing:before[i][key]),"Read-only integration source stat")
            }
        }
    }
}
