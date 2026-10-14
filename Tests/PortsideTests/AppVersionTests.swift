import XCTest
@testable import Portside

final class AppVersionTests: XCTestCase {
    func testReleasesCompareNumerically() {
        XCTAssertTrue(AppVersion.isNewer("0.37.0", than: "0.36.9"))
        XCTAssertTrue(AppVersion.isNewer("0.36.10", than: "0.36.9"), "numbers, not text")
        XCTAssertTrue(AppVersion.isNewer("1.0", than: "0.99.9"))
        XCTAssertFalse(AppVersion.isNewer("0.36.0", than: "0.36"), "trailing zeros are equal")
        XCTAssertFalse(AppVersion.isNewer("0.36.0", than: "0.36.0"))
        XCTAssertFalse(AppVersion.isNewer("0.35.9", than: "0.36.0"))
        XCTAssertFalse(AppVersion.isNewer("banana", than: "0.36.0"), "an unreadable stamp never blocks")
        XCTAssertFalse(AppVersion.isNewer("0.40.0", than: "dev"))
        for mangled in [".40", "1.-1", "+1.0", "1..0", "1.0.", "", "١.٠"] {
            XCTAssertFalse(AppVersion.isNewer(mangled, than: "0.37.0"), "\(mangled) must not block")
        }
    }
}
