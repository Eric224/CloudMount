import CloudMountMobileCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// Inspect only the OS's local cache. Evicting the domain root can itself
/// trigger recursive remote enumeration and stall an otherwise idle domain.
enum MaterializedItems {
  static func files(_ manager: NSFileProviderManager) async throws -> [NSFileProviderItemIdentifier]
  {
    let enumerator = manager.enumeratorForMaterializedItems()
    let observer = MaterializedObserver(enumerator: enumerator)
    defer { enumerator.invalidate() }
    try await SystemSyncBarrier.wait(timeout: 15) { completion in
      observer.completion = completion
      enumerator.enumerateItems(for: observer, startingAt: NSFileProviderPage(Data()))
    }
    return observer.files
  }
}
private final class MaterializedObserver: NSObject, NSFileProviderEnumerationObserver {
  let enumerator: any NSFileProviderEnumerator
  var completion: ((Error?) -> Void)?
  private let lock = NSLock()
  private var identifiers = Set<NSFileProviderItemIdentifier>()
  private var overflow = false
  var files: [NSFileProviderItemIdentifier] {
    lock.lock()
    defer { lock.unlock() }
    return Array(identifiers)
  }
  init(enumerator: any NSFileProviderEnumerator) { self.enumerator = enumerator }
  func didEnumerate(_ items: [NSFileProviderItem]) {
    lock.lock()
    defer { lock.unlock() }
    for item in items
    where item.itemIdentifier != .rootContainer && item.itemIdentifier != .workingSet
      && item.contentType?.conforms(to: .folder) != true
    {
      if identifiers.count >= 10_000 {
        overflow = true
        break
      }
      identifiers.insert(item.itemIdentifier)
    }
  }
  func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
    lock.lock()
    let capped = overflow
    lock.unlock()
    if capped {
      completion?(MobileError.busy)
    } else if let nextPage {
      enumerator.enumerateItems(for: self, startingAt: nextPage)
    } else {
      completion?(nil)
    }
  }
  func finishEnumeratingWithError(_ error: Error) { completion?(error) }
}
