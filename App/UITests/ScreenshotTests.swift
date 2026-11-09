import XCTest

/// App Store screenshots of the iPad app, taken in the built-in demo cluster: `make screenshots`
/// (PNG files land in build/appstore/). Not part of the regular test run.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-lastContext", "Demo Cluster", "-lastSidebarItem", "overview",
                                "-appearance", ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"] ?? "dark"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
    }

    func testScreenshots() throws {
        XCTAssertTrue(app.staticTexts["Cluster Overview"].waitForExistence(timeout: 30))
        // Let the usage history collect a few samples (every 15 s).
        sleep(UInt32(ProcessInfo.processInfo.environment["SCREENSHOT_WARMUP"].flatMap(UInt32.init) ?? 70))
        snap("01-overview")

        sidebar("Pods")
        snap("02-pods")

        row(startingWith: "payment-worker")
        tab("Logs")
        sleep(3)
        snap("03-pod-logs")

        sidebar("Deployments")
        row(startingWith: "frontend")
        sleep(2)
        snap("04-deployment")

        row(startingWith: "cart-api")
        tab("YAML")
        sleep(2)
        snap("05-yaml")

        sidebar("Releases")
        row(startingWith: "grafana")
        sleep(2)
        snap("06-helm-release")
    }

    // MARK: Helpers

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func sidebar(_ title: String) {
        let list = app.collectionViews.firstMatch
        let item = list.staticTexts[title].firstMatch
        for _ in 0..<5 where !(item.exists && item.isHittable) { list.swipeUp() }
        for _ in 0..<8 where !(item.exists && item.isHittable) { list.swipeDown() }
        XCTAssertTrue(item.waitForExistence(timeout: 10), "sidebar item \(title)")
        item.tap()
        sleep(2)
    }

    private func row(startingWith prefix: String) {
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap()
            if let current = search.value as? String, !current.isEmpty, current != search.placeholderValue {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            search.typeText(prefix)
            sleep(1)
        }
        let cell = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "row \(prefix)")
        cell.tap()
        // Show the whole list again; the selection stays.
        let clear = app.searchFields.firstMatch.buttons.firstMatch
        if clear.exists { clear.tap() }
        if app.keyboards.count > 0 { app.typeText("\n") }
        sleep(1)
    }

    private func tab(_ title: String) {
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 5) { button.tap() } else { XCTFail("tab \(title)\n\(app.debugDescription)") }
    }
}
