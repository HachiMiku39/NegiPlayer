import XCTest
import MediaIO
import LANHost
import LANCore
import LibraryDomain
import AVFoundation

/// Opt-in integration with a locally selected corpus. Paths and media never enter the repository.
final class SelectedLibraryTests: XCTestCase {
    func testReadOnlyLANPCMSelectedFiles() throws {
        
        guard let input=ProcessInfo.processInfo.environment["NEGI_PRESENTATION_REAL_INPUT"] else { throw XCTSkip("Optional selected local music for LAN PCM") }
        let config=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:input)))
        if ProcessInfo.processInfo.environment["NEGI_VERIFY_REAL_LAN_PCM"] != "1" {
            guard let reportPath=ProcessInfo.processInfo.environment["NEGI_NATIVE_LAN_REAL_REPORT"] else { throw XCTSkip("Opt-in real PCM needs decoding service or native app LAN report") }
            let report=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:reportPath))) as? [String:Any]
            let rows=try XCTUnwrap(report?["results"] as? [[String:Any]])
            for key in ["flac","mp3","wav","lyricAudio"] {
                guard let path=config[key] else { continue };let source=URL(fileURLWithPath:path)
                let row=try XCTUnwrap(rows.first{$0["file"] as? String == source.lastPathComponent})
                XCTAssertEqual(row["lanPCMStatus"] as? String,"passed");XCTAssertEqual(row["audioIdentity"] as? String,try AudioIdentity.digest(source))
                XCTAssertGreaterThan(row["lanPCMBytes"] as? Int ?? 0,0);XCTAssertEqual(row["sourceStatUnchanged"] as? Bool,true)
            }
            return
        }
        let root=URL(fileURLWithPath:try XCTUnwrap(config["root"]))
        for key in ["flac","mp3","wav","lyricAudio"] {
            guard let path=config[key] else { continue }; let url=URL(fileURLWithPath:path)
            let before=try FileManager.default.attributesOfItem(atPath:path),probe=try MediaProbe.detect(url)
            let media=MediaFile(rootID:"local-selected",relativePath:url.lastPathComponent,title:"Local selection",codec:probe.codec,sampleRate:probe.rate,channels:probe.channels,available:true)
            let pcm=try PCMSource(entry:CatalogEntry(media:media,root:root,source:url)),independent=try AVAudioFile(forReading:url,commonFormat:.pcmFormatFloat32,interleaved:false)
            let count=AVAudioFrameCount(min(Int64(1024),independent.length-500))
            let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:independent.processingFormat,frameCapacity:count));independent.framePosition=500;try independent.read(into:buffer,frameCount:count)
            let samples=try PCMTransport.decode(pcm.read(start:500*pcm.info.bytesPerFrame,count:Int(count)*Int(pcm.info.bytesPerFrame)),channels:pcm.info.channels)
            let channels=try XCTUnwrap(buffer.floatChannelData)
            for c in 0..<pcm.info.channels { XCTAssertEqual(samples[c],Array(UnsafeBufferPointer(start:channels[c],count:Int(count))),key) }
            let after=try FileManager.default.attributesOfItem(atPath:path)
            for k in [FileAttributeKey.size,.modificationDate,.systemFileNumber] { XCTAssertEqual(String(describing:before[k]),String(describing:after[k]),"Read-only LAN source") }
        }
    }
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
