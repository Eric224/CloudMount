import CloudMountMobileCore
import CryptoKit
import FileProvider
import XCTest

/// Read-only diagnostics. Never logs paths, filenames, file contents or credentials.
final class PhysicalSyncStatusTests: XCTestCase {
  func testInspectSystemPendingItems() async throws {
    guard ProcessInfo.processInfo.environment["CLOUDMOUNT_DEVICE_READ_TEST"] == "1" else {
      throw XCTSkip("Read-only physical diagnostics require opt-in")
    }
    let service = try MobileEnvironment.service()
    let config = try await service.configuration()
    let domains = try await NSFileProviderManager.domains()
    for (index, location) in config.locations.filter({ $0.removedPath == nil }).enumerated() {
      guard let domain = domains.first(where: { $0.identifier.rawValue == location.id.uuidString }),
        let manager = NSFileProviderManager(for: domain)
      else {
        XCTFail("Missing domain")
        continue
      }
      let health = try service.providerHealth(location.id)
      let catalog = try service.repository.catalog(location.id)
      let pending = try service.repository.pending(location.id)
      print(
        "SYNC-DIAG location=\(index) vault=\(location.isVault) appHealth=\(health?.issue.rawValue ?? "none") journal=\(pending.count) catalog=\(catalog.nodes.count) generation=\(catalog.generation)"
      )
      for (kind, label) in [
        (Progress.FileOperationKind.uploading, "upload"), (.downloading, "download"),
      ] {
        let p = manager.globalProgress(for: kind)
        print(
          "SYNC-DIAG progress=\(label) total=\(p.totalUnitCount) complete=\(p.completedUnitCount) finished=\(p.isFinished) paused=\(p.isPaused)"
        )
      }
      let done = expectation(description: "Pending set")
      let observer = SyncDiagnosticObserver(
        known: Set(catalog.nodes.keys), completion: { done.fulfill() })
      let enumerator = manager.enumeratorForPendingItems()
      observer.enumerator = enumerator
      enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
      await fulfillment(of: [done], timeout: 12)
      enumerator.invalidate()
    }
  }
}
private final class SyncDiagnosticObserver: NSObject, NSFileProviderEnumerationObserver {
  let known: Set<String>, completion: () -> Void
  var enumerator: (any NSFileProviderEnumerator)?
  private var count = 0
  init(known: Set<String>, completion: @escaping () -> Void) {
    self.known = known
    self.completion = completion
  }
  func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
    for item in updatedItems.prefix(100) {
      count += 1
      let raw = item.itemIdentifier.rawValue
      let identifier =
        item.itemIdentifier == .rootContainer
        ? "root"
        : Data(SHA256.hash(data: Data(raw.utf8))).prefix(4).map { String(format: "%02x", $0) }
          .joined()
      func error(_ value: Error?) -> String {
        guard let value else { return "none" }
        let n = value as NSError
        return n.domain + ":" + String(n.code) + ":reason="
          + String(describing: n.userInfo["CloudMountReason"] ?? "none")
      }
      print(
        "SYNC-DIAG item=\(identifier) known=\(known.contains(raw)) uploadError=\(error(item.uploadingError ?? nil)) downloadError=\(error(item.downloadingError ?? nil))"
      )
    }
  }
  func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
    if let nextPage, count < 100 {
      enumerator?.enumerateItems(for: self, startingAt: nextPage)
    } else {
      print("SYNC-DIAG pendingCount=\(count) capped=\(nextPage != nil)")
      completion()
    }
  }
  func finishEnumeratingWithError(_ error: Error) {
    let n = error as NSError
    print("SYNC-DIAG enumerationError=\(n.domain):\(n.code)")
    completion()
  }
}
