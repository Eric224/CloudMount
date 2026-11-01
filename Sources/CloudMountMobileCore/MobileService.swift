import CloudMountVaultCore
import CryptoKit
import Foundation

public struct MobileService: Sendable {
  public let repository: MobileRepository
  public let secrets: any MobileSecrets
  private let factory: (@Sendable (MobileConnection) throws -> any CiphertextStore)?
  public init(
    repository: MobileRepository, secrets: any MobileSecrets,
    storeFactory: (@Sendable (MobileConnection) throws -> any CiphertextStore)? = nil
  ) {
    self.repository = repository
    self.secrets = secrets
    self.factory = storeFactory
  }
  private func store(_ connection: MobileConnection) throws -> any CiphertextStore {
    BudgetedStore(repository:repository,factory:{ try rawStore(connection) })
  }
  private func rawStore(_ connection: MobileConnection) throws -> any CiphertextStore {
    if let factory { return try factory(connection) }
    guard let data = try secrets.read("connection-\(connection.id)") else {
      throw MobileError.credential
    }
    if let settings = connection.drime {
      guard let token = String(data: data, encoding: .utf8) else { throw MobileError.credential }
      return try DrimeStore(
        token: token, settings: settings, repository: repository, connectionID: connection.id)
    }
    if let settings = connection.s3 {
      let keys = try JSONDecoder().decode(S3Credentials.self, from: data)
      return try S3Store(
        endpoint: connection.endpoint, settings: settings, credentials: keys, journal: repository)
    }
    guard let password = String(data: data, encoding: .utf8) else { throw MobileError.credential }
    if let settings = connection.fileServer {
      if settings.kind == .sftp {
        return try SFTPStore(
          endpoint: connection.endpoint, settings: settings, username: connection.username,
          password: password)
      }
      return try FTPStore(
        endpoint: connection.endpoint, settings: settings, username: connection.username,
        password: password)
    }
    return try WebDAVStore(
      endpoint: connection.endpoint, username: connection.username, password: password)
  }
  public func configuration() async throws -> MobileConfiguration {
    try Task.checkCancellation()
    let lease = try await repository.lease("configuration")
    defer { withExtendedLifetime(lease) {} }
    return try repository.configuration()
  }
  private func location(_ id: UUID, allowSuspended: Bool = false) throws -> (MobileLocation, MobileConnection) {
    let config = try repository.configuration()
    guard let value = config.locations.first(where: { $0.id == id }), value.removedPath == nil, (allowSuspended || value.suspended != true),
      let connection = config.connections.first(where: { $0.id == value.connectionID })
    else { throw MobileError.missing }
    return (value, connection)
  }
  public func isUnlocked(_ id: UUID) throws -> Bool { try secrets.read("active-\(id)") != nil }
  public func canUnlockWithoutPassword(_ id: UUID) throws -> Bool {
    try secrets.read("remembered-\(id)") != nil
  }
  public func addWebDAV(name: String, endpoint: URL, username: String, password: String)
    async throws -> MobileLocation
  {
    let ioSlot = try await MobileResourceGate.shared.acquire(repository)
    defer { withExtendedLifetime(ioSlot) {} }

    let connection = MobileConnection(
      name: try MobilePath.name(name), endpoint: endpoint, username: username)
    let store = try WebDAVStore(endpoint: endpoint, username: username, password: password)
    guard try await store.stat("").isDirectory else { throw MobileError.invalidAddress }
    _ = try await store.list("")
    try Task.checkCancellation()
    let lease = try await repository.lease("configuration")
    defer { withExtendedLifetime(lease) {} }
    var config = try repository.configuration()
    try secrets.save(Data(password.utf8), key: "connection-\(connection.id)")
    let location = MobileLocation(connectionID: connection.id, name: connection.name)
    config.connections.append(connection)
    config.locations.append(location)
    try repository.write(config, name: "configuration.json")
    return location
  }
  public func addDrime(
    name: String = "Drime", token: String, settings: DrimeSettings = DrimeSettings()
  ) async throws -> MobileLocation {
    let ioSlot = try await MobileResourceGate.shared.acquire(repository)
    defer { withExtendedLifetime(ioSlot) {} }

    var connection = MobileConnection(
      name: try MobilePath.name(name), endpoint: DrimeStore.endpoint, username: "", drime: settings)
    let store = try DrimeStore(
      token: token, settings: settings, repository: repository, connectionID: connection.id)
    connection.drime?.accountID = try await store.accountID()
    _ = try await store.stat("")
    _ = try await store.list("")
    try Task.checkCancellation()
    let lease = try await repository.lease("configuration")
    defer { withExtendedLifetime(lease) {} }
    var config = try repository.configuration()
    let location = MobileLocation(connectionID: connection.id, name: connection.name)
    try secrets.save(
      Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
      key: "connection-\(connection.id)")
    config.connections.append(connection)
    config.locations.append(location)
    do { try repository.write(config, name: "configuration.json") } catch {
      try? secrets.remove("connection-\(connection.id)")
      throw error
    }
    return location
  }
  public func retryDrimeMaintenance(_ connectionID: UUID) async throws {
    let config = try await configuration()
    guard let connection = config.connections.first(where: { $0.id == connectionID }),
      let store = try rawStore(connection) as? DrimeStore
    else { throw MobileError.unsupported }
    let permit = try await MobileResourceGate.shared.acquire(repository)
    defer { withExtendedLifetime(permit) {} }
    try await store.retryMaintenance()
  }
  public func addS3(name: String, endpoint: URL, settings: S3Settings, credentials: S3Credentials)
    async throws -> MobileLocation
  {
    let ioSlot = try await MobileResourceGate.shared.acquire(repository)
    defer { withExtendedLifetime(ioSlot) {} }

    var connection = MobileConnection(
      name: try MobilePath.name(name), endpoint: endpoint, username: credentials.accessKey,
      s3: settings)
    let native = try S3Store(
      endpoint: endpoint, settings: settings, credentials: credentials, journal: repository)
    _ = try await native.listPage("", continuation: nil, limit: 1)
    connection.readOnly = try await !native.verifyWriteSupport().supported
    try Task.checkCancellation()
    let lease = try await repository.lease("configuration")
    defer { withExtendedLifetime(lease) {} }
    var config = try repository.configuration()
    try secrets.save(JSONEncoder().encode(credentials), key: "connection-\(connection.id)")
    let location = MobileLocation(connectionID: connection.id, name: connection.name)
    config.connections.append(connection)
    config.locations.append(location)
    try repository.write(config, name: "configuration.json")
    return location
  }
  public func updateCredentials(
    connectionID: UUID, username: String, password: String, sessionToken: String? = nil
  ) async throws {
    let lease = try await repository.lease(connectionID.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let ioSlot = try await MobileResourceGate.shared.acquire(repository)
    defer { withExtendedLifetime(ioSlot) {} }
    let config = try repository.configuration()
    guard var connection = config.connections.first(where: { $0.id == connectionID }) else {
      throw MobileError.missing
    }
    connection.username = username
    let native: any CiphertextStore
    let secret: Data
    if let settings = connection.drime {
      let drime = try DrimeStore(
        token: password, settings: settings, repository: repository, connectionID: connection.id)
      connection.drime?.accountID = try await drime.accountID()
      native = drime
      secret = Data(password.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
      connection.username = ""
    } else if let settings = connection.s3 {
      let credentials = S3Credentials(
        accessKey: username, secretKey: password, sessionToken: sessionToken)
      let s3 = try S3Store(
        endpoint: connection.endpoint, settings: settings, credentials: credentials,
        journal: repository)
      native = s3
      connection.readOnly = try await !s3.verifyWriteSupport().supported
      secret = try JSONEncoder().encode(credentials)
    } else if let settings = connection.fileServer {
      if settings.kind == .sftp {
        native = try SFTPStore(
          endpoint: connection.endpoint, settings: settings, username: username, password: password)
      } else {
        native = try FTPStore(
          endpoint: connection.endpoint, settings: settings, username: username, password: password)
      }
      secret = Data(password.utf8)
    } else {
      native = try WebDAVStore(
        endpoint: connection.endpoint, username: username, password: password)
      secret = Data(password.utf8)
    }
    _ = try await native.list("")
    // A different login must not silently redirect an unlocked vault into
    // an unrelated account that happens to have the same folder names.
    for location in config.locations
    where location.connectionID == connectionID && location.removedPath == nil {
      if let descriptor = location.descriptor {
        guard try await readDescriptor(store: native, path: location.path).id == descriptor.id
        else { throw MobileError.conflict }
      }
    }
    let configLease = try await repository.lease("configuration")
    defer { withExtendedLifetime(configLease) {} }
    var current = try repository.configuration()
    guard let index = current.connections.firstIndex(where: { $0.id == connectionID }) else {
      throw MobileError.missing
    }
    try secrets.save(secret, key: "connection-\(connectionID)")
    current.connections[index] = connection
    try repository.write(current, name: "configuration.json")
  }
  public func connectionIsReadOnly(_ connectionID:UUID) throws -> Bool {
    guard let connection = try repository.configuration().connections.first(where:{$0.id == connectionID}) else { throw MobileError.missing }
    if connection.readOnly == true { return true }
    guard let settings = connection.s3, factory == nil else { return false }
    guard let data = try secrets.read("connection-\(connectionID)") else { throw MobileError.credential }
    let keys = try JSONDecoder().decode(S3Credentials.self,from:data)
    return try S3Store.cachedWriteSupport(repository:repository,endpoint:connection.endpoint,settings:settings,credentials:keys)?.supported != true
  }
  public func pendingS3WriteCheckCleanup(_ connectionID: UUID) throws -> Bool {
    guard let connection = try repository.configuration().connections.first(where:{$0.id == connectionID}), let settings = connection.s3 else { return false }
    guard let data = try secrets.read("connection-\(connectionID)") else { throw MobileError.credential }
    let keys = try JSONDecoder().decode(S3Credentials.self,from:data)
    return try S3Store.cachedWriteSupport(repository:repository,endpoint:connection.endpoint,settings:settings,credentials:keys)?.retainedProbeKey != nil
  }
  public func isReadOnly(_ id:UUID) throws -> Bool {
    // Restoring a trashed vault still needs its connection's write policy.
    guard let value = try repository.configuration().locations.first(where:{$0.id == id}) else { throw MobileError.missing }
    return try connectionIsReadOnly(value.connectionID)
  }
  private func requireWritable(_ id:UUID) throws {
    if try isReadOnly(id) { throw MobileError.unsafeWrites }
  }
  public func recheckWriteSupport(_ connectionID:UUID) async throws {
    let lease = try await repository.lease(connectionID.uuidString)
    defer { withExtendedLifetime(lease) {} }
    guard let connection = try repository.configuration().connections.first(where:{$0.id == connectionID}),
      let native = try rawStore(connection) as? S3Store else { throw MobileError.unsupported }
    let ioSlot = try await MobileResourceGate.shared.acquire(repository)
    defer { withExtendedLifetime(ioSlot) {} }
    let status = try await native.verifyWriteSupport(force:true)
    let configLease = try await repository.lease("configuration")
    defer { withExtendedLifetime(configLease) {} }
    var config = try repository.configuration()
    guard let index = config.connections.firstIndex(where:{$0.id == connectionID}) else { throw MobileError.missing }
    config.connections[index].readOnly = !status.supported
    try repository.write(config,name:"configuration.json")
  }
  public func addFileServer(
    name: String, endpoint: URL, username: String, password: String, settings: FileServerSettings
  ) async throws -> MobileLocation {
    let ioSlot = try await MobileResourceGate.shared.acquire(repository)
    defer { withExtendedLifetime(ioSlot) {} }

    var endpoint = endpoint
    if settings.kind == .sftp, endpoint.path.isEmpty {
      let probe = try SFTPStore(
        endpoint: endpoint, settings: settings, username: username, password: password)
      var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
      parts.path = try await probe.homeDirectory()
      guard let resolved = parts.url else { throw MobileError.invalidAddress }
      endpoint = resolved
    }
    let connection = MobileConnection(
      name: try MobilePath.name(name), endpoint: endpoint, username: username, fileServer: settings)
    let native: any CiphertextStore
    if settings.kind == .sftp {
      native = try SFTPStore(
        endpoint: endpoint, settings: settings, username: username, password: password)
    } else {
      native = try FTPStore(
        endpoint: endpoint, settings: settings, username: username, password: password)
    }
    guard try await native.stat("").isDirectory else { throw MobileError.invalidAddress }
    _ = try await native.list("")
    try Task.checkCancellation()
    let lease = try await repository.lease("configuration")
    defer { withExtendedLifetime(lease) {} }
    var config = try repository.configuration()
    try secrets.save(Data(password.utf8), key: "connection-\(connection.id)")
    let location = MobileLocation(connectionID: connection.id, name: connection.name)
    config.connections.append(connection)
    config.locations.append(location)
    try repository.write(config, name: "configuration.json")
    return location
  }
  /// Changes only this device's Files registration. Cloud data, credentials,
  /// stable IDs and the local catalog remain. The OS drain occurs outside the
  /// location lease so pending callbacks can finish instead of deadlocking.
  public func setLocationSuspended(_ id: UUID, suspended: Bool,
    registration: (MobileLocation) async throws -> Void = { _ in }) async throws {
    let value = try location(id,allowSuspended:true).0
    let connectionLease = try await repository.lease(value.connectionID.uuidString)
    defer { withExtendedLifetime(connectionLease) {} }
    guard try repository.pending(id).isEmpty else { throw MobileError.busy }
    try await registration(value)
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    guard try repository.pending(id).isEmpty else { throw MobileError.busy }
    if suspended,value.isVault,try isUnlocked(id) { throw MobileError.busy }
    let configLease = try await repository.lease("configuration")
    defer { withExtendedLifetime(configLease) {} }
    var config = try repository.configuration()
    guard let index = config.locations.firstIndex(where:{$0.id==id && $0.removedPath==nil}) else {throw MobileError.missing}
    config.locations[index].suspended = suspended
    try repository.write(config,name:"configuration.json")
  }
  /// Removes this device's registration only. The caller first drains/removes
  /// the OS domains; no remote delete, move, or purge is issued here.
  public func removeConnection(
    _ connectionID: UUID,
    beforeRemove: ([MobileLocation]) async throws -> Void = { _ in }
  ) async throws {
    let lease = try await repository.lease(connectionID.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let initial = try await configuration()
    guard initial.connections.contains(where: { $0.id == connectionID }) else {
      throw MobileError.missing
    }
    let locations = initial.locations.filter { $0.connectionID == connectionID }
    for value in locations {
      guard try repository.pending(value.id).isEmpty else { throw MobileError.busy }
    }
    try await beforeRemove(locations)
    var locationLeases = [MobileLease]()
    for value in locations.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
      locationLeases.append(try await repository.lease(value.id.uuidString))
    }
    defer { withExtendedLifetime(locationLeases) {} }
    let configLease = try await repository.lease("configuration")
    defer { withExtendedLifetime(configLease) {} }
    var config = try repository.configuration()
    guard
      Set(config.locations.filter { $0.connectionID == connectionID }.map(\.id))
        == Set(locations.map(\.id))
    else { throw MobileError.busy }
    for value in locations {
      let active = value.isVault ? try isUnlocked(value.id) : false
      guard try repository.pending(value.id).isEmpty, !active else { throw MobileError.busy }
    }
    try secrets.remove("connection-\(connectionID)")
    for value in locations {
      try secrets.remove("active-\(value.id)")
      try secrets.remove("remembered-\(value.id)")
    }
    config.locations.removeAll { $0.connectionID == connectionID }
    config.connections.removeAll { $0.id == connectionID }
    try repository.write(config, name: "configuration.json")
    for value in locations {
      for name in ["catalog-\(value.id).json", "pending-\(value.id).json"] {
        try? FileManager.default.removeItem(at: repository.file(name))
      }
    }
  }
  public func remoteFolders(connectionID: UUID, parent: String) async throws -> [CipherItem] {
    let config = try await configuration()
    guard let connection = config.connections.first(where: { $0.id == connectionID }) else {
      throw MobileError.missing
    }
    return try await store(connection).list(MobilePath.checked(parent)).filter(\.isDirectory)
  }
  public func discover(connectionID: UUID, parent: String) async throws -> [(
    path: String, descriptor: VaultDescriptor
  )] {
    let config = try await configuration()
    guard let connection = config.connections.first(where: { $0.id == connectionID }) else {
      throw MobileError.missing
    }
    let store = try store(connection)
    let parent = try MobilePath.checked(parent)
    var found: [(String, VaultDescriptor)] = []
    let entries = try await store.list(parent)
    guard entries.filter(\.isDirectory).count <= 256 else { throw MobileError.busy }
    let deadline = Date().addingTimeInterval(45)
    for folder in entries where folder.isDirectory && !folder.name.hasPrefix(".cloudmount-deleted-")
    {
      try Task.checkCancellation()
      guard Date() < deadline else { throw MobileError.busy }
      let path = try MobilePath.join(parent, folder.name)
      do {
        let descriptor = try await readDescriptor(store: store, path: path)
        found.append((path, descriptor))
      } catch VaultCoreError.missing { continue } catch MobileError.forbidden { continue }
    }
    return found
  }
  private func readDescriptor(store: any CiphertextStore, path: String) async throws
    -> VaultDescriptor
  {
    let prefix = try PrefixedCiphertextStore(store: store, prefix: path)
    let config = try await prefix.read(VaultDescriptor.configName, limit: 65_536)
    let key = try await prefix.read(VaultDescriptor.keyName, limit: 65_536)
    return try VaultDescriptor.parse(masterkeyFile: key, vaultConfig: config)
  }
  public func createVault(
    connectionID: UUID, parent: String, name: String, password: String, remember: Bool
  ) async throws -> (MobileLocation, String) {
    let lease = try await repository.lease(connectionID.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let config = try repository.configuration()
    guard let connection = config.connections.first(where: { $0.id == connectionID }) else {
      throw MobileError.missing
    }
    guard try !connectionIsReadOnly(connectionID) else { throw MobileError.unsafeWrites }
    let path = try MobilePath.join(MobilePath.checked(parent), name)
    let store = try store(connection)
    do {
      _ = try await store.stat(path)
      throw VaultCoreError.exists
    } catch VaultCoreError.missing {}
    let (descriptor, raw) = try await deriveKey { try VaultDescriptor.create(password:password) }
    try await store.mkdir(path)
    let prefix = try PrefixedCiphertextStore(store: store, prefix: path)
    let scratch = try scratchDirectory(descriptor.id)
    let fs = try VaultFileSystem(
      store: prefix, descriptor: descriptor, rawKey: raw, scratch: scratch)
    try await fs.initialize()
    try await writeSmall(descriptor.masterkeyFile, store: prefix, path: VaultDescriptor.keyName)
    // Write the discoverable config only after all initialization succeeds.
    try await writeSmall(descriptor.vaultConfig, store: prefix, path: VaultDescriptor.configName)
    let location = MobileLocation(
      connectionID: connectionID, name: try MobilePath.name(name), path: path,
      descriptor: descriptor)
    try await saveLocation(location)
    try saveKey(raw, location: location, remember: remember)
    return (location, try RecoveryWords.encode(raw))
  }
  public func importVault(connectionID: UUID, path: String, password: String, remember: Bool)
    async throws -> MobileLocation
  {
    let lease = try await repository.lease(connectionID.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let config = try repository.configuration()
    guard let connection = config.connections.first(where: { $0.id == connectionID }) else {
      throw MobileError.missing
    }
    let path = try MobilePath.checked(path)
    let descriptor = try await readDescriptor(store: store(connection), path: path)
    if let existing = config.locations.first(where: {
      $0.connectionID == connectionID && $0.path == path && $0.removedPath == nil
    }) {
      try await unlock(existing.id, password: password, remember: remember)
      return existing
    }
    let raw = try await unlockKey(descriptor,password:password)
    let location = MobileLocation(
      connectionID: connectionID,
      name: path.split(separator: "/").last.map(String.init) ?? connection.name, path: path,
      descriptor: descriptor)
    try await saveLocation(location)
    try saveKey(raw, location: location, remember: remember)
    return location
  }
  private func saveLocation(_ location: MobileLocation) async throws {
    try Task.checkCancellation()
    let lease = try await repository.lease("configuration")
    defer { withExtendedLifetime(lease) {} }
    var config = try repository.configuration()
    config.locations.append(location)
    try repository.write(config, name: "configuration.json")
  }
  private func saveKey(_ raw: Data, location: MobileLocation, remember: Bool) throws {
    try location.descriptor?.authenticate(rawKey: raw)
    if remember {
      try secrets.save(raw, key: "remembered-\(location.id)")
    } else {
      try secrets.remove("remembered-\(location.id)")
    }
    try secrets.save(raw, key: "active-\(location.id)")
  }
  public func unlock(_ id: UUID, password: String?, remember: Bool = false) async throws {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let (location, connection) = try location(id,allowSuspended:true)
    guard let descriptor = location.descriptor else { return }
    let remote = try await readDescriptor(store: store(connection), path: location.path)
    guard remote == descriptor else { throw MobileError.conflict }
    let raw: Data
    if let password {
      raw = try await unlockKey(descriptor,password:password)
    } else {
      guard let remembered = try secrets.read("remembered-\(id)") else { throw MobileError.locked }
      raw = remembered
    }
    try saveKey(raw, location: location, remember: password == nil || remember)
  }
  /// Caller must first pass the OS File Provider barrier and evict its cached
  /// files. This method additionally waits for our own in-flight operations.
  public func lock(_ id: UUID) async throws {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    guard try repository.pending(id).isEmpty else { throw MobileError.busy }
    try secrets.remove("active-\(id)")
    let scratch = repository.root.appendingPathComponent("scratch-\(id)", isDirectory: true)
    if FileManager.default.fileExists(atPath: scratch.path) {
      try FileManager.default.removeItem(at: scratch)
    }
  }
  private func deriveKey<T:Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let slot = try await MobileResourceGate.shared.acquire(repository,crypto:true,timeout:30)
    defer { withExtendedLifetime(slot) {} }
    try Task.checkCancellation()
    let result = try await Task.detached(priority:.userInitiated,operation:work).value
    try Task.checkCancellation()
    return result
  }
  private func unlockKey(_ descriptor:VaultDescriptor,password:String) async throws -> Data {
    // Do not lower or rewrite an imported vault's security parameters.
    // Refuse resource-excessive KDFs before allocating their memory on mobile.
    guard let fields = try JSONSerialization.jsonObject(with:descriptor.masterkeyFile) as? [String:Any],
      let n = fields["scryptCostParam"] as? Int, let r = fields["scryptBlockSize"] as? Int,
      (2...262_144).contains(n), (1...8).contains(r), n & (n-1) == 0,
      n <= 67_108_864 / (128 * r) else { throw MobileError.vaultMemoryLimit }
    return try await deriveKey { try descriptor.unlock(password:password) }
  }
  public func recovery(_ id: UUID) async throws -> String {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    guard let raw = try secrets.read("active-\(id)") else { throw MobileError.locked }
    return try RecoveryWords.encode(raw)
  }
  public func trashVault(_ id: UUID) async throws {
    try requireWritable(id)
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    guard try !isUnlocked(id), try repository.pending(id).isEmpty else { throw MobileError.busy }
    let (location, connection) = try location(id)
    guard let descriptor = location.descriptor, !location.path.isEmpty else {
      throw MobileError.unsupported
    }
    let store = try store(connection)
    let parent = location.path.split(separator: "/").dropLast().joined(separator: "/")
    let trash = try MobilePath.join(parent, ".cloudmount-deleted-" + id.uuidString)
    do {
      guard try await readDescriptor(store: store, path: location.path).id == descriptor.id else {
        throw MobileError.conflict
      }
      try await store.move(location.path, to: trash, directory: true, replace: false)
      guard try await readDescriptor(store: store, path: trash).id == descriptor.id else {
        throw MobileError.conflict
      }
    } catch VaultCoreError.missing {
      // Reconcile a completed remote move whose local acknowledgement
      // was lost. Never interpret an arbitrary missing folder as success.
      guard try await readDescriptor(store: store, path: trash).id == descriptor.id else {
        throw MobileError.conflict
      }
    }
    let configLease = try await repository.lease("configuration")
    defer { withExtendedLifetime(configLease) {} }
    var config = try repository.configuration()
    guard let index = config.locations.firstIndex(where: { $0.id == id }) else {
      throw MobileError.missing
    }
    config.locations[index].removedPath = trash
    try repository.write(config, name: "configuration.json")
    try secrets.remove("remembered-\(id)")
  }
  public func restoreVault(_ id: UUID) async throws {
    try requireWritable(id)
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    var config = try repository.configuration()
    guard let index = config.locations.firstIndex(where: { $0.id == id }),
      let path = config.locations[index].removedPath,
      let connection = config.connections.first(where: {
        $0.id == config.locations[index].connectionID
      })
    else { throw MobileError.missing }
    do {
      let remote = try store(connection)
      try await remote.move(path, to: config.locations[index].path, directory: true, replace: false)
      guard let descriptor = config.locations[index].descriptor,
        try await readDescriptor(store: remote, path: config.locations[index].path).id == descriptor.id
      else { throw MobileError.conflict }
    } catch VaultCoreError.missing {
      guard let descriptor = config.locations[index].descriptor,
        try await readDescriptor(store: store(connection), path: config.locations[index].path).id
          == descriptor.id
      else { throw MobileError.conflict }
    }
    let configLease = try await repository.lease("configuration")
    defer { withExtendedLifetime(configLease) {} }
    config = try repository.configuration()
    guard let index = config.locations.firstIndex(where: { $0.id == id }) else {
      throw MobileError.missing
    }
    config.locations[index].removedPath = nil
    try repository.write(config, name: "configuration.json")
  }
  private func scratchDirectory(_ id: UUID) throws -> URL {
    let url = repository.root.appendingPathComponent("scratch-\(id)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    #endif
    return url
  }
  private func writeSmall(_ data: Data, store: any CiphertextStore, path: String) async throws {
    let file = try repository.file("small-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try data.write(to: file)
    try repository.protect(file)
    try await store.upload(file, to: path)
  }
  private struct Backend: Sendable {
    let store: any CiphertextStore
    let fs: VaultFileSystem?
    func stat(_ path: String) async throws -> CipherItem {
      if let fs {
        let v = try await fs.stat(path)
        return CipherItem(
          name: v.name, size: v.size, modified: v.modified, version: v.version,
          isDirectory: v.isDirectory)
      }
      return try await store.stat(path)
    }
    func list(_ path: String) async throws -> [CipherItem] {
      if let fs {
        return try await fs.list(path).map {
          CipherItem(
            name: $0.name, size: $0.size, modified: $0.modified, version: $0.version,
            isDirectory: $0.isDirectory)
        }
      }
      return try await store.list(path)
    }
    func download(_ path: String, to file: URL) async throws {
      if let fs {
        _ = try await fs.download(path, to: file)
      } else {
        try await store.download(path, to: file)
      }
    }
    func mkdir(_ path: String) async throws {
      if let fs { try await fs.mkdir(path) } else { try await store.mkdir(path) }
    }
    func move(_ a: String, to b: String, directory: Bool) async throws {
      if let fs {
        try await fs.move(a, to: b, replace: false)
      } else {
        try await store.move(a, to: b, directory: directory, replace: false)
      }
    }
    func delete(_ path: String, directory: Bool) async throws {
      if let fs {
        try await fs.delete(path)
      } else {
        try await store.delete(path, directory: directory)
      }
    }
  }
  private func backend(_ id: UUID, previewLimit: Int? = nil) throws -> Backend {
    let (location, connection) = try location(id)
    let base = try store(connection)
    var transport: any CiphertextStore = base
    if let previewLimit { transport = PreviewReadStore(base: base, limit: previewLimit) }
    let prefixed = try PrefixedCiphertextStore(store: transport, prefix: location.path)
    var fs: VaultFileSystem?
    if let descriptor = location.descriptor {
      guard let raw = try secrets.read("active-\(id)") else { throw MobileError.locked }
      fs = try VaultFileSystem(
        store: prefixed, descriptor: descriptor, rawKey: raw, scratch: scratchDirectory(id))
    }
    return Backend(store: prefixed, fs: fs)
  }
  private func rootNode(_ id: UUID) throws -> MobileNode {
    let value = try location(id).0
    return MobileNode(
      id: "root", parent: "root", path: "", name: value.name, directory: true, size: 0,
      modified: .distantPast, version: "root")
  }
  private func node(_ id: String, location: UUID, catalog: MobileCatalog) throws -> MobileNode {
    if id == "root" { return try rootNode(location) }
    guard let item = catalog.nodes[id] else { throw MobileError.missing }
    return item
  }
  public func refreshProviderMetadata(_ id: UUID) async throws {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    var catalog = try repository.catalog(id)
    for node in catalog.nodes.values {
      catalog.generation += 1
      catalog.changes.append(
        MobileChange(generation: catalog.generation, id: node.id, deleted: false))
    }
    if catalog.changes.count > 10_000 {
      catalog.changes.removeFirst(catalog.changes.count - 10_000)
    }
    try repository.saveCatalog(catalog, id: id)
  }
  public func validateProviderAccess(_ id: UUID) async throws {
    let lease=try await repository.lease(id.uuidString)
    defer {withExtendedLifetime(lease) {}}
    _ = try backend(id)
  }
  public func catalog(_ id: UUID) async throws -> MobileCatalog {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    _ = try backend(id)
    return try repository.catalog(id)
  }
  public func item(_ identifier: String, location id: UUID) async throws -> MobileNode {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    if identifier == "root" { return try rootNode(id) }
    let backend = try backend(id)
    let catalog = try repository.catalog(id)
    let old = try node(identifier, location: id, catalog: catalog)
    let value = try await backend.stat(old.path)
    return MobileNode(
      id: old.id, parent: old.parent, path: old.path, name: old.name, directory: value.isDirectory,
      size: value.size, modified: value.modified, version: value.version)
  }
  public func providerItem(_ identifier: String, location id: UUID) async throws -> (node: MobileNode, verifiedRemote: Bool) {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    if identifier == "root" { return (try rootNode(id), false) }
    let backend = try backend(id)
    var catalog = try repository.catalog(id)
    let old = try node(identifier, location: id, catalog: catalog)
    if !old.version.isEmpty, let observed = old.observedAt,
      Date().timeIntervalSince(observed) >= 0, Date().timeIntervalSince(observed) < 60 {
      return (old, false)
    }
    let receipts = (try? repository.read("directories-\(id).json", default: [String: DirectoryReceipt]())) ?? [:]
    if let receipt = receipts[old.parent], receipt.generation == catalog.generation,
      Date().timeIntervalSince(receipt.date) >= 0, Date().timeIntervalSince(receipt.date) < 60 {
      return (old, false)
    }
    let value = try await backend.stat(old.path)
    var updated = MobileNode(id: old.id, parent: old.parent, path: old.path, name: old.name,
      directory: value.isDirectory, size: value.size, modified: value.modified, version: value.version)
    updated.observedAt = Date()
    catalog.record(updated); try repository.saveCatalog(catalog, id: id)
    return (updated, true)
  }
  public func list(_ parent: String, location id: UUID) async throws -> [MobileNode] {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    return try await refresh(parent, location: id)
  }
  func cachedProviderDirectory(_ parent: String, location id: UUID) async throws -> [MobileNode]? {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    _ = try backend(id) // Cached names never grant access to a locked vault.
    let catalog = try repository.catalog(id)
    let receipts = (try? repository.read("directories-\(id).json", default: [String: DirectoryReceipt]())) ?? [:]
    guard let receipt = receipts[parent], receipt.generation == catalog.generation,
      Date().timeIntervalSince(receipt.date) >= 0, Date().timeIntervalSince(receipt.date) < 60 else { return nil }
    return catalog.nodes.values.filter { $0.parent == parent }
  }
  public func cachedProviderDirectoryForChanges(_ parent: String, location id: UUID) async throws -> Bool {
    try await cachedProviderDirectory(parent, location: id) != nil
  }
  public func refreshProviderDirectory(_ parent: String, location id: UUID) async throws {
    _ = try await MobileDeadline.run(seconds: 20) { try await self.list(parent, location: id) }
  }
  private func rememberDirectory(_ parent: String, location id: UUID, generation: Int64) {
    var receipts = (try? repository.read("directories-\(id).json", default: [String: DirectoryReceipt]())) ?? [:]
    receipts = receipts.filter { Date().timeIntervalSince($0.value.date) < 60 }
    if receipts.count >= 128, let oldest = receipts.min(by: { $0.value.date < $1.value.date })?.key { receipts[oldest] = nil }
    receipts[parent] = DirectoryReceipt(date: Date(), generation: generation)
    try? repository.write(receipts, name: "directories-\(id).json")
  }
  func providerScanContext(_ parent: String, location id: UUID) async throws -> (paged: Bool, path: String, baseline: [MobileNode]) {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    _ = try backend(id)
    let (value, connection) = try location(id)
    let catalog = try repository.catalog(id)
    let directory = try node(parent, location: id, catalog: catalog)
    guard directory.directory else { throw MobileError.missing }
    return (connection.s3 != nil && !value.isVault, directory.path, Array(catalog.nodes.values))
  }
  func providerDirectoryPage(_ parent: String, location id: UUID, path: String,
    continuation: String?, limit: Int) async throws -> MobileEnumerationPage {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let (value, connection) = try location(id)
    guard !value.isVault, connection.s3 != nil else { throw MobileError.unsupported }
    var catalog = try repository.catalog(id)
    guard try node(parent, location: id, catalog: catalog).path == path else { throw MobileError.expiredPage }
    let fullPath = [value.path, path].filter { !$0.isEmpty }.joined(separator: "/")
    let paged = BudgetedStore(repository: repository, factory: { try rawStore(connection) })
    let page = try await paged.listPage(fullPath, continuation: continuation, limit: limit)
    try Task.checkCancellation()
    guard Set(page.items.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() }).count == page.items.count else { throw MobileError.incomplete }
    var previous: [String: MobileNode] = [:]
    for item in catalog.nodes.values {
      guard previous.updateValue(item, forKey: item.path) == nil else { throw MobileError.incomplete }
    }
    var result: [MobileNode] = []
    for child in page.items {
      let childPath = try MobilePath.join(path, child.name)
      let old = previous[childPath]
      var updated = MobileNode(id: old?.id ?? UUID().uuidString, parent: parent, path: childPath,
        name: child.name, directory: child.isDirectory, size: child.size, modified: child.modified, version: child.version)
      updated.observedAt = Date()
      catalog.record(updated); result.append(updated)
    }
    // Saving one page never removes missing siblings. Only completeProviderScan
    // may remove a baseline item after all server pages succeed.
    try repository.saveCatalog(catalog, id: id)
    return MobileEnumerationPage(nodes: result, next: page.next, verifiedRemote: true)
  }
  func completeProviderScan(_ parent: String, location id: UUID, path: String,
    baseline: [MobileNode], seen: Set<String>) async throws {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    _ = try backend(id)
    var catalog = try repository.catalog(id)
    guard try node(parent, location: id, catalog: catalog).path == path else { throw MobileError.expiredPage }
    var old: [String: MobileNode] = [:]
    for item in baseline {
      guard old.updateValue(item, forKey: item.id) == nil else { throw MobileError.incomplete }
    }
    for item in baseline where item.parent == parent && !seen.contains(item.id) {
      let branch = catalog.nodes.values.filter { $0.path == item.path || $0.path.hasPrefix(item.path + "/") }
      // Do not remove local edits/new descendants made between page requests.
      guard branch.allSatisfy({ old[$0.id] == $0 }) else { continue }
      for descendant in branch { catalog.remove(descendant.id) }
    }
    try repository.saveCatalog(catalog, id: id)
    rememberDirectory(parent, location: id, generation: catalog.generation)
  }
  private func refresh(_ parent: String, location id: UUID) async throws -> [MobileNode] {
    let backend = try backend(id)
    var catalog = try repository.catalog(id)
    let directory = try node(parent, location: id, catalog: catalog)
    let children = try await backend.list(directory.path)
    guard children.count < 20_000,
      Set(children.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() }).count
        == children.count
    else { throw MobileError.incomplete }
    var previousByPath:[String:MobileNode]=[:]
    for item in catalog.nodes.values {
      guard previousByPath.updateValue(item,forKey:item.path)==nil else {throw MobileError.incomplete}
    }
    var result: [MobileNode] = []
    for child in children {
      let path = try MobilePath.join(directory.path, child.name)
      let previous = previousByPath[path]
      var value = MobileNode(
        id: previous?.id ?? UUID().uuidString, parent: parent, path: path, name: child.name,
        directory: child.isDirectory, size: child.size, modified: child.modified,
        version: child.version)
      value.observedAt = Date()
      catalog.record(value)
      result.append(value)
    }
    // Only a fully successful list may produce tombstones.
    let present = Set(result.map(\.id))
    let removed = catalog.nodes.values.filter { $0.parent == parent && !present.contains($0.id) }
    for old in removed {
      for descendant in catalog.nodes.values.filter({
        $0.path == old.path || $0.path.hasPrefix(old.path + "/")
      }) { catalog.remove(descendant.id) }
    }
    try repository.saveCatalog(catalog, id: id)
    rememberDirectory(parent, location: id, generation: catalog.generation)
    return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  public func download(_ identifier: String, location id: UUID, to file: URL) async throws
    -> MobileNode
  {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let backend = try backend(id)
    let old = try node(identifier, location: id, catalog: repository.catalog(id))
    let before = try await backend.stat(old.path)
    guard !before.isDirectory else { throw MobileError.unsupported }
    do {
      try await backend.download(old.path, to: file)
      try repository.protect(file)
      let after = try await backend.stat(old.path)
      let received = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
      guard before.version == after.version, before.size == after.size,
        after.size < 0 || received == after.size else { throw MobileError.conflict }
      return MobileNode(
        id: old.id, parent: old.parent, path: old.path, name: old.name, directory: false,
        size: after.size, modified: after.modified, version: after.version)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
  }
  public func browsingPolicy() throws -> MobileBrowsingPolicy {
    var policy = (try? repository.read("browsing-policy.json", default: MobileBrowsingPolicy())) ?? MobileBrowsingPolicy()
    policy.maximumMB = policy.safeMB; policy.retentionDays = policy.safeDays
    return policy
  }
  public func updateBrowsingPolicy(_ policy: MobileBrowsingPolicy) async throws {
    let lease = try await repository.lease("resource-thumbnail", timeout: 5)
    defer { withExtendedLifetime(lease) {} }
    var safe = policy; safe.maximumMB = policy.safeMB; safe.retentionDays = policy.safeDays
    try repository.write(safe, name: "browsing-policy.json")
    try MobileThumbnailCache(repository: repository, policy: safe).prune()
  }
  public func clearThumbnailCache() async throws {
    let lease = try await repository.lease("resource-thumbnail", timeout: 5)
    defer { withExtendedLifetime(lease) {} }
    try MobileThumbnailCache(repository: repository, policy: browsingPolicy()).prune(all: true)
  }
  public func thumbnail(_ identifier: String, location id: UUID, dimension: Double,
    timeout: Double = 15) async throws -> Data? {
    let pixels = try MobileThumbnailRenderer.pixels(dimension)
    return try await MobileDeadline.run(seconds: max(0.1, min(timeout, 20))) {
      try await self.thumbnailImage(identifier, location: id, pixels: pixels)
    }
  }
  public func deliverThumbnail(location id: UUID, delivery: @Sendable () async -> Void) async throws {
    let lease = try await repository.lease(id.uuidString, timeout: 2)
    defer { withExtendedLifetime(lease) {} }
    _ = try backend(id)
    try Task.checkCancellation()
    // A vault can be locked between rendering and the framework callback.
    // Recheck, and keep the same lock until that callback has returned.
    await delivery()
  }
  private func thumbnailImage(_ identifier: String, location id: UUID, pixels: Int) async throws -> Data? {
    let permit = try await repository.lease("resource-thumbnail", timeout: 5)
    defer { withExtendedLifetime(permit) {} }
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let policy = try browsingPolicy()
    guard policy.thumbnailsEnabled else { return nil }
    let backend = try backend(id, previewLimit: 10_485_760)
    var catalog = try repository.catalog(id)
    let old = try node(identifier, location: id, catalog: catalog)
    guard !old.directory, old.size >= 0, old.size <= MobileThumbnailRenderer.maximumSourceBytes,
      MobileThumbnailRenderer.supports(old.name) else { return nil }
    let (value, connection) = try location(id)
    let vault = value.isVault
    let raw = vault ? try secrets.read("active-\(id)") : nil
    if vault, raw == nil { throw MobileError.locked }
    let key = raw.map { MobileThumbnailCache.encryptionKey(raw: $0, location: id) }
    let cache = MobileThumbnailCache(repository: repository, policy: policy)
    let oldKey = MobileThumbnailCache.key(location: id, node: old, pixels: pixels, vault: vault)
    if !old.version.isEmpty, let hit = try? cache.read(oldKey, encryptionKey: key), hit.fresh { return hit.data }
    let before = try await backend.stat(old.path)
    guard !before.isDirectory, before.size >= 0, before.size <= MobileThumbnailRenderer.maximumSourceBytes else { return nil }
    var current = MobileNode(id: old.id, parent: old.parent, path: old.path, name: old.name,
      directory: false, size: before.size, modified: before.modified, version: before.version)
    current.observedAt = Date()
    catalog.record(current)
    try repository.saveCatalog(catalog, id: id)
    let cacheKey = MobileThumbnailCache.key(location: id, node: current, pixels: pixels, vault: vault)
    // FTP/SFTP revisions often contain only coarse mtime and size. A same-size
    // overwrite within one timestamp tick must not preserve a preview forever.
    if !current.version.isEmpty, let hit = try? cache.read(cacheKey, encryptionKey: key),
      connection.fileServer == nil || hit.fresh { return hit.data }
    let scratch = try scratchDirectory(id)
    // Only our abandoned preview sources are disposable; vault staging and
    // pending write journals are never cleared here.
    for file in try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
      where file.lastPathComponent.hasPrefix("thumbnail-") {
      try? FileManager.default.removeItem(at: file)
    }
    let source = scratch.appendingPathComponent("thumbnail-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: source) }
    try await backend.download(old.path, to: source)
    try repository.protect(source)
    guard (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value == before.size else { throw MobileError.conflict }
    let after = try await backend.stat(old.path)
    guard before.version == after.version, before.size == after.size, before.modified == after.modified else { throw MobileError.conflict }
    let result = try MobileThumbnailRenderer.render(source, pixels: pixels)
    try Task.checkCancellation()
    if let result { try? cache.save(result, key: cacheKey, encryptionKey: key) }
    return result
  }
  public func create(
    parent: String, name: String, directory: Bool, contents: URL?, requestID: String,
    location id: UUID
  ) async throws -> MobileNode {
    try requireWritable(id)
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    var catalog = try repository.catalog(id)
    if let nodeID = catalog.requests[requestID], let previous = catalog.nodes[nodeID] {
      return previous
    }
    let parentNode = try node(parent, location: id, catalog: catalog)
    let path = try MobilePath.join(parentNode.path, name)
    let backend = try backend(id)
    do {
      _ = try await backend.stat(path)
      throw MobileError.conflict
    } catch VaultCoreError.missing {}
    if directory {
      try await backend.mkdir(path)
    } else {
      guard let contents else { throw MobileError.incomplete }
      try await upload(
        contents, path: path, nodeID: requestID, expected: nil, requireNew: true, location: id,
        backend: backend)
    }
    let value = try await backend.stat(path)
    let result = MobileNode(
      id: requestID, parent: parent, path: path, name: try MobilePath.name(name),
      directory: directory, size: value.size, modified: value.modified, version: value.version)
    catalog.record(result)
    catalog.requests[requestID] = result.id
    try repository.saveCatalog(catalog, id: id)
    return result
  }
  public func modify(
    _ identifier: String, parent: String?, name: String?, contents: URL?, expected: String?,
    location id: UUID
  ) async throws -> MobileNode {
    try requireWritable(id)
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    var catalog = try repository.catalog(id)
    let old = try node(identifier, location: id, catalog: catalog)
    let backend = try backend(id)
    guard identifier != "root" else { throw MobileError.unsupported }
    let current = try await backend.stat(old.path)
    if let expected, expected != current.version {
      guard let contents, parent == nil || parent == old.parent, name == nil || name == old.name else {
        throw MobileError.conflict
      }
      return try await reconcileUploadedContents(old, contents: contents, location: id, backend: backend)
    }
    let newParent = try node(parent ?? old.parent, location: id, catalog: catalog)
    let newName = try MobilePath.name(name ?? old.name)
    let path = try MobilePath.join(newParent.path, newName)
    guard !old.directory || !path.hasPrefix(old.path + "/") else { throw MobileError.invalidName }
    // Fail closed on a combined rename+content request: preserve both fields
    // until the operation can be made atomic by a backend transaction.
    if contents != nil && path != old.path { throw MobileError.unsupported }
    if let contents {
      try await upload(
        contents, path: path, nodeID: identifier, expected: current.version, requireNew: false,
        location: id, backend: backend)
    }
    if path != old.path {
      try await backend.move(old.path, to: path, directory: old.directory)
      for var child in catalog.nodes.values.filter({ $0.path.hasPrefix(old.path + "/") }) {
        child.path = path + child.path.dropFirst(old.path.count)
        catalog.record(child)
      }
    }
    let value = try await backend.stat(path)
    let result = MobileNode(
      id: old.id, parent: parent ?? old.parent, path: path, name: newName,
      directory: value.isDirectory, size: value.size, modified: value.modified,
      version: value.version)
    catalog.record(result)
    try repository.saveCatalog(catalog, id: id)
    return result
  }
  /// A File Provider retry can carry the old base version after the main app
  /// has already retried and acknowledged its upload. Accept only exact content
  /// equality at an unchanged remote revision; never overwrite a newer edit.
  public func reconcileUploadedContents(
    _ identifier: String, contents: URL, location id: UUID
  ) async throws -> MobileNode {
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let old = try node(identifier, location: id, catalog: repository.catalog(id))
    return try await reconcileUploadedContents(old, contents: contents, location: id, backend: backend(id))
  }
  private func reconcileUploadedContents(
    _ old: MobileNode, contents: URL, location id: UUID, backend: Backend
  ) async throws -> MobileNode {
    guard old.id != "root", !old.directory else { throw MobileError.conflict }
    let hash = try digest(contents)
    guard let verified = try await verifiedContents(old.path, digest: hash, backend: backend)
    else { throw MobileError.conflict }
    for pending in try repository.pending(id).filter({ $0.nodeID == old.id }) {
      guard pending.path == old.path, pending.digest == hash else { throw MobileError.conflict }
      try await acknowledge(pending, backend: backend, expectedVersion: verified.version)
    }
    var catalog = try repository.catalog(id)
    let result = MobileNode(
      id: old.id, parent: old.parent, path: old.path, name: old.name, directory: false,
      size: verified.size, modified: verified.modified, version: verified.version)
    catalog.record(result)
    try repository.saveCatalog(catalog, id: id)
    return result
  }
  private func verifiedContents(_ path: String, digest hash: String, backend: Backend)
    async throws -> CipherItem?
  {
    let before: CipherItem
    do { before = try await backend.stat(path) } catch VaultCoreError.missing { return nil }
    guard !before.isDirectory else { return nil }
    let verify = try repository.file("verify-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: verify) }
    try await backend.download(path, to: verify)
    try repository.protect(verify)
    guard try digest(verify) == hash else { return nil }
    let after = try await backend.stat(path)
    guard !after.isDirectory, before.version == after.version, before.size == after.size else {
      throw MobileError.conflict
    }
    return after
  }
  private func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
      hash.update(data: bytes)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private func upload(
    _ source: URL, path: String, nodeID: String, expected: String?, requireNew: Bool,
    location id: UUID, backend: Backend
  ) async throws {
    let hash = try digest(source)
    var pending = try repository.pending(id)
    if let previous = pending.first(where: { $0.path == path }) {
      guard previous.nodeID == nodeID, previous.digest == hash else { throw MobileError.busy }
      let saved = try repository.file("upload-" + previous.id)
      guard try digest(saved) == previous.digest else { throw MobileError.incomplete }
      let verified = try await verifiedContents(path, digest: hash, backend: backend)
      if verified == nil { try await commit(previous, staging: saved, backend: backend) }
      try await acknowledge(previous, backend: backend, expectedVersion: verified?.version)
      return
    }
    let operationID = UUID().uuidString
    let staging = try repository.file("upload-" + operationID)
    try FileManager.default.copyItem(at: source, to: staging)
    try repository.protect(staging)
    let operation = MobilePendingWrite(
      id: operationID, location: id, path: path, nodeID: nodeID, expectedVersion: expected,
      requireNew: requireNew, digest: hash, created: Date())
    pending.append(operation)
    try repository.savePending(pending, id: id)
    // On failure retain both the journal and the protected local file.
    try await commit(operation, staging: staging, backend: backend)
    try await acknowledge(operation, backend: backend)
  }
  private func acknowledge(
    _ operation: MobilePendingWrite, backend: Backend, expectedVersion: String? = nil
  ) async throws {
    let id = operation.location
    let value = try await backend.stat(operation.path)
    if let expectedVersion, value.version != expectedVersion { throw MobileError.conflict }
    var catalog = try repository.catalog(id)
    let parts = operation.path.split(separator: "/")
    let parentPath = parts.dropLast().joined(separator: "/")
    let parent: String
    if parentPath.isEmpty {
      parent = "root"
    } else {
      guard
        let directory = catalog.nodes.values.first(where: { $0.path == parentPath && $0.directory })
      else { throw MobileError.conflict }
      parent = directory.id
    }
    let node = MobileNode(
      id: operation.nodeID, parent: parent, path: operation.path, name: String(parts.last ?? ""),
      directory: false, size: value.size, modified: value.modified, version: value.version)
    catalog.record(node)
    catalog.requests[operation.nodeID] = operation.nodeID
    try repository.saveCatalog(catalog, id: id)
    var pending = try repository.pending(id)
    pending.removeAll { $0.id == operation.id }
    try repository.savePending(pending, id: id)
    let file = try repository.file("upload-" + operation.id)
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
  private func commit(_ operation: MobilePendingWrite, staging: URL, backend: Backend) async throws
  {
    if let fs = backend.fs {
      try await fs.upload(
        staging, to: operation.path, expectedVersion: operation.expectedVersion,
        requireNew: operation.requireNew)
    } else {
      let current: CipherItem?
      do { current = try await backend.stat(operation.path) } catch VaultCoreError.missing {
        current = nil
      }
      if operation.requireNew, current != nil { throw MobileError.conflict }
      if let expected = operation.expectedVersion, current?.version != expected {
        throw MobileError.conflict
      }
      // Native DAV uploads use conditional HTTP writes; other stores must
      // supply their own compare-and-swap before production support.
      let (location, connection) = try location(operation.location)
      if factory == nil {
        guard let native = try store(connection) as? any NativeConditionalStore else {
          throw MobileError.unsupported
        }
        let path = location.path.isEmpty ? operation.path : location.path + "/" + operation.path
        try await native.put(
          staging, path: path, expected: operation.expectedVersion, requireNew: operation.requireNew
        )
      } else {
        try await backend.store.upload(staging, to: operation.path)
      }
    }
  }
  public func retryPending(_ id: UUID) async throws {
    try requireWritable(id)
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let backend = try backend(id)
    for operation in try repository.pending(id) {
      let staging = try repository.file("upload-" + operation.id)
      guard try digest(staging) == operation.digest else { throw MobileError.incomplete }
      // A server may have committed before the response was lost. Verify
      // plaintext, never overwrite the new revision just to clear an error.
      let verified = try await verifiedContents(operation.path, digest: operation.digest, backend: backend)
      if verified == nil { try await commit(operation, staging: staging, backend: backend) }
      try await acknowledge(operation, backend: backend, expectedVersion: verified?.version)
    }
  }
  public func delete(_ identifier: String, expected: String?, recursive: Bool, location id: UUID)
    async throws
  {
    try requireWritable(id)
    let lease = try await repository.lease(id.uuidString)
    defer { withExtendedLifetime(lease) {} }
    let backend = try backend(id)
    var catalog = try repository.catalog(id)
    let old = try node(identifier, location: id, catalog: catalog)
    guard identifier != "root" else { throw MobileError.unsupported }
    let current = try await backend.stat(old.path)
    if let expected, current.version != expected { throw MobileError.conflict }
    if recursive {
      try await deleteTree(old.path, backend: backend, depth: 0)
    } else {
      try await backend.delete(old.path, directory: old.directory)
    }
    for value in catalog.nodes.values.filter({
      $0.path == old.path || $0.path.hasPrefix(old.path + "/")
    }) { catalog.remove(value.id) }
    try repository.saveCatalog(catalog, id: id)
  }
  private func deleteTree(_ path: String, backend: Backend, depth: Int) async throws {
    guard depth < 128 else { throw MobileError.incomplete }
    try Task.checkCancellation()
    let current = try await backend.stat(path)
    if current.isDirectory {
      for value in try await backend.list(path) {
        try await deleteTree(MobilePath.join(path, value.name), backend: backend, depth: depth + 1)
      }
    }
    try await backend.delete(path, directory: current.isDirectory)
  }
}
