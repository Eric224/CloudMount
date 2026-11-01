import CloudMountMobileCore
import FileProvider
import Foundation

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
  let domain: NSFileProviderDomain
  let id: UUID
  let service: Result<MobileService, Error>
  var vault: Bool {
    (try? service.get().repository.configuration().locations.first(where: { $0.id == id })?.isVault)
      == true
  }
  required init(domain: NSFileProviderDomain) {
    self.domain = domain
    self.id = UUID(uuidString: domain.identifier.rawValue) ?? UUID()
    self.service = Result { try MobileEnvironment.service() }
    super.init()
  }
  init(domain: NSFileProviderDomain, service: MobileService) {
    self.domain = domain
    self.id = UUID(uuidString: domain.identifier.rawValue) ?? UUID()
    self.service = .success(service)
    super.init()
  }
  var readOnly: Bool { (try? service.get().isReadOnly(id)) ?? true }
  private let operations = MobileTaskRegistry(maximum: 8)
  private let thumbnailOperations = MobileTaskRegistry(maximum: 2)
  func invalidate() { operations.invalidate(); thumbnailOperations.invalidate() }
  func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
    perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
    completionHandler: @escaping (Error?) -> Void) -> Progress {
    let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
    let callbacks = ThumbnailBatchCallbacks(progress: progress,
      perItem: perThumbnailCompletionHandler, completion: completionHandler)
    guard itemIdentifiers.count <= 128, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0 else {
      Task { await callbacks.finish(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
      return progress
    }
    let task = thumbnailOperations.start { [self] in
      let deadline = ContinuousClock.now.advanced(by: .seconds(25))
      for item in itemIdentifiers {
        if Task.isCancelled || ContinuousClock.now >= deadline {
          await callbacks.finish(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)); return
        }
        do {
          let remaining = ContinuousClock.now.duration(to: deadline).components
          let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
          let activeService = try service.get()
          let image = try await activeService.thumbnail(identifier(item), location: id,
            dimension: max(size.width, size.height), timeout: min(15, seconds))
          try Task.checkCancellation()
          try await activeService.deliverThumbnail(location: id) { await callbacks.item(item, image, nil) }
        } catch {
          if Task.isCancelled {
            await callbacks.finish(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)); return
          }
          // A failed optional preview must not create a persistent storage-wide
          // synchronization warning or poison otherwise working file access.
          await callbacks.item(item, nil, MobileEnvironment.providerError(error, location: id))
        }
      }
      await callbacks.finish(nil)
    }
    guard let task else {
      Task { await callbacks.finish(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
      return progress
    }
    Task { await callbacks.installCancellation(task) }
    return progress
  }
  func identifier(_ value: NSFileProviderItemIdentifier) -> String {
    value == .rootContainer ? "root" : value.rawValue
  }
  private func operation<T>(
    verifiedRead: Bool = false, mutation: Bool = false, itemID: String? = nil,
    _ work: @escaping @Sendable (MobileService) async throws -> T,
    completion: @escaping (Result<T, Error>) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    let task = operations.start { [self] in
      defer { progress.cancellationHandler = nil }
      do {
        let value = try await work(service.get())
        progress.completedUnitCount = 1
        completion(.success(value))
        if verifiedRead || mutation {
          await MobileEnvironment.didSucceed(
            id, mutation: mutation, itemID: itemID ?? (value as? MobileNode)?.id)
        }
      } catch {
        completion(.failure(MobileEnvironment.providerError(error, location: id)))
        await MobileEnvironment.didFail(error, location: id, itemID: itemID)
      }
    }
    guard let task else {
      completion(.failure(MobileEnvironment.providerError(MobileError.busy, location: id)))
      progress.completedUnitCount = 1
      return progress
    }
    progress.cancellationHandler = { task.cancel() }
    return progress
  }
  func item(
    for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    operation(
      itemID: self.identifier(identifier),
      { service in
        let result = try await service.providerItem(self.identifier(identifier), location: self.id)
        if result.verifiedRemote { await MobileEnvironment.didSucceed(self.id, mutation: false, itemID: self.identifier(identifier)) }
        return result.node
      }
    ) { result in
      switch result {
      case .success(let node):
        completionHandler(FileProviderItem(node, vault: self.vault, readOnly: self.readOnly), nil)
      case .failure(let error): completionHandler(nil, error)
      }
    }
  }
  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier,
    version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    operation(
      verifiedRead: true, itemID: self.identifier(itemIdentifier),
      { service in
        guard let manager = NSFileProviderManager(for: self.domain) else {
          throw MobileError.incomplete
        }
        let directory = try manager.temporaryDirectoryURL()
        let file = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        let item = try await service.download(
          self.identifier(itemIdentifier), location: self.id, to: file)
        return (file, item)
      }
    ) { result in
      switch result {
      case .success(let value):
        completionHandler(
          value.0, FileProviderItem(value.1, vault: self.vault, readOnly: self.readOnly), nil)
      case .failure(let error): completionHandler(nil, nil, error)
      }
    }
  }
  func createItem(
    basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents: URL?,
    options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
    completionHandler:
      @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    operation(
      mutation: true, itemID: itemTemplate.itemIdentifier.rawValue,
      { service in
        guard itemTemplate.contentType?.conforms(to: .symbolicLink) != true else {
          throw MobileError.unsupported
        }
        return try await service.create(
          parent: self.identifier(itemTemplate.parentItemIdentifier), name: itemTemplate.filename,
          directory: itemTemplate.contentType?.conforms(to: .folder) == true, contents: contents,
          requestID: itemTemplate.itemIdentifier.rawValue, location: self.id)
      }
    ) { result in
      switch result {
      case .success(let node):
        completionHandler(
          FileProviderItem(node, vault: self.vault, readOnly: self.readOnly), [], false, nil)
      case .failure(let error): completionHandler(nil, fields, false, error)
      }
    }
  }
  func modifyItem(
    _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields, contents newContents: URL?,
    options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
    completionHandler:
      @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    operation(
      mutation: true, itemID: self.identifier(item.itemIdentifier),
      { service in
        let old = try await service.item(self.identifier(item.itemIdentifier), location: self.id)
        guard FileProviderItem(old).itemVersion.contentVersion == version.contentVersion else {
          guard changedFields == [.contents], let newContents else { throw MobileError.conflict }
          return try await service.reconcileUploadedContents(
            old.id, contents: newContents, location: self.id)
        }
        return try await service.modify(
          old.id,
          parent: changedFields.contains(.parentItemIdentifier)
            ? self.identifier(item.parentItemIdentifier) : nil,
          name: changedFields.contains(.filename) ? item.filename : nil,
          contents: changedFields.contains(.contents) ? newContents : nil, expected: old.version,
          location: self.id)
      }
    ) { result in
      switch result {
      case .success(let node):
        completionHandler(
          FileProviderItem(node, vault: self.vault, readOnly: self.readOnly), [], false, nil)
      case .failure(let error): completionHandler(nil, changedFields, false, error)
      }
    }
  }
  func deleteItem(
    identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
    completionHandler: @escaping (Error?) -> Void
  ) -> Progress {
    operation(
      mutation: true, itemID: self.identifier(identifier),
      { service in
        let old = try await service.item(self.identifier(identifier), location: self.id)
        guard FileProviderItem(old).itemVersion.contentVersion == version.contentVersion else {
          throw MobileError.conflict
        }
        try await service.delete(
          old.id, expected: old.version, recursive: options.contains(.recursive), location: self.id)
      }
    ) { result in
      switch result {
      case .success: completionHandler(nil)
      case .failure(let error): completionHandler(error)
      }
    }
  }
  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
  ) throws -> NSFileProviderEnumerator {
    if containerItemIdentifier == .trashContainer {
      throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
    }
    return FileProviderEnumerator(
      service: try service.get(), location: id, container: containerItemIdentifier)
  }
}

/// An actor serializes callbacks, including the cancellation callback, so the
/// overall completion occurs exactly once and never before a per-item callback.
actor ThumbnailBatchCallbacks {
  private let progress: Progress
  private let perItem: (NSFileProviderItemIdentifier, Data?, Error?) -> Void
  private let completion: (Error?) -> Void
  private var finished = false
  init(progress: Progress, perItem: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
    completion: @escaping (Error?) -> Void) {
    self.progress = progress; self.perItem = perItem; self.completion = completion
  }
  func item(_ id: NSFileProviderItemIdentifier, _ bytes: Data?, _ error: Error?) {
    guard !finished else { return }
    progress.completedUnitCount += 1
    perItem(id, bytes, error)
  }
  func finish(_ error: Error?) {
    guard !finished else { return }
    finished = true; progress.cancellationHandler = nil
    completion(error)
  }
  func installCancellation(_ task: Task<Void, Never>) {
    guard !finished else { return }
    if progress.isCancelled {
      task.cancel(); finish(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)); return
    }
    progress.cancellationHandler = {
      task.cancel()
      Task { await self.finish(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
    }
  }
}
