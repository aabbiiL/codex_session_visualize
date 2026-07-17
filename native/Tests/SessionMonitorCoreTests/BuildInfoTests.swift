import XCTest
@testable import SessionMonitorCore

final class BuildInfoTests: XCTestCase {
    func testFixedVersionAndPlatformFloor() {
        XCTAssertEqual(BuildInfo.version, "0.1.0")
        XCTAssertEqual(BuildInfo.minimumMacOSMajorVersion, 14)
        XCTAssertEqual(BuildInfo.supportedArchitecture, "arm64")
    }
}
