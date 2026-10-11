import XCTest
import LibraryDomain

final class BrowseTests: XCTestCase {
    func testCombinedSourceFiltersAndNumericSorting() {
        let a = MediaFile(id:"a",rootID:"r",relativePath:"02.flac",title:"Song 2",artists:["AC/DC"],codec:"FLAC",sampleRate:96000,duration:20,tags:["COMPOSER":["作者"]])
        let b = MediaFile(id:"b",rootID:"r",relativePath:"10.flac",title:"Song 10",codec:"FLAC",sampleRate:44100,duration:10,available:false)
        let d = MediaFile(id:"d",rootID:"r",relativePath:"d.dsf",title:"DSD",codec:"DSD (DSF)",sampleRate:2822400)
        var query = BrowseQuery(); query.codec = "FLAC"; query.sourceRate = .pcmHigh; query.text = "作者"
        XCTAssertEqual(query.apply(to:[d,b,a]).map(\.id),["a"])
        query.text = ""; query.sourceRate = .all; query.availability = .offline
        XCTAssertEqual(query.apply(to:[d,b,a]).map(\.id),["b"])
        query = BrowseQuery(); query.sort = .duration; query.ascending = false
        XCTAssertEqual(query.apply(to:[d,b,a]).map(\.id),["a","b","d"])
        query.sourceRate = .dsd
        XCTAssertEqual(query.apply(to:[a,b,d]).map(\.id),["d"])
    }
    func testPlayNextMovesWithoutDuplicatingOrChangingCurrent() {
        func media(_ id: String) -> MediaFile { .init(id:id,rootID:"r",relativePath:id,title:id) }
        let a=media("a"), b=media("b"), c=media("c"), d=media("d")
        let initial=[a,b,c]
        XCTAssertEqual(QueuePlan.inserting(c,into:initial,currentID:a.id,next:true).map(\.id),["a","c","b"])
        XCTAssertEqual(QueuePlan.inserting(b,into:initial,currentID:a.id,next:false).map(\.id),["a","b","c"])
        XCTAssertEqual(QueuePlan.inserting(d,into:initial,currentID:a.id,next:false).map(\.id),["a","b","c","d"])
        XCTAssertEqual(QueuePlan.inserting(a,into:initial,currentID:a.id,next:true).map(\.id),["a","b","c"])
    }
}
