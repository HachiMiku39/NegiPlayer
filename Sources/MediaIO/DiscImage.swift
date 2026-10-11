import Foundation

public struct DiscImageInfo: Equatable, Sendable {
    public let kind: String
    public let detail: String
}

/// Header recognition only. A data ISO is not evidence of CD-DA tracks.
public enum DiscImageProbe {
    public static func inspect(_ url: URL) throws -> DiscImageInfo {
        let h = try FileHandle(forReadingFrom:url); defer { try? h.close() }
        let length = try h.seekToEnd()
        if length >= 511*2048 {
            try h.seek(toOffset:510*2048)
            if try h.read(upToCount:8) == Data("SACDMTOC".utf8) {
                return .init(kind:"SACD ISO",detail:"已识别 SACD 主目录；曲目解析、DST／DSD 解码与镜像播放尚未接通")
            }
        }
        if length >= 17*2048 {
            try h.seek(toOffset:16*2048)
            let sector = try h.read(upToCount:7) ?? Data()
            if sector.count == 7, sector[1..<6] == Data("CD001".utf8), sector[6] == 1 {
                return .init(kind:"数据 ISO",detail:"已识别 ISO 9660 数据镜像；尚未枚举其中音频。CD-DA 通常需要 BIN／CUE 的轨道信息")
            }
        }
        return .init(kind:"未识别 ISO",detail:"未发现有效 SACD／ISO 9660 头部；保留记录，未作为音乐播放")
    }
}
