import XCTest

/// Regression for the SwiftUI List invalid-update exception after deleting a
/// history task from its detail screen (3 rows, delete one).
final class HistoryDeleteTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDeletingFaceToFaceTaskFromDetailKeepsHistoryListConsistent() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-duiyi.onboardingComplete", "YES", "-duiyi.seedHistory"]
        app.launch()

        let history = app.buttons["home-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15), "home history entry missing")
        history.tap()

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'history-row-'")
        )
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "seeded rows missing")
        XCTAssertGreaterThanOrEqual(rows.count, 3, "seed should provide three rows")
        rows.firstMatch.tap()

        let delete = app.buttons["detail-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 15), "detail delete missing")
        delete.tap()

        // The confirmation is a system popover card without identifiers; the
        // detail button is excluded by its identifier.
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "删除", "detail-delete")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "delete confirmation missing")
        confirm.tap()

        // After the delete the app must return to a consistent history list.
        // A List update exception terminates the app before this can pass.
        XCTAssertTrue(
            app.buttons["home-history"].waitForExistence(timeout: 15)
                || app.buttons["history-filter-all"].waitForExistence(timeout: 15),
            "app did not return to a consistent history screen"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }
}
