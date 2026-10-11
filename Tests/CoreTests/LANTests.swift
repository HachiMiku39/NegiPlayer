import XCTest
import Foundation
import AVFoundation
import LANCore
import LANHost
import MediaIO
import LibraryDomain

final class LANTests:XCTestCase {
    func folder() throws -> URL { let u=FileManager.default.temporaryDirectory.appendingPathComponent("Negi-LAN-Test-"+UUID().uuidString); try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true); return u }
    func fixture(_ root:URL) throws -> CatalogEntry {
        let source=root.appendingPathComponent("Signal.wav")
        var samples=Data()
        for i in 0..<4096 { for c in 0..<2 { var v=Int16((sin(Double(i)*0.07)*Double(c==0 ? 8000 : 4000)).rounded()).littleEndian; withUnsafeBytes(of:&v){samples.append(contentsOf:$0)} } }
        var data=Data("RIFF".utf8)
        func u32(_ n:UInt32) { var v=n.littleEndian; withUnsafeBytes(of:&v){data.append(contentsOf:$0)} }
        func u16(_ n:UInt16) { var v=n.littleEndian; withUnsafeBytes(of:&v){data.append(contentsOf:$0)} }
        u32(UInt32(samples.count+36)); data.append(Data("WAVEfmt ".utf8)); u32(16);u16(1);u16(2);u32(48000);u32(192000);u16(4);u16(16);data.append(Data("data".utf8));u32(UInt32(samples.count));data.append(samples);try data.write(to:source)
        let media=MediaFile(id:"signal-1",rootID:"test-root",relativePath:"Signal.wav",title:"Signal",artists:["Test"],album:"LAN",codec:"PCM 16-bit",sampleRate:48000,channels:2,duration:4096.0/48000,tags:["REPLAYGAIN_TRACK_GAIN":["-3 dB"],"PRIVATE_SOURCE_PATH":[source.path]],releaseKey:"album-1")
        return CatalogEntry(media:media,root:root,source:source)
    }
    func testHTTPFramingRejectsAmbiguityAndBounds() throws {
        XCTAssertNil(try HTTPRequest.parse(Data("GET /v1/info HTTP/1.1\r\nHost: localhost\r\n".utf8)))
        let valid=try XCTUnwrap(HTTPRequest.parse(Data("POST /v1/pair HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}".utf8)))
        XCTAssertEqual(valid.body,Data("{}".utf8));XCTAssertEqual(valid.method,"POST")
        for text in ["GET //evil HTTP/1.1\r\nHost: x\r\n\r\n","GET /v1/info HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n","POST /v1/pair HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n","GET /v1/info HTTP/1.1\r\nHost: x\r\n\r\nGET /v1/info HTTP/1.1","POST /v1/pair HTTP/1.1\r\nHost: x\r\nContent-Length: 4097\r\n\r\n"] { XCTAssertThrowsError(try HTTPRequest.parse(Data(text.utf8))) }
        XCTAssertThrowsError(try HTTPRequest.parse(Data(repeating:65,count:32769)))
    }
    func testRangesAndLANAddressValidation() throws {
        XCTAssertEqual(try ByteRange.parse("bytes=8-15",length:100),ByteRange(start:8,count:8))
        XCTAssertEqual(try ByteRange.parse("bytes=-5",length:100),ByteRange(start:95,count:5))
        XCTAssertEqual(try ByteRange.parse("bytes=98-",length:100),ByteRange(start:98,count:2))
        for s in ["bytes=1-0","bytes=100-","bytes=0-1,3-4","bytes=-0","bytes=9223372036854775808-","bytes=+1-2","bytes= 1-2"] { XCTAssertThrowsError(try ByteRange.parse(s,length:100)) }
        for ip in ["127.0.0.1","10.20.30.40","172.16.0.1","192.168.3.1","::1","fd11::2","fe80::1%en0","::ffff:192.168.1.5"] { XCTAssertTrue(NegiLAN.localAddress(ip),ip) }
        for ip in ["172.32.0.1","8.8.8.8","192.168.1.256","fc:::::","fd0","2001:4860::1","fe7f::1"] { XCTAssertFalse(NegiLAN.localAddress(ip),ip) }
        for url in ["http://localhost:1","https://example.com:443","https://127.0.0.1:443/x","https://u:p@localhost:443","https://localhost:443?q=x","https://localhost"] { XCTAssertThrowsError(try NegiLAN.baseURL(url)) }
        XCTAssertEqual(try NegiLAN.baseURL("https://mac.local:5000/").absoluteString,"https://mac.local:5000")
    }
    func testPairingExpiryLockOneUsePersistenceAndRevocation() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let path=root.appendingPathComponent("pairings.json"),store=try PairingStore(url:path),now=Date()
        let expired=try await store.renew(now:now)
        do { _=try await store.pair(PairRequest(code:expired,deviceName:"Test"),now:now.addingTimeInterval(301));XCTFail("Expired code accepted") } catch {}
        let locked=try await store.renew(now:now)
        for _ in 0..<10 { do { _=try await store.pair(PairRequest(code:"wrong",deviceName:"Test"),now:now);XCTFail("Wrong code accepted") } catch {} }
        do { _=try await store.pair(PairRequest(code:locked,deviceName:"Test"),now:now);XCTFail("Locked code accepted") } catch {}
        let code=try await store.renew(now:now),token=try await store.pair(PairRequest(code:code,deviceName:"Device\nName"),now:now)
        do { _=try await store.pair(PairRequest(code:code,deviceName:"Test"),now:now);XCTFail("Reused code") } catch {}
        let device=await store.authorize("Bearer "+token);XCTAssertNotNil(device)
        let persisted=try String(contentsOf:path,encoding:.utf8);XCTAssertFalse(persisted.contains(token))
        let restored=try PairingStore(url:path), restoredID=await restored.authorize("Bearer "+token);XCTAssertEqual(restoredID,device)
        try await restored.revoke(device!);let revoked=await restored.authorize("Bearer "+token);XCTAssertNil(revoked)
    }
    func testPCMExactRangesReadOnlyMetadataAndVideoBoundary() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let entry=try fixture(root),before=try Data(contentsOf:entry.source),pcm=try PCMSource(entry:entry)
        XCTAssertEqual(pcm.info.sampleRate,48000);XCTAssertEqual(pcm.info.channels,2);XCTAssertEqual(pcm.info.frames,4096);XCTAssertNil(pcm.info.tags["PRIVATE_SOURCE_PATH"])
        let whole=try pcm.read(start:0,count:Int(pcm.info.length)),slice=try pcm.read(start:7,count:1031)
        XCTAssertEqual(slice,Data(whole[7..<1038]))
        let decoded=try PCMTransport.decode(whole,channels:2);XCTAssertEqual(decoded[0][0],0);XCTAssertEqual(decoded[0][100],2*decoded[1][100],accuracy:1.0/32768)
        XCTAssertEqual(try Data(contentsOf:entry.source),before)
        let projected=try JSONEncoder().encode(entry.remote);XCTAssertFalse(String(decoding:projected,as:UTF8.self).contains(root.path))
        XCTAssertNil(try LANServer.video(for:entry));try Data([0,1]).write(to:root.appendingPathComponent("Signal.mp4"));XCTAssertNotNil(try LANServer.video(for:entry))
        try Data([0,1]).write(to:root.appendingPathComponent("Signal.mov"));XCTAssertNil(try LANServer.video(for:entry)) // Ambiguous matches are not selected.
        let outside=try folder();defer{try? FileManager.default.removeItem(at:outside)}
        try before.write(to:outside.appendingPathComponent("Escape.wav"));let link=root.appendingPathComponent("Escape.wav");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside.appendingPathComponent("Escape.wav"))
        XCTAssertThrowsError(try CatalogEntry(media:entry.media,root:root,source:link).authorizedSource())
        var dsd=entry.media;dsd.codec="DSD (DSF)";XCTAssertFalse(CatalogEntry(media:dsd,root:root,source:entry.source).remote.playable)
        XCTAssertThrowsError(try PCMTransport.decode(Data([1,2,3]),channels:2))
    }
    func testDuoAdaptiveLayoutUsesWindowDimensions() {
        XCTAssertFalse(MobileLayout.splitLyrics(width:390,height:760,hasLyrics:true))
        XCTAssertTrue(MobileLayout.splitLyrics(width:940,height:720,hasLyrics:true))
        XCTAssertFalse(MobileLayout.splitLyrics(width:940,height:720,hasLyrics:false))
        XCTAssertFalse(MobileLayout.splitLyrics(width:940,height:300,hasLyrics:true))
        XCTAssertLessThanOrEqual(MobileLayout.coverLimit(width:940,height:720,split:true),520)
    }
    func testPinnedHTTPSReadOnlyStreamingAndRevoke() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let music=root.appendingPathComponent("Music");try FileManager.default.createDirectory(at:music,withIntermediateDirectories:true)
        let entry=try fixture(music);try Data("[offset:500]\n[00:01.00]A lyric\n".utf8).write(to:music.appendingPathComponent("Signal.lrc"))
        let server=try LANServer(directory:root.appendingPathComponent("Server"),artwork:ArtworkRepository(cacheDirectory:root.appendingPathComponent("Artwork")))
        await server.update([entry]);try await server.start(port:0,advertise:false)
        var state=await server.snapshot()
        for _ in 0..<50 where !state.running { try await Task.sleep(nanoseconds:100_000_000);state=await server.snapshot() }
        XCTAssertTrue(state.running);guard state.running else { await server.stop();return }
        let base=URL(string:"https://127.0.0.1:\(state.port)")!,client=try PinnedSession(baseURL:base,fingerprint:state.fingerprint)
        do {
            do { _=try await client.request("/v1/info");XCTFail("Unauthenticated request accepted") } catch {}
            let code=try await server.renewCode(),paired=try await client.pair(code:code,name:"Integration device")
            let page=try await client.json("/v1/tracks",as:TrackPage.self,token:paired.token);XCTAssertEqual(page.total,1)
            let info=try await client.json("/v1/tracks/signal-1/stream-info",as:StreamInfo.self,token:paired.token)
            XCTAssertEqual(info.sampleRate,48000)
            let range=ByteRange(start:7,count:1031),(bytes,response)=try await client.request("/v1/tracks/signal-1/stream",token:paired.token,range:range)
            XCTAssertEqual(response.statusCode,206);XCTAssertEqual(bytes,try PCMSource(entry:entry).read(start:7,count:1031))
            let lines=try await client.json("/v1/tracks/signal-1/lyrics",as:RemoteLyrics.self,token:paired.token);XCTAssertEqual(lines.lines.first?.time,1.5)
            let wrong=try PinnedSession(baseURL:base,fingerprint:String(repeating:"0",count:64));defer{wrong.session.invalidateAndCancel()}
            do { _=try await wrong.request("/v1/info",token:paired.token);XCTFail("Wrong certificate accepted") } catch {}
            do { _=try await client.request("/v1/tracks",method:"POST",token:paired.token);XCTFail("Writable library route accepted") } catch {}
            let (_,deleted)=try await client.request("/v1/device",method:"DELETE",token:paired.token);XCTAssertEqual(deleted.statusCode,204)
            do { _=try await client.request("/v1/info",token:paired.token);XCTFail("Revoked token accepted") } catch {}
        } catch { client.session.invalidateAndCancel();await server.stop();throw error }
        client.session.invalidateAndCancel();await server.stop()
    }
    func testLargeCatalogHTTPSResponseCompletes() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let original=try fixture(root)
        let entries=(0..<14000).map { index -> CatalogEntry in
            var media=original.media
            media.id="large-\(index)";media.releaseKey="album-\(index/10)"
            media.album="Album \(index/10) "+String(repeating:"音楽",count:80)
            return CatalogEntry(media:media,root:root,source:original.source)
        }
        let server=try LANServer(directory:root.appendingPathComponent("Server"),artwork:ArtworkRepository(cacheDirectory:root.appendingPathComponent("Artwork")))
        await server.update(entries);try await server.start(port:0,advertise:false)
        var state=await server.snapshot()
        for _ in 0..<50 where !state.running { try await Task.sleep(nanoseconds:100_000_000);state=await server.snapshot() }
        XCTAssertTrue(state.running);guard state.running else { await server.stop();return }
        let client=try PinnedSession(baseURL:URL(string:"https://127.0.0.1:\(state.port)")!,fingerprint:state.fingerprint)
        do {
            let paired=try await client.pair(code:server.renewCode(),name:"Large catalog test")
            for _ in 0..<3 {
                let page=try await client.json("/v1/albums",as:AlbumPage.self,token:paired.token)
                XCTAssertEqual(page.albums.count,1400)
                XCTAssertEqual(page.albums.reduce(0){$0+$1.count},14000)
                let tracks=try await client.json("/v1/tracks?offset=13500&limit=500",as:TrackPage.self,token:paired.token)
                XCTAssertEqual(tracks.total,14000);XCTAssertEqual(tracks.tracks.count,500)
            }
        } catch { client.session.invalidateAndCancel();await server.stop();throw error }
        client.session.invalidateAndCancel();await server.stop()
    }
}
