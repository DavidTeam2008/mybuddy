import XCTest

/// Regressions for the SwiftUI List invalid-update exception after deleting a
/// history task: from its detail screen (the covered list receives the row
/// change while the stack pops) and from the history swipe action.
final class HistoryDeleteTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDeletingFaceToFaceTaskFromDetailKeepsHistoryListConsistent() throws {
        let app = XCUIApplication()
        // Isolated store so device runs never touch the developer's real history.
        app.launchArguments += [
            "-duiyi.onboardingComplete", "YES",
            "-duiyi.seedHistory",
            "-duiyi.storeFile", "history-delete-\(UUID().uuidString)",
        ]
        app.launch()

        let history = app.buttons["home-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15), "home history entry missing")
        history.tap()

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'history-row-'")
        )
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "seeded rows missing")
        XCTAssertGreaterThanOrEqual(rows.count, 4, "seed should provide four rows")
        rows.firstMatch.tap()

        let delete = app.buttons["detail-delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 15), "detail delete missing")
        delete.tap()

        // The dialog's button is exposed twice (SwiftUI wraps it in another
        // button of the same identifier).
        let confirm = app.buttons.matching(identifier: "detail-delete-confirm").firstMatch
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

    /// Deletes every seeded row one by one through the detail screen. The
    /// second delete runs against a two-row list, the shape in the device
    /// crash reports.
    func testRepeatedDetailDeletesKeepHistoryListConsistent() throws {
        let app = XCUIApplication()
        // Isolated store so device runs never touch the developer's real history.
        app.launchArguments += [
            "-duiyi.onboardingComplete", "YES",
            "-duiyi.seedHistory",
            "-duiyi.seedEntryCount", "40",
            "-duiyi.storeFile", "history-delete-\(UUID().uuidString)",
        ]
        app.launch()

        let history = app.buttons["home-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15), "home history entry missing")
        history.tap()

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'history-row-'")
        )
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "seeded rows missing")
        XCTAssertGreaterThanOrEqual(rows.count, 4, "seed should provide four rows")

        let filters = app.buttons["history-filter-all"]
        for remaining in stride(from: rows.count, to: 0, by: -1) {
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
            rows.firstMatch.tap()

            let delete = scrollToDetailDelete(in: app)
            XCTAssertTrue(delete.waitForExistence(timeout: 15), "detail delete missing")
            delete.tap()

            let confirm = app.buttons.matching(identifier: "detail-delete-confirm").firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 15), "delete confirmation missing")
            confirm.tap()

            XCTAssertTrue(filters.waitForExistence(timeout: 15), "app did not return to history")
            XCTAssertEqual(app.state, .runningForeground)
            if remaining > 1 {
                XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
            }
        }

        XCTAssertTrue(
            app.staticTexts["history-empty"].waitForExistence(timeout: 15),
            "history empty state missing"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// The device crash happened while deleting inside the face-to-face
    /// filtered history list: two rows, one swipe-deleted, confirmation
    /// dismissed.
    func testFilteredSwipeDeleteKeepsHistoryListConsistent() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-duiyi.onboardingComplete", "YES",
            "-duiyi.seedHistory",
            "-duiyi.seedEntryCount", "40",
            "-duiyi.storeFile", "history-swipe-delete-\(UUID().uuidString)",
        ]
        app.launch()

        let history = app.buttons["home-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15), "home history entry missing")
        history.tap()

        let faceToFace = app.buttons["history-filter-faceToFace"]
        XCTAssertTrue(faceToFace.waitForExistence(timeout: 15), "face-to-face filter missing")
        faceToFace.tap()

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'history-row-'")
        )
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "seeded rows missing")
        waitUntil { rows.count == 2 }
        XCTAssertEqual(rows.count, 2, "seed should provide two face-to-face tasks")

        rows.firstMatch.swipeLeft()
        let action = app.buttons["history-swipe-delete"]
        XCTAssertTrue(action.waitForExistence(timeout: 10), "swipe delete action missing")
        action.tap()

        // The dialog's button is exposed twice (SwiftUI wraps it in another
        // button of the same identifier).
        let confirm = app.buttons.matching(identifier: "history-delete-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "delete confirmation missing")
        confirm.tap()

        XCTAssertTrue(app.buttons["history-filter-all"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
        waitUntil { rows.count == 1 }
        XCTAssertEqual(rows.count, 1)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// The delete button sits below the transcript, so a realistic task needs
    /// scrolling before it can be tapped. It must also clear the home-indicator
    /// strip, or the tap is swallowed by the system gesture.
    private func scrollToDetailDelete(in app: XCUIApplication) -> XCUIElement {
        let delete = app.buttons["detail-delete"]
        var swipes = 0
        while (!delete.isHittable || delete.frame.maxY > app.frame.maxY - 40), swipes < 30 {
            app.swipeUp()
            swipes += 1
        }
        return delete
    }
}
