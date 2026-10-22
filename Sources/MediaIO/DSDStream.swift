import Foundation

public struct DSDStreamInfo: Equatable, Sendable {
    public let sampleRate: Int
    public let sampleCount: UInt64
    public let container: String
    public var carrierRate: Double { Double(sampleRate)/16 }
    public var duration: Double { Double(sampleCount)/Double(sampleRate) }
    public var frames: UInt64 { (sampleCount+15)/16 }
}

/// Read-only, bounded raw DSD reader. Output frames are chronological MSB-first
/// [L byte 0, L byte 1, R byte 0, R byte 1], never PCM samples.
/// DSF 1.01 (Sony) and uncompressed DSDIFF; DST is deliberately rejected.
public final class DSDStreamReader {
    public let info: DSDStreamInfo
    public private(set) var frame: UInt64 = 0
    private let handle: FileHandle
    private let payload: UInt64
    private let isDSF: Bool
    private let reverse: Bool
    private var cachedBlock: UInt64 = .max
    private var block = Data()
    private static let reverseTable: [UInt8] = (0...255).map { value in
        var input = UInt8(value), out: UInt8 = 0
        for _ in 0..<8 { out = (out << 1) | (input & 1); input >>= 1 }
        return out
    }
    private static func invalid(_ message: String) -> NSError { NSError(domain:"DSD",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    public init(url: URL) throws {
        let f = try FileHandle(forReadingFrom: url)
        do {
            let length = try f.seekToEnd()
            func read(_ at: UInt64, _ size: Int) throws -> Data {
                guard at <= length, size >= 0, UInt64(size) <= length-at else { throw Self.invalid("DSD 文件截断") }
                try f.seek(toOffset:at)
                let data = try f.read(upToCount:size) ?? Data()
                guard data.count == size else { throw Self.invalid("DSD 文件读取不完整") }; return data
            }
            func number(_ data: Data, _ at: Int, _ n: Int, little: Bool = false) -> UInt64 {
                (0..<n).reduce(0) { value, i in value | UInt64(data[at+i]) << (8*(little ? i : n-i-1)) }
            }
            let head = try read(0, 16)
            if head.prefix(4) == Data("DSD ".utf8) {
                let h = try read(0, 92)
                guard number(h,4,8,little:true)==28, number(h,12,8,little:true)==length,
                      h[28..<32]==Data("fmt ".utf8), number(h,32,8,little:true)==52,
                      number(h,40,4,little:true)==1, number(h,44,4,little:true)==0,
                      h[80..<84]==Data("data".utf8) else { throw Self.invalid("不支持或损坏的 DSF 头") }
                guard number(h,48,4,little:true)==2, number(h,52,4,little:true)==2 else { throw Self.invalid("DoP 首版只支持双声道 DSD") }
                let rate = number(h,56,4,little:true), bits = number(h,60,4,little:true)
                let samples = number(h,64,8,little:true), blockSize = number(h,72,4,little:true)
                guard [2_822_400,5_644_800].contains(rate), [1,8].contains(bits), blockSize==4096,
                      samples>0, samples <= (length/2)*8, samples < UInt64.max-15 else { throw Self.invalid("DoP 首版支持 DSD64／128，DSF 块须为 4096 字节") }
                let chunks = number(h,84,8,little:true), needed = ((samples+32767)/32768)*8192
                let metadata = number(h,20,8,little:true)
                guard chunks>=12, chunks<=length-80, chunks-12>=needed,
                      metadata==0 || (metadata>=80+chunks && metadata<length) else { throw Self.invalid("DSF 音频块长度或标签指针损坏") }
                payload=92; isDSF=true; reverse=bits==1
                info = .init(sampleRate:Int(rate),sampleCount:samples,container:"DSF")
            } else {
                guard head.prefix(4)==Data("FRM8".utf8), head[12..<16]==Data("DSD ".utf8),
                      number(head,4,8)>=4, number(head,4,8)<=length-12 else { throw Self.invalid("不支持的 DSD 容器") }
                let end=12+number(head,4,8)
                var at:UInt64=16, rate:UInt64=0, channels:UInt64=0, compression="", audio:UInt64=0, size:UInt64=0, count=0
                while at+12<=end {
                    count+=1; guard count<=100_000 else { throw Self.invalid("DFF 块过多") }
                    let h=try read(at,12), n=number(h,4,8), begin=at+12
                    guard n<=end-begin else { throw Self.invalid("DFF 块长度损坏") }
                    let id=String(decoding:h.prefix(4),as:UTF8.self)
                    if id=="DST " { throw Self.invalid("DST 压缩 DFF 尚未支持") }
                    if id=="PROP" {
                        guard n>=4, n<=1_048_576 else { throw Self.invalid("DFF 属性长度无效") }
                        let p=try read(begin,Int(n)); guard p.prefix(4)==Data("SND ".utf8) else { throw Self.invalid("DFF 音频属性缺失") }
                        var offset=4
                        while offset+12<=p.count {
                            let bytes=number(p,offset+4,8), start=offset+12
                            guard bytes<=UInt64(p.count-start) else { throw Self.invalid("DFF 子块越界") }
                            let tag=String(decoding:p[offset..<offset+4],as:UTF8.self)
                            if tag=="FS  ", bytes==4 { rate=number(p,start,4) }
                            if tag=="CHNL", bytes>=2 {
                                channels=number(p,start,2)
                                guard channels==2, bytes==10, p[start+2..<start+10]==Data("SLFTSRGT".utf8) else { throw Self.invalid("DoP 首版只支持双声道 Left／Right DFF") }
                            }
                            if tag=="CMPR", bytes>=4 { compression=String(decoding:p[start..<start+4],as:UTF8.self) }
                            offset=start+Int(bytes)+Int(bytes%2)
                        }
                    }
                    if id=="DSD " {
                        guard audio==0 else { throw Self.invalid("DFF 存在重复音频块") }
                        audio=begin; size=n
                    }
                    at=begin+n+n%2
                }
                guard compression=="DSD " else { throw Self.invalid("DFF 需要未压缩 DSD，尚不支持 DST") }
                guard [2_822_400,5_644_800].contains(rate), channels==2, audio>0, size>0, size%2==0,
                      size<=UInt64.max/4 else { throw Self.invalid("DoP 首版支持双声道 DSD64／128") }
                payload=audio; isDSF=false; reverse=false
                info = .init(sampleRate:Int(rate),sampleCount:size*4,container:"DFF")
            }
            handle=f
        } catch { try? f.close(); throw error }
    }
    deinit { try? handle.close() }
    public func seek(to seconds: Double) {
        let safe=seconds.isFinite ? min(info.duration,max(0,seconds)) : 0
        frame=min(info.frames,UInt64(safe*info.carrierRate)); cachedBlock = .max; block=Data()
    }
    public func readFrames(_ count: Int) throws -> Data {
        guard count>0, count<=65_536 else { throw Self.invalid("无效的 DSD 读取长度") }
        let n=Int(min(UInt64(count),info.frames-frame)); if n==0 { return Data() }
        let perChannel=(info.sampleCount+7)/8
        var output=Data(count:n*4)
        if !isDSF {
            let offset=frame*4, bytes=Int(min(UInt64(n*4),perChannel*2-offset))
            try handle.seek(toOffset:payload+offset)
            let input=try handle.read(upToCount:bytes) ?? Data()
            guard input.count==bytes else { throw Self.invalid("DFF 音频截断") }
            for i in 0..<n {
                let a=i*4
                output[a]=a<input.count ? input[a] : 0x69
                output[a+1]=a+2<input.count ? input[a+2] : 0x69
                output[a+2]=a+1<input.count ? input[a+1] : 0x69
                output[a+3]=a+3<input.count ? input[a+3] : 0x69
            }
        } else {
            for i in 0..<n {
                for c in 0..<2 { for b in 0..<2 {
                    let byte=(frame+UInt64(i))*2+UInt64(b)
                    var value:UInt8=0x69
                    if byte<perChannel {
                        let group=byte/4096
                        if group != cachedBlock {
                            try handle.seek(toOffset:payload+group*8192)
                            block=try handle.read(upToCount:8192) ?? Data()
                            guard block.count==8192 else { throw Self.invalid("DSF 音频截断") }; cachedBlock=group
                        }
                        value=block[c*4096+Int(byte%4096)]
                        if reverse { value=Self.reverseTable[Int(value)] }
                        if byte==perChannel-1, info.sampleCount%8 != 0 {
                            let mask=UInt8(0xff << (8-Int(info.sampleCount%8)) & 0xff)
                            value=(value & mask) | (0x69 & ~mask)
                        }
                    }
                    output[i*4+c*2+b]=value
                } }
            }
        }
        frame+=UInt64(n); return output
    }
}
