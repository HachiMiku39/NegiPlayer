import XCTest
import AudioCore

final class MobileDSPTests:XCTestCase {
    func testActualMobileMetadataGainIndependentOfVolume() throws {
        let measurements:[PCMLevelMeasurement]
        if let path=ProcessInfo.processInfo.environment["NEGI_NATIVE_MOBILE_DSP_REPORT"] {
            measurements=try JSONDecoder().decode([PCMLevelMeasurement].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        } else { measurements=try PCMLevelControlVerification.measure() }
        XCTAssertEqual(measurements.map(\.gainDB),[-180,-96,-6,0,6,30,72])
        for m in measurements {
            XCTAssertEqual(m.input,0.0001);XCTAssertEqual(m.volume,0.5);XCTAssertEqual(m.means.count,2)
            let expected=m.input*m.volume*pow(10,m.gainDB/20)
            for actual in m.means { XCTAssertEqual(actual/expected,1,accuracy:0.003,"Gain \(m.gainDB)") }
        }
    }
}
