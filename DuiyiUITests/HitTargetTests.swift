import XCTest

/// #44: every custom interactive control must offer at least a 44×44 pt hit
/// target. System toolbar items (#45) are Apple-owned controls and are covered
/// by an identifier/existence check instead. Frames come from the accessibility
/// hierarchy, so this also pins the identifiers used by the rest of the suite.
final class HitTargetTests: XCTestCase {
    private let minimumSide: CGFloat = 44

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-duiyi.onboardingComplete", "YES"]
        app.launch()
        return app
    }

    /// Sheet and navigation presentations scale their content while animating;
    /// measuring mid-flight reports a slightly shrunken frame. Poll until two
    /// consecutive measurements agree before asserting.
    private func settledFrame(of element: XCUIElement, timeout: TimeInterval = 5) -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = element.frame
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let current = element.frame
            if current == previous {
                return current
            }
            previous = current
        }
        return element.frame
    }

    private func assertHitTarget(
        _ element: XCUIElement,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: 15),
            "\(name) does not exist",
            file: file,
            line: line
        )
        let frame = settledFrame(of: element)
        // Screen-space frames go through Core Animation's float pipeline, so
        // an exact 44 pt layout can read back as 43.99999999999994.
        let threshold = minimumSide - 0.5
        XCTAssertGreaterThanOrEqual(
            frame.width,
            threshold,
            "\(name) width is \(frame.width), expected ≥44",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.height,
            threshold,
            "\(name) height is \(frame.height), expected ≥44",
            file: file,
            line: line
        )
    }

    /// The system toolbar owns these items' hit targets; assert the identifiers
    /// survive the move out of the custom chrome.
    func testModuleToolbarEntries() throws {
        let app = launchApp()
        let module = app.buttons["home-module-faceToFace"]
        XCTAssertTrue(module.waitForExistence(timeout: 15))
        module.tap()

        for identifier in [
            "nav-home",
            "nav-history",
            "taskbar-new-task",
            "taskbar-end-task",
        ] {
            XCTAssertTrue(
                app.buttons[identifier].waitForExistence(timeout: 15),
                "\(identifier) missing from the system toolbar"
            )
        }
    }

    func testDirectionBarAndVoiceOut() throws {
        let app = launchApp()
        let module = app.buttons["home-module-simultaneous"]
        XCTAssertTrue(module.waitForExistence(timeout: 15))
        module.tap()

        assertHitTarget(app.buttons["direction-source"], "direction-source")
        assertHitTarget(app.buttons["direction-target"], "direction-target")
        assertHitTarget(app.buttons["direction-swap"], "direction-swap")
        assertHitTarget(app.buttons["voice-out"], "voice-out")
    }

    /// Measures the chips in a module's in-view settings overlay (1:1 screen
    /// coordinates).
    func testLanguageChips() throws {
        let app = launchApp()
        let module = app.buttons["home-module-faceToFace"]
        XCTAssertTrue(module.waitForExistence(timeout: 15))
        module.tap()

        let settings = app.buttons["settings-open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let chips = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'langchip-'")
        )
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(chips.count, 6)
        for index in 0..<chips.count {
            let chip = chips.element(boundBy: index)
            assertHitTarget(chip, chip.identifier)
        }
    }

    /// HomeSettingsSheet is a system sheet; iOS presents its content in an
    /// inset card that scales layout points down (424 / 440 on this device),
    /// so screen-space frames must be normalized by that presentation scale.
    func testHomeSettingsSheetChipLayout() throws {
        let app = launchApp()
        let settings = app.buttons["settings-open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()

        let chip = app.buttons["langchip-zhHans"]
        XCTAssertTrue(chip.waitForExistence(timeout: 15))

        // The presented sheet is the narrowest navigation bar on screen; the
        // root (home) bar sits behind it at full width.
        let navigationBars = app.navigationBars.allElementsBoundByIndex
        XCTAssertFalse(navigationBars.isEmpty, "no navigation bar for the sheet")
        let sheetBar = navigationBars.min { $0.frame.width < $1.frame.width }
        XCTAssertNotNil(sheetBar, "could not locate the sheet navigation bar")

        let scale = (sheetBar?.frame.width ?? 0) / app.frame.width
        XCTAssertGreaterThan(scale, 0, "could not derive sheet presentation scale")

        let frame = settledFrame(of: chip)
        let threshold = minimumSide - 0.5
        XCTAssertGreaterThanOrEqual(
            frame.width / scale,
            threshold,
            "langchip-zhHans width is \(frame.width / scale) in sheet space, expected ≥44"
        )
        XCTAssertGreaterThanOrEqual(
            frame.height / scale,
            threshold,
            "langchip-zhHans height is \(frame.height / scale) in sheet space, expected ≥44"
        )
    }

    func testHistoryFilterChips() throws {
        let app = launchApp()
        let history = app.buttons["home-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        history.tap()

        assertHitTarget(app.buttons["history-filter-all"], "history-filter-all")
        assertHitTarget(
            app.buttons["history-filter-faceToFace"],
            "history-filter-faceToFace"
        )
    }
}
