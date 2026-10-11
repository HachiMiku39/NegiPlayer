import Foundation

public struct HTTPRequest: Sendable {
    public let method:String; public let target:String; public let headers:[String:String]; public let body:Data
    public var components:URLComponents? { URLComponents(string:"https://localhost"+target) }
    public init(method:String,target:String,headers:[String:String]=[:],body:Data=Data()) { self.method=method; self.target=target; self.headers=headers; self.body=body }
    /// One bounded request per connection. No chunked bodies, duplicates, or ambiguous framing.
    public static func parse(_ bytes:Data) throws -> HTTPRequest? {
        let separator=Data("\r\n\r\n".utf8)
        guard let range=bytes.range(of:separator) else { if bytes.count>32768 { throw LANError.status(431) }; return nil }
        guard range.lowerBound<=32768, let text=String(data:bytes[..<range.lowerBound],encoding:.utf8) else { throw LANError.status(400) }
        let rows=text.components(separatedBy:"\r\n"), first=rows[0].split(separator:" ",omittingEmptySubsequences:false)
        guard first.count==3, ["GET","HEAD","POST","DELETE"].contains(String(first[0])), first[2]=="HTTP/1.1",
              first[1].hasPrefix("/"), !first[1].hasPrefix("//"), !first[1].contains("#") else { throw LANError.status(400) }
        var headers:[String:String]=[:]
        for row in rows.dropFirst() {
            guard !row.hasPrefix(" "), !row.hasPrefix("\t"), let colon=row.firstIndex(of:":") else { throw LANError.status(400) }
            let key=row[..<colon].lowercased(); let value=row[row.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0=="-") }), headers[key]==nil,
                  !value.contains(where: { $0.asciiValue.map { $0<32 || $0==127 } ?? false }) else { throw LANError.status(400) }
            headers[key]=value
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil else { throw LANError.status(400) }
        let length:Int
        if let raw=headers["content-length"] { guard !raw.isEmpty, raw.allSatisfy(\.isNumber), let n=Int(raw), n<=4096 else { throw LANError.status(413) }; length=n }
        else { length=0 }
        let start=range.upperBound
        guard bytes.count >= start+length else { return nil }
        guard bytes.count == start+length else { throw LANError.status(400) }
        return .init(method:String(first[0]),target:String(first[1]),headers:headers,body:Data(bytes[start...]))
    }
}
public struct ByteRange: Equatable, Sendable {
    public var start:Int64; public var count:Int64
    public var end:Int64 { start+count-1 }
    public init(start:Int64,count:Int64) { self.start=start; self.count=count }
    public static func parse(_ value:String?,length:Int64) throws -> ByteRange {
        guard length>0 else { throw LANError.status(416) }
        guard let value else { return .init(start:0,count:length) }
        guard value.hasPrefix("bytes="), !value.contains(",") else { throw LANError.status(416) }
        let p=value.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
        guard p.count==2 else { throw LANError.status(416) }
        func number(_ s:Substring) -> Int64? { guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }; return Int64(s) }
        if p[0].isEmpty { guard let n=number(p[1]), n>0 else { throw LANError.status(416) }; let count=min(n,length); return .init(start:length-count,count:count) }
        guard let start=number(p[0]), start<length else { throw LANError.status(416) }
        let end:Int64
        if p[1].isEmpty { end=length-1 } else { guard let n=number(p[1]), n>=start else { throw LANError.status(416) }; end=min(n,length-1) }
        return .init(start:start,count:end-start+1)
    }
}
