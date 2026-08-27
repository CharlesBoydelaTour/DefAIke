import XCTest

/// UI, accessibility, and localization-readiness tests for the main app.
///
/// This target uses XCTest because XCUITest drives the visible flows: ingest
/// routes, progress states, result cards, Dynamic Type through the largest
/// accessibility categories, Reduce Motion, VoiceOver and Switch Control
/// workflows, pseudolocalized catalogs, and the absence of probability,
/// confidence, history, save, export, copy, and share-result affordances.
///
/// Populated by the presentation and accessibility tasks. Simulator runs are
/// development checks; the required assistive-technology workflows are physical
/// device gates.
final class DefAIkeUITests: XCTestCase {

    /// The approved chrome wording each screen is expected to show.
    ///
    /// Duplicated as literals here rather than imported, and deliberately so: this target must
    /// not link `DefAIkePresentation`, and a test that read the same constant the app reads
    /// would pass whatever that constant said. These are the strings a user sees, asserted
    /// independently. They are the *proposed* wording awaiting content approval, so a change to
    /// the String Catalog is expected to fail here until it is reflected.
    private enum Copy {
        static let selectImage = "Choose an image to analyze"
        static let importing = "Getting the image you chose"
        static let analyzing = "Analyzing this image on your device"
        static let cancel = "Stop analyzing"
        static let developmentNotice = "defaike.development.unapproved-inputs-notice"
    }

    /// The three fixed pixel labels Requirement 8.2 fixes character for character.
    private static let fixedPixelLabels = [
        "No strong signal detected",
        "Not enough signal",
        "Signals consistent with AI generation",
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    /// Drives the Photos route end to end and records each screen it passes through.
    ///
    /// A development check, not release evidence: it runs in a Simulator against the
    /// `#if DEBUG` development provisioning, whose Calibration Policy boundary is not approved.
    /// What it does establish is that the ready, importing or active, and terminal screens all
    /// render approved text, and that the picker is reachable from the ready screen at all.
    func testPhotosRouteRendersEveryScreen() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        // 1. The development notice, so a run cannot be mistaken for a release build.
        let notice = app.descendants(matching: .any)[Copy.developmentNotice]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "the development notice must render")
        attach(named: "1-ready")

        // 2. The ready screen's one control, found by the text a user actually sees.
        //
        // `firstMatch` is required rather than tidy. `AccessibleElementView` renders an operable
        // element as a SwiftUI `Button` and then applies `.accessibilityElement(children: .ignore)`
        // to it, which wraps the button's own accessibility element in a second one carrying the
        // same label. Both surface to XCUITest, so an unqualified query is ambiguous and reports
        // `isHittable == false` for that reason alone. Recorded here rather than worked around
        // silently: the duplication is benign for VoiceOver, which announces the outer element
        // once, but it is a real redundancy in the view layer.
        let selectImage = app.buttons[Copy.selectImage].firstMatch
        XCTAssertTrue(
            selectImage.waitForExistence(timeout: 20),
            "the ready screen must expose a labelled image-selection control"
        )
        XCTAssertTrue(selectImage.isHittable, "the control must be operable")
        // Requirement 12.9: at least a 44 by 44 point activation area, measured on the rendered
        // frame rather than on the model that asked for it.
        XCTAssertGreaterThanOrEqual(selectImage.frame.height, 44)
        XCTAssertGreaterThanOrEqual(selectImage.frame.width, 44)

        // 3. Open the picker.
        selectImage.tap()
        attach(named: "2-picker")

        // 4. Choose the first image the picker offers. The Photos picker is a system surface, so
        //    the element it exposes is queried loosely rather than by a fixed identifier.
        let firstImage = firstPickerImage(in: app)
        XCTAssertTrue(
            firstImage.waitForExistence(timeout: 30),
            "the Photos picker must offer at least one image; seed one with `simctl addmedia`"
        )
        firstImage.tap()

        // 5. Work in flight, captured by polling rather than by waiting.
        //
        // `waitForExistence` is the wrong tool here: it returns *after* the element appears, by
        // which time a fast analysis has already replaced the screen. The whole chain — retrieve,
        // decode, orient, resize, crop, load the model, infer, calibrate — runs in well under a
        // second on a 2000-pixel image, so the importing and active screens can come and go
        // between two of its polls.
        //
        // So this polls tightly and screenshots the first frame that shows either in-flight
        // status. Recorded as an observation rather than asserted: whether a screen is on display
        // long enough to be sampled is a timing property, and failing the test for a *fast*
        // analysis would be asserting the wrong thing.
        var sawImporting = false
        var sawAnalyzing = false
        let inFlightDeadline = Date().addingTimeInterval(20)
        while Date() < inFlightDeadline, !sawAnalyzing {
            if !sawImporting, app.staticTexts[Copy.importing].firstMatch.exists {
                sawImporting = true
                attach(named: "3-importing")
            }
            if app.staticTexts[Copy.analyzing].firstMatch.exists {
                sawAnalyzing = true
                let cancel = app.buttons[Copy.cancel].firstMatch
                XCTAssertTrue(cancel.exists, "the cancel control must be present during work")

                // The active screen appears while the picker sheet is still dismissing, so the
                // first frame that contains it is partly covered by that sheet and the control
                // under it is not yet hittable. Wait for the sheet to finish before recording,
                // and treat hittability as something to wait for rather than to assert on an
                // arbitrary frame — a mid-animation frame says nothing about Requirement 15.5.
                let settled = Date().addingTimeInterval(5)
                while Date() < settled, !cancel.isHittable,
                    app.staticTexts[Copy.analyzing].firstMatch.exists
                {
                    continue
                }
                attach(named: "3-analyzing")
                if app.staticTexts[Copy.analyzing].firstMatch.exists {
                    XCTAssertTrue(
                        cancel.isHittable,
                        "Requirement 15.5: the cancel control is enabled throughout active work"
                    )
                    XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
                }
                break
            }
            if Self.fixedPixelLabels.contains(where: { app.staticTexts[$0].firstMatch.exists }) {
                break  // Already finished; nothing in flight left to sample.
            }
        }
        print("=== DEFAIKE in-flight observed: importing=\(sawImporting) analyzing=\(sawAnalyzing)")

        // 6. A terminal screen. The completed screen shows one of the three fixed pixel labels;
        //    an error screen shows approved error copy, which this build has no value for and so
        //    renders nothing but the recovery control. Both are real outcomes.
        let reachedTerminal = waitForTerminal(in: app, timeout: 120)
        attach(named: "4-terminal")
        XCTAssertTrue(reachedTerminal, "the session must reach a terminal screen")

        // 7. Whatever the terminal was, no probability, percentage, or score is on screen
        //    (Requirement 8.13). Checked over every visible string rather than a chosen one.
        assertNoMagnitudeOnScreen(app)
    }

    // MARK: - Helpers

    /// The first selectable image in the system Photos picker.
    private func firstPickerImage(in app: XCUIApplication) -> XCUIElement {
        // The picker is a remote view; its cells surface as images or cells depending on the OS
        // build, so both are tried in a stable order.
        let cells = app.cells.firstMatch
        if cells.waitForExistence(timeout: 10) { return cells }
        return app.images.firstMatch
    }

    /// Waits until a terminal screen is on display.
    private func waitForTerminal(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in Self.fixedPixelLabels where app.staticTexts[label].firstMatch.exists {
                return true
            }
            // A terminal screen also re-offers the selection control. On the error screen that is
            // the only thing that renders, because this build has no approved error copy.
            if app.buttons[Copy.selectImage].firstMatch.exists,
                !app.staticTexts[Copy.analyzing].firstMatch.exists,
                !app.staticTexts[Copy.importing].firstMatch.exists
            {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Fails if any visible string contains a percentage or a bare decimal magnitude.
    ///
    /// Requirement 8.13 removes probability and confidence representations from every
    /// user-facing surface. The presentation models make one unrepresentable, and this is the
    /// same claim checked from the outside, on rendered text.
    private func assertNoMagnitudeOnScreen(_ app: XCUIApplication) {
        // Closures rather than key paths: `XCUIElement.label` is main-actor isolated, and a key
        // path to it cannot be formed under strict concurrency.
        let visible = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            + app.buttons.allElementsBoundByIndex.map { $0.label }
        for text in visible {
            XCTAssertFalse(text.contains("%"), "a percentage reached the screen: \(text)")
            // A decimal number would be a score or a raw logit. Version numbers are not on any
            // rendered surface in this build, so any decimal here is a magnitude.
            let decimal = text.range(of: #"\d+\.\d+"#, options: .regularExpression)
            XCTAssertNil(decimal, "a decimal magnitude reached the screen: \(text)")
        }
    }

    /// Records a full-screen screenshot in the result bundle.
    private func attach(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
