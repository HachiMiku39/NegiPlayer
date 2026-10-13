import Foundation
import AVFoundation
import LANCore
import LANHost
import MediaIO
import LibraryDomain

func option(_ name:String)->String? { let args=CommandLine.arguments; guard let index=args.firstIndex(of:name),args.indices.contains(index+1) else { return nil }; return args[index+1] }
func expectedPCM()->Data {
    var data=Data()
    for frame in 0..<4096 { for scale in [100,50] { var bits=Float((frame%97-48)*scale).divided(by:32768).bitPattern.littleEndian; withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) } } }
    return data
}
extension Float { func divided(by x:Float)->Float { self/x } }

if let peer=option("--peer") {
    let root=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:peer))) as! [String:String]
    let client=try PinnedSession(baseURL:NegiLAN.baseURL(root["baseURL"]!),fingerprint:root["fingerprint"]!)
    defer { client.session.invalidateAndCancel() }
    let pair=try await client.pair(code:root["code"]!,name:"Swift conformance endpoint")
    let info=try await client.json("/v1/info",as:ServerInfo.self,token:pair.token)
    guard info.protocolVersion==1,info.id==pair.serverID else { throw LANError.message("Peer identity mismatch") }
    let format=try await client.json("/v1/tracks/signal-1/stream-info",as:StreamInfo.self,token:pair.token);try format.validate()
    guard format.frames==4096,format.sampleRate==48000,format.channels==2 else { throw LANError.message("Fixture format differs") }
    let expected=expectedPCM()
    for range in [ByteRange(start:0,count:32768),ByteRange(start:7,count:1031),ByteRange(start:16000,count:1200)] {
        let (data,response)=try await client.request("/v1/tracks/signal-1/stream",token:pair.token,range:range)
        guard response.statusCode==206,data==Data(expected[Int(range.start)..<Int(range.start+range.count)]),response.value(forHTTPHeaderField:"Content-Range")=="bytes \(range.start)-\(range.end)/32768" else { throw LANError.message("PCM range differs") }
    }
    let lyrics=try await client.json("/v1/tracks/signal-1/lyrics",as:RemoteLyrics.self,token:pair.token)
    guard lyrics.lines.count==2,abs((lyrics.lines[0].time ?? -1)-1.2)<0.000001,lyrics.lines[1].text=="音楽 · Music · 🌱" else { throw LANError.message("LRC differs") }
    let art=try await client.request("/v1/tracks/signal-1/artwork",token:pair.token);guard !art.0.isEmpty else { throw LANError.message("Cover missing") }
    let state=MobileDeviceState(output:"Swift conformance endpoint",sampleRate:48000,eqEnabled:true,playing:false,trackTitle:"Original signal")
    _=try await client.request("/v1/device/state",method:"POST",token:pair.token,body:JSONEncoder().encode(state))
    _=try await client.request("/v1/device",method:"DELETE",token:pair.token)
    let report:[String:Any]=["passed":true,"protocolVersion":1,"sourceRate":48000,"channels":2,"frames":4096,"exactRanges":3,"artwork":true,"lrcOffsetAndUnicode":true,"stateReport":true]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:option("--report") ?? "swift-peer.json"))
    print("PASS: Swift client / peer host, exact PCM ranges, artwork, LRC and state.")
} else {
    guard let ready=option("--ready") else { fatalError("--ready is required") }
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("Negi-Conformance-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let music=root.appendingPathComponent("Music");try FileManager.default.createDirectory(at:music,withIntermediateDirectories:true)
    let source=music.appendingPathComponent("Signal.wav")
    var pcm=Data();for frame in 0..<4096 { for scale in [100,50] { var value=Int16((frame%97-48)*scale).littleEndian;withUnsafeBytes(of:&value){pcm.append(contentsOf:$0)} } }
    var wav=Data("RIFF".utf8)
    func u32(_ x:UInt32) { var y=x.littleEndian;withUnsafeBytes(of:&y){wav.append(contentsOf:$0)} }
    func u16(_ x:UInt16) { var y=x.littleEndian;withUnsafeBytes(of:&y){wav.append(contentsOf:$0)} }
    u32(UInt32(pcm.count+36));wav.append(Data("WAVEfmt ".utf8));u32(16);u16(1);u16(2);u32(48000);u32(192000);u16(4);u16(16);wav.append(Data("data".utf8));u32(UInt32(pcm.count));wav.append(pcm);try wav.write(to:source)
    try Data("[offset:200]\n[00:01.00]Original signal\n[00:02.00]音楽 · Music · 🌱\n".utf8).write(to:music.appendingPathComponent("Signal.lrc"))
    try Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!.write(to:music.appendingPathComponent("Cover.png"))
    let media=MediaFile(id:"signal-1",rootID:"test-root",relativePath:"Signal.wav",title:"Original signal",artists:["NegiPlayer Original Signal"],album:"Fixture",codec:"PCM 16-bit",sampleRate:48000,channels:2,duration:4096.0/48000,releaseKey:"album-1")
    let server=try LANServer(directory:root.appendingPathComponent("Server"),artwork:ArtworkRepository(cacheDirectory:root.appendingPathComponent("Artwork")),name:"NegiPlayer Swift fixture")
    await server.update([CatalogEntry(media:media,root:music,source:source)]);try await server.start(port:0,advertise:false)
    var state=await server.snapshot();for _ in 0..<100 where !state.running { try await Task.sleep(nanoseconds:100_000_000);state=await server.snapshot() }
    guard state.running else { throw LANError.message("Fixture host did not start") }
    let code=try await server.renewCode()
    let data=try JSONSerialization.data(withJSONObject:["baseURL":"https://127.0.0.1:\(state.port)","fingerprint":state.fingerprint,"code":code])
    try data.write(to:URL(fileURLWithPath:ready));try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:ready)
    print("Synthetic Swift HTTPS fixture ready.")
    try await Task.sleep(nanoseconds:UInt64(Int(option("--seconds") ?? "240") ?? 240)*1_000_000_000);await server.stop()
}
