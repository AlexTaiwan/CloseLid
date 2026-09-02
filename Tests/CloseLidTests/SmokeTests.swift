import XCTest
@testable import CloseLid

final class SmokeTests: XCTestCase {
    func testTestTargetLinksAgainstApp() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.alexwang.CloseLid")
    }
}
