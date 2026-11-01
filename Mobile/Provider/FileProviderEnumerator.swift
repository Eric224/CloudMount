import CloudMountMobileCore
import FileProvider
import Foundation

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
  let service: MobileService, location: UUID, container: NSFileProviderItemIdentifier
  private let tasks = MobileTaskRegistry(maximum: 3)
  private let pages = MobileEnumerationPages()
  private let directoryPages: MobileProviderDirectoryPages
  private let changesState = ChangeScanState()
  init(service: MobileService, location: UUID, container: NSFileProviderItemIdentifier) {
    self.service = service
    self.location = location
    self.container = container
    self.directoryPages = MobileProviderDirectoryPages(service: service, location: location,
      parent: container == .rootContainer ? "root" : container.rawValue)
  }
  func invalidate() {
    tasks.invalidate()
    Task { await pages.invalidate() }
    Task { await directoryPages.invalidate() }
  }
  private func flags() throws -> (vault: Bool, readOnly: Bool) {
    guard
      let value = try service.repository.configuration().locations.first(where: {
        $0.id == location && $0.removedPath == nil && $0.suspended != true
      })
    else { throw MobileError.missing }
    return (value.isVault, try service.isReadOnly(location))
  }
  func enumerateItems(
    for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
  ) {
    guard
      tasks.start({ [self] in
        do {
          let result: MobileEnumerationPage
          let size = max(1, min(200, observer.suggestedPageSize ?? 200))
          let initial =
            page.rawValue == (NSFileProviderPage.initialPageSortedByName as Data)
            || page.rawValue == (NSFileProviderPage.initialPageSortedByDate as Data)
            || page.rawValue.isEmpty
          if initial {
            if container == .workingSet {
              let nodes = Array(try await service.catalog(location).nodes.values)
              let sorted = nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
              result = try await pages.start(sorted, size: size)
            } else {
              result = try await directoryPages.first(size: size,
                byDate: page.rawValue == (NSFileProviderPage.initialPageSortedByDate as Data))
            }
          } else {
            // Revalidate lock state on every page. A snapshot never grants access.
            try await service.validateProviderAccess(location)
            guard let token = String(data: page.rawValue, encoding: .utf8) else {
              throw MobileError.expiredPage
            }
            if container == .workingSet { result = try await pages.next(token, size: size) }
            else { result = try await directoryPages.next(token, size: size) }
          }
          try Task.checkCancellation()
          let policy = try flags()
          observer.didEnumerate(
            result.nodes.map {
              FileProviderItem($0, vault: policy.vault, readOnly: policy.readOnly)
            })
          observer.finishEnumerating(upTo: result.next.map { NSFileProviderPage(Data($0.utf8)) })
          if result.verifiedRemote, container != .workingSet {
            await MobileEnvironment.didReadRemote(location)
            if result.next == nil { await MobileEnvironment.signalWorkingSet(location) }
          }
        } catch {
          observer.finishEnumeratingWithError(
            MobileEnvironment.providerError(error, location: location))
          await MobileEnvironment.didFail(error, location: location)
        }
      }) != nil
    else {
      observer.finishEnumeratingWithError(
        MobileEnvironment.providerError(MobileError.busy, location: location))
      return
    }
  }
  func enumerateChanges(
    for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor
  ) {
    guard
      tasks.start({ [self] in
        do {
          guard let text = String(data: syncAnchor.rawValue, encoding: .utf8),
            let since = Int64(text)
          else { throw NSFileProviderError(.syncAnchorExpired) }
          var verifiedRemote = false
          if container != .workingSet, await changesState.shouldRefresh(since) {
            let parent = container == .rootContainer ? "root" : container.rawValue
            if try await service.cachedProviderDirectoryForChanges(parent, location: location) == false {
              try await service.refreshProviderDirectory(parent, location: location)
              verifiedRemote = true
            }
          }
          let catalog = try await service.catalog(location)
          guard since <= catalog.generation, since >= (catalog.changes.first?.generation ?? 1) - 1
          else { throw NSFileProviderError(.syncAnchorExpired) }
          let changes = catalog.changes.filter { $0.generation > since }
          let size = max(1, min(200, observer.suggestedBatchSize ?? 200))
          let batch = Array(changes.prefix(size))
          let ids = Set(batch.map(\.id))
          let deleted = ids.filter { catalog.nodes[$0] == nil }.map {
            NSFileProviderItemIdentifier($0)
          }
          let updated = ids.compactMap { catalog.nodes[$0] }.filter {
            container == .workingSet
              || $0.parent == (container == .rootContainer ? "root" : container.rawValue)
          }
          try Task.checkCancellation()
          let policy = try flags()
          observer.didDeleteItems(withIdentifiers: deleted)
          observer.didUpdate(
            updated.map { FileProviderItem($0, vault: policy.vault, readOnly: policy.readOnly) })
          let more = changes.count > batch.count
          let anchor = more ? (batch.last?.generation ?? since) : catalog.generation
          await changesState.finished(anchor, more: more)
          observer.finishEnumeratingChanges(
            upTo: NSFileProviderSyncAnchor(Data(String(anchor).utf8)), moreComing: more)
          if verifiedRemote {
            await MobileEnvironment.didReadRemote(location)
            await MobileEnvironment.signalWorkingSet(location)
          }
        } catch {
          observer.finishEnumeratingWithError(
            MobileEnvironment.providerError(error, location: location))
          await MobileEnvironment.didFail(error, location: location)
        }
      }) != nil
    else {
      observer.finishEnumeratingWithError(
        MobileEnvironment.providerError(MobileError.busy, location: location))
      return
    }
  }
  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    guard
      tasks.start({ [self] in
        do {
          let generation = try await service.providerSyncGeneration(location)
          completionHandler(NSFileProviderSyncAnchor(Data(String(generation).utf8)))
        } catch { completionHandler(nil) }
      }) != nil
    else {
      completionHandler(nil)
      return
    }
  }
}

private actor ChangeScanState {
  private var continuation: Int64?
  func shouldRefresh(_ anchor: Int64) -> Bool { continuation != anchor }
  func finished(_ anchor: Int64, more: Bool) { continuation = more ? anchor : nil }
}
