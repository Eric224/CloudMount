import CloudMountLocalization
import CloudMountVaultCore
import Foundation
import XCTest

@testable import CloudMountMobileCore

final class LocalizationAndHealthTests: XCTestCase {
  func testFirstSystemLanguageSelectsChineseScriptAndAllOthersFallBackToEnglish() {
    let matrix: [([String], AppLanguage)] = [
      (["zh-TW"], .traditionalChinese), (["zh-HK"], .traditionalChinese),
      (["zh-MO"], .traditionalChinese),
      (["zh-Hant-CN"], .traditionalChinese), (["zh-Hans-TW"], .simplifiedChinese),
      (["zh-CN"], .simplifiedChinese),
      (["ZH_hAnS_SG"], .simplifiedChinese), (["zh"], .traditionalChinese), (["en-GB"], .english),
      (["ja-JP", "zh-Hant"], .english), (["fr", "zh-Hans", "en"], .english), ([], .english),
    ]
    for (input, expected) in matrix {
      XCTAssertEqual(AppLanguage.resolve(input), expected, input.description)
    }
    XCTAssertEqual(AppLanguage.traditionalChinese.choose("繁體", "简体", "English"), "繁體")
    XCTAssertEqual(AppLanguage.simplifiedChinese.choose("繁體", "简体", "English"), "简体")
    XCTAssertEqual(AppLanguage.english.choose("繁體", "简体", "English"), "English")
  }
  func testReadRecoveryNeverClearsWriteConflictOrQuotaAndHealthContainsNoCredentials() async throws
  {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try await f.service.recordProviderFailure(.conflict, location: f.plain.id, itemID: "file-A")
    var status = try await f.service.recordProviderSuccess(location: f.plain.id, mutation: false)
    XCTAssertEqual(status.issue, .conflict)
    status = try await f.service.recordProviderSuccess(
      location: f.plain.id, mutation: true, itemID: "file-B")
    XCTAssertEqual(status.issue, .conflict)
    status = try await f.service.recordProviderSuccess(
      location: f.plain.id, mutation: true, itemID: "file-A")
    XCTAssertEqual(status.issue, .ready)
    try await f.service.recordProviderFailure(.quota, location: f.plain.id)
    status = try await f.service.recordProviderSuccess(location: f.plain.id, mutation: false)
    XCTAssertEqual(status.issue, .quota)
    status = try await f.service.recordProviderSuccess(location: f.plain.id, mutation: true)
    XCTAssertEqual(status.issue, .ready)
    for issue in [MobileProviderIssue.permission, .unsupported, .uploadFailed] {
      try await f.service.recordProviderFailure(issue, location: f.plain.id)
      status = try await f.service.recordProviderSuccess(location: f.plain.id, mutation: false)
      XCTAssertEqual(status.issue, issue)
      status = try await f.service.recordProviderSuccess(location: f.plain.id, mutation: true)
      XCTAssertEqual(status.issue, .ready)
    }
    for issue in [MobileProviderIssue.offline, .credentials, .deviceLocked] {
      try await f.service.recordProviderFailure(issue, location: f.plain.id)
      status = try await f.service.recordProviderSuccess(location: f.plain.id, mutation: false)
      XCTAssertEqual(status.issue, .ready)
    }
    let json = try String(
      contentsOf: try f.repository.file("provider-health-\(f.plain.id).json"), encoding: .utf8)
    XCTAssertFalse(json.contains("password"))
    XCTAssertFalse(json.contains("Authorization"))
    XCTAssertFalse(json.contains("https://"))
  }
  func testReplayedUploadRequiresExactRemoteContentsAndDoesNotOverwriteNewerEdits() async throws {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let source = f.root.appendingPathComponent("source")
    let stale = f.root.appendingPathComponent("stale")
    try Data("first".utf8).write(to: source)
    let first = try await f.service.create(parent: "root", name: "file.txt", directory: false,
      contents: source, requestID: "file-A", location: f.plain.id)
    try Data("updated with different length".utf8).write(to: source)
    let second = try await f.service.modify(first.id, parent: nil, name: nil,
      contents: source, expected: first.version, location: f.plain.id)
    let replay = try await f.service.reconcileUploadedContents(first.id, contents: source, location: f.plain.id)
    XCTAssertEqual(second.version, replay.version)
    let directReplay = try await f.service.modify(first.id, parent: nil, name: nil,
      contents: source, expected: first.version, location: f.plain.id)
    XCTAssertEqual(directReplay.version, second.version)
    try Data("unrelated stale edit".utf8).write(to: stale)
    do {
      _ = try await f.service.reconcileUploadedContents(first.id, contents: stale, location: f.plain.id)
      XCTFail("A stale write must remain a conflict")
    } catch MobileError.conflict {}
    do {
      _ = try await f.service.modify(first.id, parent: nil, name: "renamed.txt",
        contents: source, expected: first.version, location: f.plain.id)
      XCTFail("Content equality does not acknowledge a rename")
    } catch MobileError.conflict {}
    XCTAssertEqual(try Data(contentsOf: f.cloud.appendingPathComponent("file.txt")), try Data(contentsOf: source))
    XCTAssertTrue(try f.repository.pending(f.plain.id).isEmpty)
  }
  func testLockedVaultRootAndSyncGenerationDoNotRequireCloudCredentialsOrRevealContents()
    async throws
  {
    let f = try MobileCoreTests().fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (vault, _) = try await f.service.createVault(
      connectionID: f.connection.id, parent: "", name: "locked vault",
      password: "long-fixture-password", remember: false)
    try await f.service.lock(vault.id)
    let root = try await f.service.item("root", location: vault.id)
    XCTAssertEqual(root.name, "locked vault")
    XCTAssertTrue(root.directory)
    let generation = try await f.service.providerSyncGeneration(vault.id)
    XCTAssertGreaterThanOrEqual(generation, 0)
    do {
      _ = try await f.service.list("root", location: vault.id)
      XCTFail("Root metadata must not permit content access")
    } catch MobileError.locked {}
  }
}
