import Foundation
import AVFoundation
import LibraryDomain
import LANCore

public struct CatalogEntry: Sendable {
    public let media:MediaFile; public let root:URL; public let source:URL
    public init(media:MediaFile,root:URL,source:URL) { self.media=media; self.root=root; self.source=source }
    public var remote:RemoteTrack { .init(id:media.id,title:media.title,artist:media.artists.joined(separator:" · "),album:media.album,albumID:media.releaseKey,codec:media.codec,sampleRate:media.sampleRate,duration:media.duration,trackNumber:media.trackNumber,discNumber:media.discNumber,playable:media.available && !media.isDSD && !media.isDiscImage && (1...2).contains(media.channels) && (8000...384000).contains(media.sampleRate)) }
    public func authorizedSource() throws -> URL {
        let rootPath=root.standardizedFileURL.resolvingSymlinksInPath().path
        let path=source.standardizedFileURL.resolvingSymlinksInPath()
        guard path.path.hasPrefix(rootPath+"/"), media.available, !media.isDiscImage, !media.isDSD,
              try path.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true else { throw LANError.status(404) }
        return path
    }
}
public final class PCMSource: @unchecked Sendable {
    private let file:AVAudioFile; public let info:StreamInfo
    public init(entry:CatalogEntry) throws {
        file=try AVAudioFile(forReading:entry.authorizedSource(),commonFormat:.pcmFormatFloat32,interleaved:false)
        let safeKeys=Set(["REPLAYGAIN_TRACK_GAIN","REPLAYGAIN_ALBUM_GAIN","REPLAYGAIN_TRACK_PEAK","REPLAYGAIN_ALBUM_PEAK"])
        let tags=entry.media.tags.filter { safeKeys.contains($0.key.uppercased()) }
        info = .init(sampleRate:file.processingFormat.sampleRate,channels:Int(file.processingFormat.channelCount),frames:file.length,tags:tags)
        try info.validate()
    }
    /// A bounded, seekable decoded view. No disk cache and no Mac DSP/output graph.
    public func read(start:Int64,count:Int) throws -> Data {
        guard start>=0, count>=0, count<=262144, start<=info.length, Int64(count)<=info.length-start else { throw LANError.status(416) }
        if count==0 { return Data() }
        let frame=start/info.bytesPerFrame, skip=Int(start%info.bytesPerFrame)
        let n=(count+skip+Int(info.bytesPerFrame)-1)/Int(info.bytesPerFrame)
        guard let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(n)) else { throw LANError.status(500) }
        file.framePosition=frame; try file.read(into:buffer,frameCount:AVAudioFrameCount(n))
        guard let c=buffer.floatChannelData, Int(buffer.frameLength)>=n else { throw LANError.message("音乐文件在传输期间改变或被截断") }
        let channels=(0..<info.channels).map { Array(UnsafeBufferPointer(start:c[$0],count:n)) }
        let data=try PCMTransport.encode(channels:channels); return Data(data[skip..<skip+count])
    }
}
