import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchShowsLibrary() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Stickers"].waitForExistence(timeout: 10))
    }
}
