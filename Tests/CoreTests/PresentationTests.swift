import XCTest
import MediaIO
import LibraryDomain
import LyricCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class PresentationTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("negi-presentation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    private func be(_ n: Int, _ bytes: Int = 4) -> Data { Data((0..<bytes).reversed().map { UInt8((n >> ($0*8)) & 255) }) }
    private func le(_ n: Int, _ bytes: Int = 4) -> Data { Data((0..<bytes).map { UInt8((n >> ($0*8)) & 255) }) }
    private func sync(_ n: Int) -> Data { Data((0..<4).reversed().map { UInt8((n >> ($0*7)) & 127) }) }
    private func picture(_ red: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data:nil,width:2,height:1,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:red,green:0.4,blue:1-red,alpha:1)); context.fill(CGRect(x:0,y:0,width:2,height:1))
        let image = try XCTUnwrap(context.makeImage()); let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(dest,image,nil); XCTAssertTrue(CGImageDestinationFinalize(dest)); return data as Data
    }
    private func flacPicture(_ image: Data, type: Int) -> Data {
        let mime = Data("image/png".utf8)
        return be(type)+be(mime.count)+mime+be(0)+be(2)+be(1)+be(24)+be(0)+be(image.count)+image
    }
    private func flac(_ pictures: [(Data,Int)]) -> Data {
        var out = Data("fLaC".utf8)
        for (i,item) in pictures.enumerated() {
            let block = flacPicture(item.0,type:item.1)
            out += Data([i == pictures.count-1 ? 0x86 : 6])+be(block.count,3)+block
        }
        return out
    }
    private func id3(_ pictures: [(Data,Int)], version: UInt8 = 3, utf16: Bool = false) -> Data {
        var frames = Data()
        for item in pictures {
            let description = utf16 ? Data([0xff,0xfe,0x41,0,0,0]) : Data([0])
            let body = Data([utf16 ? 1 : 0])+Data(version == 2 ? "PNG".utf8 : "image/png\0".utf8)+Data([UInt8(item.1)])+description+item.0
            if version == 2 { frames += Data("PIC".utf8)+be(body.count,3)+body }
            else { frames += Data("APIC".utf8)+(version == 4 ? sync(body.count) : be(body.count))+Data([0,0])+body }
        }
        return Data("ID3".utf8)+Data([version,0,0])+sync(frames.count)+frames
    }
    private func atom(_ type: String, _ payload: Data) -> Data { be(payload.count+8)+Data(type.utf8)+payload }

    func testEmbeddedFrontPicturePriorityAndID3Versions() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let back = try picture(1), front = try picture(0)
        let flacURL = dir.appendingPathComponent("album.flac")
        try flac([(back,4),(front,3)]).write(to:flacURL)
        XCTAssertEqual(try EmbeddedArtwork.read(flacURL),front)
        for version in [UInt8(2),3,4] {
            let url = dir.appendingPathComponent("v\(version).mp3")
            try id3([(back,4),(front,3)],version:version,utf16:version != 2).write(to:url)
            XCTAssertEqual(try EmbeddedArtwork.read(url),front,"ID3 v2.\(version)")
        }
        let thumbnail = try XCTUnwrap(EmbeddedArtwork.thumbnail(front))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData,nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src,0,nil))
        XCTAssertEqual(img.width,2); XCTAssertEqual(img.height,1,"Keep non-square artwork without cropping")
    }
    func testWAVDSFAndM4ACoverContainers() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let cover = try picture(0.3), tag = id3([(cover,3)])
        let riffBody = Data("WAVEdata".utf8)+le(4)+Data([0,0,0,0])+Data("id3 ".utf8)+le(tag.count)+tag+(tag.count % 2 == 1 ? Data([0]) : Data())
        let wav = dir.appendingPathComponent("cover.wav")
        try (Data("RIFF".utf8)+le(riffBody.count)+riffBody).write(to:wav)
        XCTAssertEqual(try EmbeddedArtwork.read(wav),cover)
        let dsf = dir.appendingPathComponent("cover.dsf")
        try (Data("DSD ".utf8)+le(28,8)+le(28+tag.count,8)+le(28,8)+tag).write(to:dsf)
        XCTAssertEqual(try EmbeddedArtwork.read(dsf),cover)
        let m4a = dir.appendingPathComponent("cover.m4a")
        let metadata = atom("moov",atom("udta",atom("meta",Data(repeating:0,count:4)+atom("ilst",atom("covr",atom("data",be(14)+be(0)+cover))))))
        try (atom("mdat",Data(repeating:0xff,count:12000))+metadata).write(to:m4a)
        XCTAssertEqual(try EmbeddedArtwork.read(m4a),cover,"Skip audio payload and read covr/data")
    }
    func testTruncatedAndOversizeArtworkIsRejected() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("bad.mp3")
        try (Data("ID3".utf8)+Data([3,0,0])+sync(EmbeddedArtwork.maximumBytes+1)).write(to:url)
        XCTAssertNil(try EmbeddedArtwork.read(url))
        try Data(id3([(try picture(0.5),3)]).dropLast()).write(to:url)
        XCTAssertNil(try EmbeddedArtwork.read(url))
        let badFLAC = dir.appendingPathComponent("bad.flac")
        try (Data("fLaC".utf8)+Data([0x86,0xff,0xff,0xff])).write(to:badFLAC)
        XCTAssertNil(try EmbeddedArtwork.read(badFLAC))
        XCTAssertNil(EmbeddedArtwork.thumbnail(Data([0,1,2,3])))
    }
    func testAlbumFallbackCacheInvalidationAndReadOnlySources() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let root = dir.appendingPathComponent("Music"), cache = dir.appendingPathComponent("Cache")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let wav = root.appendingPathComponent("01.wav"), track = root.appendingPathComponent("02.flac"), folder = root.appendingPathComponent("CoVeR.PNG")
        let red = try picture(1), blue = try picture(0)
        try Data("no embedded art".utf8).write(to:wav); try flac([(blue,3)]).write(to:track); try red.write(to:folder)
        let before = try [wav,track,folder].map { (try Data(contentsOf:$0),try $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) }
        let repository = ArtworkRepository(cacheDirectory:cache)
        let embedded = await repository.artwork(sources:[wav,track],root:root)
        XCTAssertEqual(embedded?.data,EmbeddedArtwork.thumbnail(blue),"Other tracks in this release precede folder art")
        let fallback = await repository.artwork(sources:[wav],root:root)
        XCTAssertEqual(fallback?.data,EmbeddedArtwork.thumbnail(red))
        let cached = await ArtworkRepository(cacheDirectory:cache).artwork(sources:[wav],root:root)
        XCTAssertEqual(cached?.data,fallback?.data); XCTAssertEqual(cached?.source,"本机封面缓存")
        for (i,url) in [wav,track,folder].enumerated() {
            XCTAssertEqual(try Data(contentsOf:url),before[i].0)
            XCTAssertEqual(try url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,before[i].1)
        }
        try blue.write(to:folder)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:5)],ofItemAtPath:folder.path)
        let changed = await repository.artwork(sources:[wav],root:root)
        XCTAssertEqual(changed?.data,EmbeddedArtwork.thumbnail(blue))
        let date = try folder.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate!
        try red.write(to:folder); try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:folder.path)
        await repository.invalidate(musicRoots:[root])
        let refreshed = await repository.artwork(sources:[wav],root:root)
        XCTAssertEqual(refreshed?.data,EmbeddedArtwork.thumbnail(red),"Explicit refresh reloads even when an editor preserves mtime")
        let files = try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)
        XCTAssertFalse(files.isEmpty); XCTAssertTrue(files.allSatisfy { $0.deletingPathExtension().lastPathComponent.count == 64 })
    }
    func testFolderDiscParentAndSecurityBoundary() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let root = dir.appendingPathComponent("Music"), disc = root.appendingPathComponent("Album/Disc 1")
        try FileManager.default.createDirectory(at:disc,withIntermediateDirectories:true)
        let wav = disc.appendingPathComponent("song.wav"), cover = disc.deletingLastPathComponent().appendingPathComponent("Folder.PNG")
        try Data().write(to:wav); try picture(0.5).write(to:cover)
        XCTAssertEqual(ArtworkRepository.folderCandidates(for:wav,root:root).map { $0.resolvingSymlinksInPath().path },[cover.resolvingSymlinksInPath().path])
        XCTAssertTrue(ArtworkRepository.folderCandidates(for:wav,root:disc).isEmpty,"Do not enumerate a parent outside the selected root")
        let outside = dir.appendingPathComponent("outside.png"); try picture(0).write(to:outside)
        try FileManager.default.createSymbolicLink(at:disc.appendingPathComponent("cover.png"),withDestinationURL:outside)
        XCTAssertEqual(ArtworkRepository.folderCandidates(for:wav,root:root).map { $0.resolvingSymlinksInPath().path },[cover.resolvingSymlinksInPath().path],"Escaped symlink is ignored")
        let unsafeCache = root.appendingPathComponent("Cache")
        let artwork = await ArtworkRepository(cacheDirectory:unsafeCache).artwork(sources:[wav],root:root)
        XCTAssertNotNil(artwork); XCTAssertFalse(FileManager.default.fileExists(atPath:unsafeCache.path),"Never write cache into referenced music")
        await ArtworkRepository(cacheDirectory:disc.deletingLastPathComponent()).invalidate(musicRoots:[root])
        XCTAssertTrue(FileManager.default.fileExists(atPath:cover.path),"Cache refresh does not delete source artwork")
        let escaped = await ArtworkRepository(cacheDirectory:dir.appendingPathComponent("Cache")).artwork(sources:[outside],root:root)
        XCTAssertNil(escaped)
    }
    func testSidecarFilenamePriorityUnicodeOffsetAndClickTime() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let audio = dir.appendingPathComponent("01 初音.flac"), lrc = dir.appendingPathComponent("01 初音.LRC")
        let text = "[offset:-250]\r\n[00:04.000]未来 é 🌱\r\n[00:00.000]初音ミク\r\n"
        try (Data([0xff,0xfe])+text.data(using:.utf16LittleEndian)!).write(to:lrc)
        try Data("[00:00]Other title".utf8).write(to:dir.appendingPathComponent("Title.lrc"))
        let before = try Data(contentsOf:lrc)
        let result = try XCTUnwrap(SidecarLyrics.load(for:audio,title:"Title",root:dir))
        XCTAssertEqual(result.filename,lrc.lastPathComponent)
        XCTAssertEqual(result.document.rows.map(\.text),["初音ミク","未来 é 🌱"])
        XCTAssertEqual(result.document.displayTime(result.document.rows[1].start!).seconds,3.75)
        XCTAssertEqual(result.document.activeRow(at:3.8),result.document.rows[1].id)
        XCTAssertEqual(try Data(contentsOf:lrc),before,"LRC read is not an editor write")
    }
    func testSidecarExactTitleOnlyMalformedAndSymlink() throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        let root = dir.appendingPathComponent("Music"); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let audio = root.appendingPathComponent("track.wav"), title = root.appendingPathComponent("Song.lrc")
        try Data("[00:01]Matched title".utf8).write(to:title)
        XCTAssertEqual(try SidecarLyrics.load(for:audio,title:"song",root:root)?.document.rows.first?.text,"Matched title")
        XCTAssertNil(try SidecarLyrics.load(for:audio,title:"unrelated",root:root))
        let outside = dir.appendingPathComponent("outside.lrc"); try Data("[00:01]Outside".utf8).write(to:outside)
        let exact = root.appendingPathComponent("track.lrc"); try FileManager.default.createSymbolicLink(at:exact,withDestinationURL:outside)
        XCTAssertNil(try SidecarLyrics.load(for:audio,title:"unrelated",root:root))
        try FileManager.default.removeItem(at:exact); try Data("no timestamps".utf8).write(to:exact)
        XCTAssertThrowsError(try SidecarLyrics.load(for:audio,title:"song",root:root))
    }
    func testISOHeaderRecognitionAndIndependentScan() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at:dir) }
        var sacd = Data(repeating:0,count:511*2048); sacd.replaceSubrange(510*2048..<510*2048+8,with:Data("SACDMTOC".utf8))
        let url = dir.appendingPathComponent("SACD.iso"); try sacd.write(to:url)
        XCTAssertEqual(try DiscImageProbe.inspect(url).kind,"SACD ISO")
        var dataISO = Data(repeating:0,count:17*2048); dataISO.replaceSubrange(16*2048..<16*2048+7,with:Data([1])+Data("CD001".utf8)+Data([1]))
        let dataURL = dir.appendingPathComponent("data.ISO"); try dataISO.write(to:dataURL)
        XCTAssertEqual(try DiscImageProbe.inspect(dataURL).kind,"数据 ISO")
        let short = dir.appendingPathComponent("bad.iso"); try Data([0,1]).write(to:short)
        XCTAssertEqual(try DiscImageProbe.inspect(short).kind,"未识别 ISO")
        let files = try await LibraryScanner.scan(root:LibraryRoot(path:dir.path,bookmark:Data()),url:dir,previous:[]) { _,_ in }
        XCTAssertEqual(files.count,3); XCTAssertTrue(files.allSatisfy(\.isDiscImage)); XCTAssertTrue(files.allSatisfy { $0.duration == 0 && $0.issue != nil && $0.audioIdentity == nil })
        XCTAssertEqual(try Data(contentsOf:url),sacd)
    }
}
