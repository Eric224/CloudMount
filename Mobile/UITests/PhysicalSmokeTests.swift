import XCTest

final class PhysicalSmokeTests: XCTestCase {
  @MainActor func testInspectCloudMountLocationSyncIndicators() throws {
    let app=XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["openFiles"].waitForExistence(timeout:20))
    app.buttons["openFiles"].tap()
    let initialBack=app.buttons["DOC.navBarButton.backInHistory"]
    _ = initialBack.waitForExistence(timeout:10)
    for _ in 0..<8 {
      if app.staticTexts.matching(NSPredicate(format:"label == %@","CloudMount")).count>=2 {break}
      let back=app.buttons["DOC.navBarButton.backInHistory"]
      if back.exists && back.isEnabled {back.tap()}
      else {
        let bar=app.navigationBars.firstMatch
        guard bar.exists else {break}
        bar.coordinate(withNormalizedOffset:CGVector(dx:0.08,dy:0.5)).tap()
      }
    }
    guard app.staticTexts.matching(NSPredicate(format:"label == %@","CloudMount")).count>=2,
      !app.buttons["openFiles"].exists else {
      throw XCTSkip("Could not reach the Files location list; warning-icon verification is inconclusive")
    }
    let screenshot=XCTAttachment(screenshot:app.screenshot())
    screenshot.name="CloudMount Files locations after sync fix";screenshot.lifetime = .keepAlways;add(screenshot)
    print("FILES-INDICATOR cloudmountLabels=\(app.staticTexts.matching(NSPredicate(format:"label == %@","CloudMount")).count)")
    for cell in app.cells.containing(.staticText,identifier:"CloudMount").allElementsBoundByIndex {
      print("FILES-INDICATOR symbols=\(cell.images.allElementsBoundByIndex.map(\.label))")
    }
    // Observe location indicators only. Never select a document or alter a registration.
    app.terminate()
  }
  @MainActor func testLaunchAboutAndExistingFilesLocations() {
    let app = XCUIApplication()
    app.launchArguments = []
    app.launch()
    XCTAssertTrue(app.buttons["openAbout"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.alerts.firstMatch.exists, "Startup showed an error")
    app.buttons["openAbout"].tap()
    XCTAssertTrue(app.staticTexts["appVersion"].waitForExistence(timeout: 5))
    let bundle = Bundle(for: Self.self)
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    XCTAssertTrue(app.staticTexts["appVersion"].label.contains("\(version) (\(build))"))
    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "俊宇")).firstMatch.exists)
    XCTAssertTrue(app.links.matching(NSPredicate(format: "label CONTAINS %@", "naoki@duck.com")).firstMatch.exists)
    let about = XCTAttachment(screenshot: app.screenshot())
    about.name = "Physical About"; about.lifetime = .keepAlways; add(about)
    let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "Done"])).firstMatch
    XCTAssertTrue(done.exists); done.tap()
    XCTAssertTrue(app.buttons["openFiles"].exists)
    app.buttons["openFiles"].tap()
    let pickerReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      app.navigationBars.allElementsBoundByIndex.contains { $0.identifier.contains("CloudMount") && $0.identifier != "CloudMount" }
    }, object: nil)
    _ = XCTWaiter.wait(for: [pickerReady], timeout: 10)
    let browser = XCTAttachment(screenshot: app.screenshot())
    browser.name = "Physical document picker"; browser.lifetime = .keepAlways; add(browser)
    XCTAssertFalse(app.alerts.firstMatch.exists, "Document picker showed an error")
    // Do not select, preview, edit, or delete a user document.
    app.terminate()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    springboard.activate()
    let icon = springboard.icons["CloudMount"].firstMatch
    if icon.waitForExistence(timeout: 3) {
      let attachment = XCTAttachment(screenshot: icon.screenshot())
      attachment.name = "Physical home screen icon"; attachment.lifetime = .keepAlways; add(attachment)
    }
  }
}
