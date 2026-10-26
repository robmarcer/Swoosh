import XCTest
@testable import SwooshCore

final class HomeHoldTests: XCTestCase {
    func testProgressAndSingleActivationUntilRelease() {
        var hold = HomeHold()
        XCTAssertFalse(hold.update(pressed: true, eligible: true, now: 10))
        XCTAssertFalse(hold.update(pressed: true, eligible: true, now: 10.75))
        XCTAssertEqual(hold.progress, 0.5)
        XCTAssertTrue(hold.update(pressed: true, eligible: true, now: 11.5))
        XCTAssertFalse(hold.update(pressed: true, eligible: true, now: 13))
        XCTAssertFalse(hold.update(pressed: false, eligible: true, now: 14))
        XCTAssertEqual(hold.progress, 0)
        XCTAssertFalse(hold.update(pressed: true, eligible: true, now: 15))
        XCTAssertTrue(hold.update(pressed: true, eligible: true, now: 16.5))
    }
    func testDisconnectOrGameExitCancelsHold() {
        var hold = HomeHold()
        _ = hold.update(pressed: true, eligible: true, now: 0)
        XCTAssertFalse(hold.update(pressed: false, eligible: true, now: 1))
        XCTAssertFalse(hold.update(pressed: true, eligible: true, now: 2))
        XCTAssertFalse(hold.update(pressed: true, eligible: false, now: 4))
        XCTAssertEqual(hold.progress, 0)
    }
}
