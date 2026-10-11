import Foundation
public struct MobileDeviceState: Codable, Sendable {
    public var output:String; public var sampleRate:Double; public var eqEnabled:Bool; public var playing:Bool; public var trackTitle:String
    public init(output:String,sampleRate:Double,eqEnabled:Bool,playing:Bool,trackTitle:String) { self.output=String(output.prefix(120)); self.sampleRate=sampleRate.isFinite ? sampleRate : 0; self.eqEnabled=eqEnabled; self.playing=playing; self.trackTitle=String(trackTitle.prefix(200)) }
}
public struct VideoInfo: Codable, Sendable {
    public var available:Bool; public var length:Int64; public var contentType:String
    public init(available:Bool,length:Int64=0,contentType:String="video/mp4") { self.available=available; self.length=length; self.contentType=contentType }
}
