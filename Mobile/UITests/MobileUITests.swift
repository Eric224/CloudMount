import XCTest

final class MobileUITests: XCTestCase {
  @MainActor func testSystemLanguagesTraditionalSimplifiedAndUnsupportedFallback() {
    let cases = [
      ("(zh-Hant-TW)", "新增空間", "Drime 存取權杖"), ("(zh-Hans-CN)", "添加空间", "Drime 访问令牌"),
      ("(fr-FR,zh-Hant)", "Connect storage", "Drime access token"),
    ]
    for (languages, title, tokenLabel) in cases {
      let app = XCUIApplication()
      app.launchArguments = ["-AppleLanguages", languages, "-AppleLocale", "fr_FR"]
      app.launch()
      XCTAssertTrue(app.buttons["addRemote"].waitForExistence(timeout: 15))
      app.buttons["addRemote"].tap()
      XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), languages)
      app.buttons["remoteType"].tap()
      app.buttons["Drime"].tap()
      XCTAssertTrue(app.secureTextFields["drimeToken"].waitForExistence(timeout: 5))
      XCTAssertEqual(app.secureTextFields["drimeToken"].placeholderValue, tokenLabel, languages)
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = "Language-" + languages
      attachment.lifetime = .keepAlways
      add(attachment)
      app.terminate()
    }
  }
  @MainActor func testDrimeFormOnlyRequiresTokenAndHidesAdvancedSettings() {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.buttons["addRemote"].waitForExistence(timeout: 15))
    XCTAssertFalse(
      app.alerts.firstMatch.waitForExistence(timeout: 2), app.alerts.firstMatch.debugDescription)
    app.buttons["addRemote"].tap()
    app.buttons["remoteType"].tap()
    app.buttons["Drime"].tap()
    XCTAssertTrue(app.secureTextFields["drimeToken"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["remoteURL"].exists)
    XCTAssertFalse(app.textFields["remoteUsername"].exists)
    XCTAssertFalse(app.textFields["drimeWorkspace"].exists)
    XCTAssertFalse(app.buttons["connectConfirm"].isEnabled)
    app.secureTextFields["drimeToken"].tap()
    app.secureTextFields["drimeToken"].typeText("fixture-not-a-real-token")
    XCTAssertTrue(app.buttons["connectConfirm"].isEnabled)
    // Do not connect, register a domain or send this fixture value to the live service.
  }
  @MainActor func testBeginnerFormsDoNotRequireTerminalOrAdvancedSettings() {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.buttons["addRemote"].waitForExistence(timeout: 15))
    app.buttons["addRemote"].tap()
    XCTAssertTrue(app.textFields["remoteName"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["remoteURL"].exists)
    XCTAssertTrue(app.secureTextFields["remotePassword"].exists)
    XCTAssertFalse(app.buttons["connectConfirm"].isEnabled)
    XCTAssertFalse(app.staticTexts["vendor"].exists)
  }

  @MainActor func testBrandFormsPrefillAddressesAndClearCredentialsWhenSwitching() {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.buttons["addRemote"].waitForExistence(timeout: 15))
    app.buttons["addRemote"].tap()
    app.buttons["remoteType"].tap()
    app.buttons["pCloud"].tap()
    XCTAssertTrue(app.textFields["remoteUsername"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["remoteURL"].exists)
    XCTAssertFalse(app.buttons["connectConfirm"].isEnabled)
    app.textFields["remoteUsername"].tap()
    app.textFields["remoteUsername"].typeText("fixture@example.invalid")
    app.buttons["remoteType"].tap()
    app.buttons["Koofr"].tap()
    XCTAssertFalse(app.textFields["remoteURL"].exists)
    XCTAssertEqual(app.textFields["remoteUsername"].value as? String, "Username")
    XCTAssertFalse(app.buttons["connectConfirm"].isEnabled)
    app.buttons["remoteType"].tap()
    app.buttons["Nextcloud"].tap()
    XCTAssertTrue(app.textFields["remoteURL"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["connectConfirm"].isEnabled)
    // No credentials are submitted and no Files locations are created.
  }
  @MainActor func testS3PresetsOnlyAskForRelevantConnectionDetails() {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.buttons["addRemote"].waitForExistence(timeout: 15))
    app.buttons["addRemote"].tap()
    app.buttons["remoteType"].tap()
    app.buttons["S3 / MinIO / R2"].tap()
    XCTAssertTrue(app.textFields["s3Bucket"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["s3Region"].exists)
    XCTAssertFalse(app.textFields["s3Endpoint"].exists)
    app.buttons["s3Preset"].tap()
    app.buttons["Cloudflare R2"].tap()
    XCTAssertTrue(app.textFields["s3Account"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["s3Region"].exists)
    XCTAssertFalse(app.textFields["s3Endpoint"].exists)
    XCTAssertFalse(app.buttons["connectConfirm"].isEnabled)
    app.buttons["s3Preset"].tap()
    app.buttons["MinIO / S3-compatible"].tap()
    XCTAssertTrue(app.textFields["s3Endpoint"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["s3Account"].exists)
    XCTAssertFalse(app.textFields["s3Region"].exists)
    XCTAssertFalse(app.secureTextFields["Session token (optional)"].exists)
  }
}

extension MobileUITests {
  @MainActor func testS3RequiredBucketAndOptionalPrefixAndURLStyle() {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.buttons["addRemote"].waitForExistence(timeout: 15))
    app.buttons["addRemote"].tap()
    app.buttons["remoteType"].tap()
    app.buttons["S3 / MinIO / R2"].tap()
    XCTAssertTrue(app.textFields["s3Bucket"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.textFields["s3Bucket"].placeholderValue, "Bucket name (required)")
    XCTAssertFalse(app.buttons["connectConfirm"].isEnabled)
    XCTAssertFalse(app.textFields["s3Prefix"].exists)
    app.buttons["Advanced (usually unnecessary)"].tap()
    app.swipeUp()
    XCTAssertTrue(app.textFields["s3Prefix"].exists)
    XCTAssertTrue(app.buttons["s3URLStyle"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "S3 advanced connection settings"; screenshot.lifetime = .keepAlways; add(screenshot)
    app.terminate()
  }
  @MainActor func testBrowsingSettingsAreTranslatedAndCacheClearIsExplicit() {
    for (language, title) in [("(zh-Hant)", "瀏覽與快取"), ("(zh-Hans)", "浏览与缓存"), ("(fr)", "Browsing and cache")] {
      let app = XCUIApplication()
      app.launchArguments = ["-AppleLanguages", language]
      app.launch()
      XCTAssertTrue(app.buttons["openAbout"].waitForExistence(timeout: 15))
      app.buttons["openAbout"].tap()
      app.buttons["openBrowsingSettings"].tap()
      XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
      XCTAssertTrue(app.switches["cacheThumbnails"].exists)
      XCTAssertTrue(app.steppers["thumbnailLimit"].exists)
      XCTAssertTrue(app.steppers["thumbnailRetention"].exists)
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "Browsing cache " + language; screenshot.lifetime = .keepAlways; add(screenshot)
      app.terminate()
    }
  }
}
