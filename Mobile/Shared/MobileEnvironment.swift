import CloudMountMobileCore
import CloudMountVaultCore
import FileProvider
import Foundation

struct MobileEnvironment {
  private static let recovery = ProviderRecoveryState()
  static let group = "group.com.codex.cloudmount.mobile"
  static func service() throws -> MobileService {
    guard
      let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
        .appendingPathComponent("CloudMount", isDirectory: true)
    else { throw MobileError.incomplete }
    let repository = try MobileRepository(root: root)
    let group = Bundle.main.object(forInfoDictionaryKey: "CloudMountKeychainGroup") as? String
    return MobileService(repository: repository, secrets: MobileKeychain(accessGroup: group))
  }
  static func domain(_ location: MobileLocation) -> NSFileProviderDomain {
    return NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(location.id.uuidString),
      displayName: location.name)
  }
  static func publish(_ location: MobileLocation) async throws {
    try await NSFileProviderManager.add(domain(location))
    try await service().refreshProviderMetadata(location.id)
    if location.isVault, (try? service().isUnlocked(location.id)) == true {
      await didUnlock(location.id)
    } else {
      await signal(location.id)
    }
  }
  static func signal(_ id: UUID) async {
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(id.uuidString), displayName: "CloudMount")
    guard let manager = NSFileProviderManager(for: domain) else { return }
    try? await manager.signalEnumerator(for: .rootContainer)
    try? await manager.signalEnumerator(for: .workingSet)
  }
  static func signalWorkingSet(_ id: UUID) async {
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(id.uuidString), displayName: "CloudMount")
    if let manager = NSFileProviderManager(for: domain) {
      try? await manager.signalEnumerator(for: .workingSet)
    }
  }
  static func didReadRemote(_ id: UUID) async {
    await didSucceed(id, mutation: false)
  }
  static func didFail(_ error: Error, location: UUID, itemID: String? = nil) async {
    recovery.resetLocation(location)
    guard let issue = ProviderErrorPolicy.issue(error) else { return }
    try? await service().recordProviderFailure(issue, location: location, itemID: itemID)
  }
  static func didSucceed(_ id: UUID, mutation: Bool, itemID: String? = nil) async {
    do {
      let service = try service()
      let previous = try service.providerHealth(id)
      let status = try await service.recordProviderSuccess(
        location: id, mutation: mutation, itemID: itemID)
      let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(id.uuidString), displayName: "CloudMount")
      guard let manager = NSFileProviderManager(for: domain) else { return }
      var codes: [NSFileProviderError.Code] = [.serverUnreachable, .notAuthenticated]
      if mutation, status.issue == .ready, try service.repository.pending(id).isEmpty {
        if previous?.issue == .quota { codes.append(.insufficientQuota) }
        if previous?.issue == .conflict, itemID != nil, previous?.itemID == itemID {
          codes.append(.cannotSynchronize)
        }
      }
      for code in codes {
        let key = "\(id):\(status.eventID):\(code.rawValue)"
        guard recovery.claim(key) else { continue }
        do {
          try await manager.signalErrorResolved(
            NSError(domain: NSFileProviderErrorDomain, code: code.rawValue))
        } catch { recovery.reset(key) }
      }
    } catch { /* Device protection may temporarily prevent access. Keep the OS error for retry. */
    }
  }
  static func checkConnection(_ location: MobileLocation) async throws {
    recovery.resetLocation(location.id)
    let service = try service()
    do {
      _ = try await service.list("root", location: location.id)
      await didReadRemote(location.id)
      await signal(location.id)
    } catch {
      await didFail(error, location: location.id)
      throw error
    }
  }
  static func recheckWriteSupport(_ connectionID: UUID) async throws {
    let service = try service()
    try await service.recheckWriteSupport(connectionID)
    for location in try await service.configuration().locations
    where location.connectionID == connectionID && location.removedPath == nil {
      try await service.refreshProviderMetadata(location.id)
      await signal(location.id)
    }
  }
  static func suspend(_ location: MobileLocation) async throws {
    let service = try service()
    var removed = false
    do {
      try await service.setLocationSuspended(location.id, suspended: true) { value in
        let registered = try await NSFileProviderManager.domains().contains {
          $0.identifier.rawValue == value.id.uuidString
        }
        if registered {
          if value.isVault {
            try await lock(value)
          } else if let manager = NSFileProviderManager(for: domain(value)) {
            try await prepareToDisconnect(manager)
          }
          try await NSFileProviderManager.remove(domain(value))
          removed = true
        } else if value.isVault {
          try await service.lock(value.id)
        }
      }
    } catch {
      // Restore registration if the local state could not be committed.
      if removed {
        try? await NSFileProviderManager.add(domain(location))
        await signal(location.id)
      }
      throw error
    }
  }
  static func resume(_ location: MobileLocation) async throws {
    try await service().setLocationSuspended(location.id, suspended: false) { value in
      try await NSFileProviderManager.add(domain(value))
    }
    try await service().refreshProviderMetadata(location.id)
    await signal(location.id)
  }
  static func retryUploads(_ location: MobileLocation) async throws {
    let service = try service()
    let pending = try service.repository.pending(location.id)
    try await service.retryPending(location.id)
    for value in pending { await didSucceed(location.id, mutation: true, itemID: value.nodeID) }
    await signal(location.id)
  }
  static func removeConnection(_ connection: MobileConnection) async throws {
    let service = try service()
    let progress = RemovedDomainTracker()
    do {
      try await service.removeConnection(connection.id) { locations in
        let domains = try await NSFileProviderManager.domains()
        let registered = Set(domains.map { $0.identifier.rawValue })
        for value in locations where value.removedPath == nil {
          guard registered.contains(value.id.uuidString) else {
            if value.isVault { try await service.lock(value.id) }
            continue
          }
          if value.isVault {
            if try service.isUnlocked(value.id) { try await lock(value) }
          } else if let manager = NSFileProviderManager(for: domain(value)) {
            try await SystemSyncBarrier.wait(manager)
          }
        }
        for value in locations where registered.contains(value.id.uuidString) {
          try await NSFileProviderManager.remove(domain(value))
          await progress.removed(value)
        }
      }
    } catch {
      for value in await progress.values { try? await publish(value) }
      throw error
    }
  }
  static func didUnlock(_ id: UUID) async {
    recovery.resetLocation(id)
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(id.uuidString), displayName: "CloudMount")
    if let value = try? service().repository.configuration().locations.first(where: { $0.id == id })
    {
      if value.isVault, (try? service().isUnlocked(id)) != true {
        await signal(id)
        return
      }
    }
    do {
      let service = try service()
      try await service.refreshProviderMetadata(id)
      _ = try await service.list("root", location: id)
      await didReadRemote(id)
    } catch { await didFail(error, location: id) }
    await signal(id)
  }
  static func lock(_ location: MobileLocation) async throws {
    let service = try service()
    guard let manager = NSFileProviderManager(for: domain(location)) else {
      throw MobileError.incomplete
    }
    // The OS barrier reports unsynchronized writes; do not evict or clear
    // keys if any application edit has not been acknowledged by the provider.
    try await prepareToDisconnect(manager)
    try await service.lock(location.id)
    try? await service.recordProviderFailure(.vaultLocked, location: location.id)
    // Keep the registered domain stable. Re-registering it during a key
    // transition can wait on File Provider reconciliation of that same domain.
    // Key removal and authentication errors enforce the lock independently.
    await signal(location.id)
  }
  private static func prepareToDisconnect(_ manager: NSFileProviderManager) async throws {
    try await SystemSyncBarrier.wait(manager)
    let files = try await MaterializedItems.files(manager)
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    for identifier in files {
      guard ContinuousClock.now < deadline else { throw MobileError.busy }
      do {
        try await SystemSyncBarrier.wait(timeout: 15) { completion in
          manager.evictItem(identifier: identifier, completionHandler: completion)
        }
      } catch let error as NSError
        where error.domain == NSFileProviderErrorDomain
        && error.code == NSFileProviderError.noSuchItem.rawValue
      { continue }
    }
    try await SystemSyncBarrier.wait(manager)
  }
  static func providerError(_ error: Error, location: UUID) -> NSError {
    ProviderErrorPolicy.error(error, location: location)
  }
}
private actor RemovedDomainTracker {
  private(set) var values: [MobileLocation] = []
  func removed(_ value: MobileLocation) { values.append(value) }
}
private final class ProviderRecoveryState: @unchecked Sendable {
  private let lock = NSLock()
  private var recovered = Set<String>()
  func claim(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if recovered.count > 1024 { recovered.removeAll() }
    return recovered.insert(id).inserted
  }
  func resetLocation(_ id: UUID) {
    lock.lock()
    recovered = recovered.filter { !$0.hasPrefix("\(id):") }
    lock.unlock()
  }
  func reset(_ id: String) {
    lock.lock()
    recovered.remove(id)
    lock.unlock()
  }
}
func T(_ traditional: String, _ simplified: String, _ english: String) -> String {
  MobileText.text(traditional, simplified, english)
}
