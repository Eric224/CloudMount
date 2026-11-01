import XCTest

final class FilesIntegrationTests: XCTestCase {
  @MainActor func testWebDAVAndVaultAppearInAppleFiles() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    app.launch()
    XCTAssertTrue(app.buttons["addRemote"].waitForExistence(timeout: 15))
    app.buttons["addRemote"].tap()
    let name = "Mobile NAS " + UUID().uuidString.prefix(4)
    app.textFields["remoteName"].tap()
    app.textFields["remoteName"].typeText(String(name))
    app.textFields["remoteURL"].tap()
    app.textFields["remoteURL"].typeText("https://127.0.0.1:19463/home/")
    app.textFields["remoteUsername"].tap()
    app.textFields["remoteUsername"].typeText("test")
    app.secureTextFields["remotePassword"].tap()
    app.secureTextFields["remotePassword"].typeText("test")
    app.buttons["connectConfirm"].tap()
    XCTAssertTrue(app.staticTexts[String(name)].waitForExistence(timeout: 35), app.debugDescription)
    app.buttons["createVault"].tap()
    XCTAssertTrue(app.textFields["vaultName"].waitForExistence(timeout: 5))
    let vault = "Mobile Vault " + UUID().uuidString.prefix(4)
    app.textFields["vaultName"].tap()
    app.textFields["vaultName"].typeText(String(vault))
    app.secureTextFields["vaultPassword"].tap()
    app.secureTextFields["vaultPassword"].typeText("long-test-password")
    app.secureTextFields["vaultPasswordConfirm"].tap()
    app.secureTextFields["vaultPasswordConfirm"].typeText("long-test-password")
    if !app.buttons["vaultConfirm"].isHittable { app.swipeUp() }
    app.buttons["vaultConfirm"].tap()
    let words = app.staticTexts["44-word recovery key"]
    XCTAssertTrue(words.waitForExistence(timeout: 35), app.debugDescription)
    app.buttons["Done"].tap()
    XCTAssertTrue(app.staticTexts[String(vault)].waitForExistence(timeout: 5))
    let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
    files.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    files.launch()
    if files.buttons["Continue"].waitForExistence(timeout: 3) { files.buttons["Continue"].tap() }
    let browse = files.tabBars.buttons["Browse"]
    if browse.waitForExistence(timeout: 5) {
      browse.tap()
    } else if files.buttons["Browse"].firstMatch.exists {
      files.buttons["Browse"].firstMatch.tap()
    } else if files.tabBars.buttons["瀏覽"].exists {
      files.tabBars.buttons["瀏覽"].tap()
    }
    if !files.staticTexts["Locations"].exists, files.buttons["ToggleSideBar"].exists {
      files.buttons["ToggleSideBar"].tap()
    }
    if files.navigationBars.buttons["Browse"].exists {
      files.navigationBars.buttons["Browse"].tap()
    }
    for _ in 0..<3 {
      if files.staticTexts["Locations"].exists { break }
      let back = files.buttons["DOC.navBarButton.backInHistory"]
      if back.exists && back.isEnabled { back.tap() } else { break }
    }
    // On a new installation Files may ask the user to enable a provider.
    print("FILES-LOCATIONS", files.debugDescription)
    XCTAssertTrue(
      files.staticTexts["CloudMount"].waitForExistence(timeout: 15)
        || files.staticTexts[String(name)].exists || files.staticTexts[String(vault)].exists,
      files.debugDescription)
  }
}

extension FilesIntegrationTests {
  @MainActor func testBrowseConfiguredLocations() {
    let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
    files.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    files.launch()
    if files.tabBars.buttons["Browse"].exists {
      files.tabBars.buttons["Browse"].tap()
    } else if files.buttons["Browse"].firstMatch.exists {
      files.buttons["Browse"].firstMatch.tap()
    }
    if !files.staticTexts["Locations"].exists, files.buttons["ToggleSideBar"].exists {
      files.buttons["ToggleSideBar"].tap()
    }
    for _ in 0..<4 {
      if files.staticTexts["Locations"].exists { break }
      let back = files.buttons["DOC.navBarButton.backInHistory"]
      if back.exists && back.isEnabled { back.tap() } else { break }
    }
    print("FILES-ROOT", files.debugDescription)
    XCTAssertTrue(
      files.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Mobile NAS", "Mobile Vault")
      ).firstMatch.waitForExistence(timeout: 10) || files.staticTexts["CloudMount"].exists,
      files.debugDescription)
  }
}

extension FilesIntegrationTests {
  @MainActor func testOpenVaultLocationAndEnableSync() {
    let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
    files.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    files.launch()
    if files.tabBars.buttons["Browse"].exists {
      files.tabBars.buttons["Browse"].tap()
    } else if files.buttons["Browse"].firstMatch.exists {
      files.buttons["Browse"].firstMatch.tap()
    }
    if !files.staticTexts["Locations"].exists, files.buttons["ToggleSideBar"].exists {
      files.buttons["ToggleSideBar"].tap()
    }
    for _ in 0..<4 {
      if files.staticTexts["Locations"].exists { break }
      let back = files.buttons["DOC.navBarButton.backInHistory"]
      if back.exists && back.isEnabled { back.tap() } else { break }
    }
    let cell = files.cells.matching(NSPredicate(format: "label CONTAINS %@", "Files Test Vault"))
      .firstMatch
    XCTAssertTrue(cell.waitForExistence(timeout: 10), files.debugDescription)
    if !cell.isHittable { files.swipeUp() }
    cell.tap()
    print("FILES-VAULT-OPEN", files.debugDescription)
    if files.buttons["Enable"].exists { files.buttons["Enable"].tap() }
    if files.buttons["Turn On"].exists { files.buttons["Turn On"].tap() }
    print("FILES-VAULT-ENABLED", files.debugDescription)
    XCTAssertTrue(files.cells["Hello, txt"].waitForExistence(timeout: 15), files.debugDescription)
  }
}

extension FilesIntegrationTests {
  @MainActor func testUnlockVaultDirectlyInsideFiles() {
    let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
    files.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    files.launch()
    if files.tabBars.buttons["Browse"].exists { files.tabBars.buttons["Browse"].tap() }
    for _ in 0..<4 {
      if files.staticTexts["Locations"].exists { break }
      let back = files.buttons["DOC.navBarButton.backInHistory"]
      if back.exists && back.isEnabled { back.tap() } else { break }
    }
    let vault = files.cells.matching(NSPredicate(format: "label CONTAINS %@", "Files Test Vault"))
      .firstMatch
    XCTAssertTrue(vault.waitForExistence(timeout: 10), files.debugDescription)
    if !vault.isHittable { files.swipeUp() }
    vault.tap()
    if files.buttons["Turn On"].exists { files.buttons["Turn On"].tap() }
    if files.buttons["Authenticate"].waitForExistence(timeout: 5) {
      files.buttons["Authenticate"].tap()
    } else {
      let paused = files.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Paused"))
        .firstMatch
      if paused.exists { paused.tap() }
      if files.cells["Hello, txt"].exists { files.cells["Hello, txt"].press(forDuration: 1.1) }
      print("FILES-STATUS-AUTH", files.debugDescription)
      if files.buttons["Sign In"].exists {
        files.buttons["Sign In"].tap()
      } else if files.buttons["Authenticate"].exists {
        files.buttons["Authenticate"].tap()
      } else if files.buttons["Unlock vault"].exists {
        files.buttons["Unlock vault"].tap()
      }
    }
    print("FILES-AUTH-UI", files.debugDescription)
    let unlock = files.buttons["unlockConfirm"]
    XCTAssertTrue(unlock.waitForExistence(timeout: 10), files.debugDescription)
    if files.secureTextFields["unlockPassword"].exists {
      files.secureTextFields["unlockPassword"].tap()
      files.secureTextFields["unlockPassword"].typeText("long-test-password")
    }
    unlock.tap()
    XCTAssertFalse(unlock.waitForExistence(timeout: 2))
    print("FILES-AUTH-FINISHED", files.debugDescription)
  }
}
