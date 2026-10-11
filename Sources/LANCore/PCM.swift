import Foundation

public struct StreamInfo: Codable, Sendable {
    public var sampleRate:Double; public var channels:Int; public var frames:Int64
    public var format:String = "float32-le-interleaved"
    public var tags:[String:[String]]
    public var bytesPerFrame:Int64 { Int64(channels*4) }
    public var length:Int64 { frames*bytesPerFrame }
    public init(sampleRate:Double,channels:Int,frames:Int64,tags:[String:[String]]=[:]) { self.sampleRate=sampleRate; self.channels=channels; self.frames=frames; self.tags=tags }
    public func validate() throws {
        guard format == "float32-le-interleaved", sampleRate.isFinite, (8000...384000).contains(sampleRate),
              (1...2).contains(channels), frames>0, frames<=Int64.max/bytesPerFrame else { throw LANError.message("音频流格式不支持（首版支持单声道／立体声 PCM）") }
    }
}
public enum PCMTransport {
    /// Stable wire endianness, no gain/EQ/resampling. Invalid float samples become silence.
    public static func encode(channels:[[Float]]) throws -> Data {
        guard let n=channels.first?.count, (1...2).contains(channels.count), channels.allSatisfy({ $0.count==n }) else { throw LANError.message("PCM 通道长度不一致") }
        var data=Data(capacity:n*channels.count*4)
        for frame in 0..<n { for c in channels { let f=c[frame].isFinite ? c[frame] : 0; var bits=f.bitPattern.littleEndian; withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) } } }
        return data
    }
    public static func decode(_ data:Data,channels:Int) throws -> [[Float]] {
        guard (1...2).contains(channels), data.count%(channels*4)==0, data.count<=2_097_152 else { throw LANError.message("PCM 数据不完整或超过缓冲上限") }
        let frames=data.count/(channels*4); var result=Array(repeating:Array(repeating:Float(0),count:frames),count:channels)
        data.withUnsafeBytes { raw in
            for f in 0..<frames { for c in 0..<channels { let bits=raw.loadUnaligned(fromByteOffset:(f*channels+c)*4,as:UInt32.self); let value=Float(bitPattern:UInt32(littleEndian:bits)); result[c][f]=value.isFinite ? value : 0 } }
        }
        return result
    }
}
public enum MobileLayout {
    // Size comes from the current scene, never a device model or launch-time screen.
    public static func splitLyrics(width:Double,height:Double,hasLyrics:Bool) -> Bool { hasLyrics && width>=680 && height>=360 }
    public static func coverLimit(width:Double,height:Double,split:Bool) -> Double { max(120,min(split ? width*0.43 : width-40, max(120,height-360),520)) }
}
