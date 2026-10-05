import XCTest

/// End-to-end: real drives, real SMART through the sandbox, a real (tiny) benchmark on the startup volume.
final class ODiskE2ETests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ODiskTinyBenchmark", "YES", "-ODiskResetOnLaunch", "YES", "-showMenuBarExtra", "NO"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    func testHealthPageShowsStartupDrive() {
        let header = app.descendants(matching: .any)["driveHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 15), "drive header missing")
        // Every Apple silicon Mac's internal SSD reports NVMe health, so the ring must appear.
        let ring = app.descendants(matching: .any)["healthRing"]
        XCTAssertTrue(ring.waitForExistence(timeout: 15), "health ring missing — SMART read failed inside the sandbox?")
        XCTAssertTrue(app.descendants(matching: .any)["metric.Temperature"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["metric.Data written"].exists)
        attach("health")
    }

    func testSpeedTestRunsAndSavesHistory() {
        XCTAssertTrue(app.descendants(matching: .any)["driveHeader"].waitForExistence(timeout: 15))
        app.typeKey("2", modifierFlags: .command)
        let run = app.buttons["runBenchmark"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        run.click()
        XCTAssertTrue(app.buttons["stopBenchmark"].waitForExistence(timeout: 10), "benchmark didn't start")
        XCTAssertTrue(run.waitForExistence(timeout: 120), "benchmark didn't finish")
        for label in ["SEQ1M Q8T1", "SEQ1M Q1T1", "RND4K Q32T1", "RND4K Q1T1"] {
            for kind in ["read", "write"] {
                let cell = app.descendants(matching: .any)["result.\(label).\(kind)"]
                XCTAssertTrue(cell.exists, "\(label) \(kind) missing")
                XCTAssertNotEqual(cell.value as? String, "not measured", "\(label) \(kind) has no value")
            }
        }
        XCTAssertFalse(app.descendants(matching: .any)["benchmarkError"].exists)
        let status = app.staticTexts["benchmarkStatus"]
        XCTAssertTrue((status.value as? String ?? status.label).contains("Last run"), "history not saved: \(status.label)")
        attach("benchmark")
    }

    func testDetailsTabListsSMARTValues() {
        XCTAssertTrue(app.descendants(matching: .any)["driveHeader"].waitForExistence(timeout: 15))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Power-on hours"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["copyReport"].exists)
        app.buttons["copyReport"].click()
        attach("details")
    }

    private func attach(_ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
