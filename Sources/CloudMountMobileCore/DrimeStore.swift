import CloudMountVaultCore
import CoreFoundation
import CryptoKit
import Foundation

/// Drime's REST API. No subprocess, mount daemon, embedded account token, or Mac relay.
/// All operations on a connection are serialized across the app and extensions.
/// Replacement uploads never delete the old file first. A persisted rename plan
/// keeps the previous version recoverable until the new entry is confirmed.
public actor DrimeStore: NativeConditionalStore {
  public static let endpoint = URL(string: "https://app.drime.cloud/api/v1/")!
  private let base: URL
  private let token: String
  private let settings: DrimeSettings
  private let repository: MobileRepository
  private let identifier: UUID
  private let session: URLSession
  private let delegate = DrimeSessionDelegate()
  private let testing: Bool
  private var journalName: String { "drime-\(identifier).json" }

  public init(
    token: String, settings: DrimeSettings = DrimeSettings(),
    repository: MobileRepository, connectionID: UUID
  ) throws {
    try self.init(
      token: token, settings: settings, repository: repository,
      connectionID: connectionID, endpoint: Self.endpoint, testing: false)
  }
  // Internal fixture-only initializer; there is no editable API URL or TLS bypass in the app.
  init(
    token: String, settings: DrimeSettings, repository: MobileRepository,
    connectionID: UUID, endpoint: URL, testing: Bool
  ) throws {
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, token.utf8.count <= 8192,
      !token.unicodeScalars.contains(where: {
        CharacterSet.whitespacesAndNewlines.contains($0)
          || CharacterSet.controlCharacters.contains($0)
      }),
      settings.workspaceID >= 0, settings.rootFolderID.map({ $0 > 0 }) ?? true,
      endpoint == Self.endpoint
        || (testing && endpoint.scheme == "http" && endpoint.host == "127.0.0.1")
    else { throw MobileError.invalidAddress }
    self.base = endpoint
    self.token = token
    self.settings = settings
    self.repository = repository
    self.identifier = connectionID
    self.testing = testing
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 25
    config.timeoutIntervalForResource = 180
    config.httpMaximumConnectionsPerHost = 2
    session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }
  private func lease() async throws -> MobileLease {
    try await repository.lease("drime-\(identifier)")
  }
  private func state() throws -> DrimeJournal {
    try repository.read(journalName, default: DrimeJournal())
  }
  private func save(_ value: DrimeJournal) throws { try repository.write(value, name: journalName) }
  private func request(
    _ method: String, _ route: String, query: [String: String] = [:], body: [String: Any]? = nil
  ) throws -> URLRequest {
    var c = URLComponents(url: base.appendingPathComponent(route), resolvingAgainstBaseURL: false)!
    var query = query
    query["workspaceId"] = String(settings.workspaceID)
    c.queryItems = query.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    guard let url = c.url else { throw MobileError.invalidAddress }
    var r = URLRequest(url: url)
    r.httpMethod = method
    r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      r.httpBody = try JSONSerialization.data(withJSONObject: body)
      r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return r
  }
  private func check(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let r = response as? HTTPURLResponse else { throw MobileError.incomplete }
    switch r.statusCode {
    case 200...299: return r
    case 401: throw MobileError.credential
    case 403: throw MobileError.forbidden
    case 404: throw VaultCoreError.missing
    case 409, 412: throw MobileError.conflict
    case 413, 507: throw MobileError.quota
    default: throw MobileError.network(r.statusCode)
    }
  }
  private func json(_ request: URLRequest, upload: URL? = nil) async throws -> [String: Any] {
    for attempt in 0..<3 {
      try Task.checkCancellation()
      let data: Data
      let response: URLResponse
      if let upload {
        (data, response) = try await BoundedHTTP.upload(session,request:request,file:upload)
      } else {
        let (file, r) = try await BoundedHTTP.download(session,request:request,maximum:8_388_608)
        defer { try? FileManager.default.removeItem(at: file) }
        guard try (file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8_388_608
        else { throw MobileError.incomplete }
        data = try Data(contentsOf: file)
        response = r
      }
      if request.httpMethod == "GET", let r = response as? HTTPURLResponse,
        [429, 500, 502, 503, 504].contains(r.statusCode), attempt < 2
      {
        let delay = min(
          5,
          max(0.25, Double(r.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(attempt + 1))
        )
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        continue
      }
      _ = try check(response)
      guard data.count <= 8_388_608 else { throw MobileError.incomplete }
      if data.isEmpty { return [:] }
      guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        result["status"] as? String != "error",
        (result["errors"] as? [String: Any])?.isEmpty ?? true
      else { throw MobileError.incomplete }
      return result
    }
    throw MobileError.network(429)
  }
  private func api(
    _ method: String, _ route: String, query: [String: String] = [:], body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    try await json(request(method, route, query: query, body: body))
  }
  public func accountID() async throws -> Int64 {
    let result = try await api("GET", "users/me")
    guard let user = result["user"] as? [String: Any], let id = DrimeEntry.integer(user["id"]),
      id > 0,
      settings.accountID == nil || settings.accountID == id
    else { throw MobileError.credential }
    return id
  }
  private func entry(_ id: Int64) async throws -> DrimeEntry {
    let result = try await api("GET", "file-entries/\(id)")
    guard let raw = result["fileEntry"] ?? result["entry"] else { throw MobileError.incomplete }
    let value = try DrimeEntry.parse(raw)
    guard value.id == id else { throw MobileError.incomplete }
    if value.deleted { throw VaultCoreError.missing }
    return value
  }
  private func children(_ parent: Int64?) async throws -> [DrimeEntry] {
    var values = [DrimeEntry]()
    var seen = Set<Int64>()
    var expectedTotal: Int?
    for page in 1...200 {
      var query = ["perPage": "1000", "page": String(page), "orderBy": "name", "orderDir": "asc"]
      if let parent { query["folderId"] = String(parent) }
      let result = try await api("GET", "drive/file-entries", query: query)
      guard let raw = result["data"] as? [Any],
        let current = DrimeEntry.integer(result["current_page"]), current == page,
        let last = DrimeEntry.integer(result["last_page"]), last >= page, last <= 200,
        let total = DrimeEntry.integer(result["total"]), total >= 0, total <= 20_000,
        expectedTotal == nil || expectedTotal == Int(total)
      else { throw MobileError.incomplete }
      expectedTotal = Int(total)
      for value in raw {
        let item = try DrimeEntry.parse(value)
        guard !item.deleted, item.parent == parent, item.workspace == settings.workspaceID,
          seen.insert(item.id).inserted
        else { throw MobileError.incomplete }
        values.append(item)
      }
      guard values.count <= 20_000, page == last || !raw.isEmpty else {
        throw MobileError.incomplete
      }
      if page == last {
        guard values.count == expectedTotal else { throw MobileError.incomplete }
        // Duplicate names cannot safely be mapped to a filesystem path.
        guard Set(values.map { Data($0.name.utf8) }).count == values.count else {
          throw MobileError.conflict
        }
        return values
      }
    }
    throw MobileError.incomplete
  }
  private func named(_ name: String, parent: Int64?) async throws -> DrimeEntry? {
    try await children(parent).first { Array($0.name.utf8) == Array(name.utf8) }
  }
  private func resolve(_ path: String) async throws -> DrimeEntry {
    let path = try MobilePath.checked(path)
    var parent = settings.rootFolderID
    if path.isEmpty {
      if let parent {
        let root = try await entry(parent)
        guard root.directory, root.workspace == settings.workspaceID else {
          throw MobileError.forbidden
        }
        return root
      }
      return .root(workspace: settings.workspaceID)
    }
    let components = path.split(separator: "/").map(String.init)
    var result: DrimeEntry?
    for (index, name) in components.enumerated() {
      guard let value = try await named(name, parent: parent),
        index == components.count - 1 || value.directory
      else { throw VaultCoreError.missing }
      result = value
      parent = value.id
    }
    return result!
  }
  private func parent(_ path: String) async throws -> (DrimeEntry, String) {
    let pieces = try MobilePath.checked(path).split(separator: "/").map(String.init)
    guard let name = pieces.last else { throw MobileError.invalidName }
    let folder = try await resolve(pieces.dropLast().joined(separator: "/"))
    guard folder.directory else { throw MobileError.invalidName }
    return (folder, name)
  }
  private func rootID(_ entry: DrimeEntry) -> Int64? { entry.id == 0 ? nil : entry.id }
  public func stat(_ path: String) async throws -> CipherItem {
    let lease = try await lease()
    defer { withExtendedLifetime(lease) {} }
    return try await resolve(path).item
  }
  public func list(_ path: String) async throws -> [CipherItem] {
    let lease = try await lease()
    defer { withExtendedLifetime(lease) {} }
    let folder = try await resolve(path)
    guard folder.directory else { throw MobileError.invalidName }
    let journal = try state()
    return try await children(rootID(folder)).filter {
      let item = $0
      let retained = journal.cleanup.contains {
        $0.id == item.id && $0.name == item.name && $0.parent == item.parent
          && $0.version == item.version
      }
      let staging = item.name == journal.upload?.name && item.parent == journal.upload?.parent
      return !retained && !staging
        && !(item.id == journal.move?.oldID && item.name == journal.move?.backupName)
    }.map(\.item)
  }
  private func downloadEntry(_ entry: DrimeEntry, to file: URL, maximum: Int? = nil) async throws {
    guard !entry.directory, !entry.hash.isEmpty else { throw MobileError.incomplete }
    var r = try request("GET", "file-entries/download/" + entry.hash)
    var authenticated = true
    for _ in 0..<5 {
      let (temp, response): (URL, URLResponse)
      if let maximum { (temp, response) = try await BoundedHTTP.download(session,request:r,maximum:maximum) }
      else { (temp, response) = try await session.download(for:r) }
      defer { try? FileManager.default.removeItem(at: temp) }
      guard let response = response as? HTTPURLResponse else { throw MobileError.incomplete }
      if [301, 302, 303, 307, 308].contains(response.statusCode) {
        guard let location = response.value(forHTTPHeaderField: "Location"),
          let url = URL(string: location, relativeTo: r.url)?.absoluteURL,
          url.scheme == "https"
            || (testing && url.scheme == "http"
              && ["127.0.0.1", "localhost"].contains(url.host ?? "")),
          url.user == nil, url.password == nil, url.fragment == nil
        else { throw MobileError.invalidAddress }
        authenticated =
          authenticated && url.scheme == base.scheme && url.host == base.host
          && url.port == base.port
        r = URLRequest(url: url)
        if authenticated { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        continue
      }
      _ = try check(response)
      guard response.statusCode == 200,
        try Int64(temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == entry.size
      else { throw MobileError.incomplete }
      if !entry.fileHash.isEmpty {
        guard try S3Signature.digest(temp) == entry.fileHash else { throw MobileError.incomplete }
      }
      if FileManager.default.fileExists(atPath: file.path) {
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
      } else {
        try FileManager.default.moveItem(at: temp, to: file)
      }
      try repository.protect(file)
      return
    }
    throw MobileError.incomplete
  }
  public func download(_ path: String, to file: URL) async throws {
    let lease = try await lease()
    defer { withExtendedLifetime(lease) {} }
    let value = try await resolve(path)
    try await downloadEntry(value, to: file)
    guard try await resolve(path).version == value.version else { throw MobileError.conflict }
  }
  public func read(_ path: String, limit: Int) async throws -> Data {
    let lease = try await lease()
    defer { withExtendedLifetime(lease) {} }
    let value = try await resolve(path)
    guard limit >= 0, value.size <= limit else { throw MobileError.incomplete }
    let file = repository.root.appendingPathComponent("drime-read-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try await downloadEntry(value, to: file, maximum:limit)
    guard try await resolve(path).version == value.version else { throw MobileError.conflict }
    return try Data(contentsOf: file)
  }
  public func mkdir(_ path: String) async throws {
    let lease = try await lease()
    defer { withExtendedLifetime(lease) {} }
    try await recoverMove()
    var folder = try await resolve("")
    for name in try MobilePath.checked(path).split(separator: "/").map(String.init) {
      if let found = try await named(name, parent: rootID(folder)) {
        guard found.directory else { throw VaultCoreError.exists }
        folder = found
        continue
      }
      let result = try await api(
        "POST", "folders",
        body: ["name": name, "parentId": rootID(folder).map { $0 as Any } ?? NSNull()])
      guard let raw = result["folder"] else { throw MobileError.incomplete }
      let created = try DrimeEntry.parse(raw)
      guard created.name == name, created.parent == rootID(folder), created.directory else {
        throw MobileError.incomplete
      }
      folder = created
    }
  }
  private func rename(_ value: DrimeEntry, _ name: String) async throws {
    if Array(value.name.utf8) == Array(name.utf8) { return }
    _ = try await api("PUT", "file-entries/\(value.id)", body: ["name": try MobilePath.name(name)])
  }
  /// Confirmation is language-independent. A localized 422 is not success:
  /// complete parent listing AND entry metadata must establish absence.
  private func trash(_ value: DrimeEntry) async throws {
    var failure: Error?
    do {
      _ = try await api(
        "POST", "file-entries/delete", body: ["entryIds": [value.id], "deleteForever": false])
    } catch { failure = error }
    for attempt in 0..<3 {
      let listed = try await children(value.parent)
      if !listed.contains(where: { $0.id == value.id }) {
        do { _ = try await entry(value.id) } catch VaultCoreError.missing { return }
      }
      if attempt < 2 { try await Task.sleep(nanoseconds: 250_000_000) }
    }
    throw failure ?? MobileError.incomplete
  }
  public func delete(_ path: String, directory: Bool) async throws {
    let lease = try await lease()
    defer { withExtendedLifetime(lease) {} }
    guard !path.isEmpty else { throw MobileError.forbidden }
    try await recoverMove()
    let value = try await resolve(path)
    guard value.directory == directory else { throw MobileError.conflict }
    if directory, !(try await children(value.id)).isEmpty { throw VaultCoreError.busy }
    try await trash(value)
  }
  private func digestMatches(_ value: DrimeEntry, digest: String, size: Int64) async throws -> Bool
  {
    guard value.size == size, !value.directory else { return false }
    do {
      let result = try await api(
        "POST", "file-entries/\(value.id)/verify-integrity", body: ["sha256": digest])
      guard let verified = result["verified"] as? Bool, let hash = result["serverHash"] as? String
      else { throw MobileError.incomplete }
      return verified && hash.lowercased() == digest
    } catch MobileError.forbidden {
      // Shared files may be readable/writable but only their owner may ask Drime to hash them.
    } catch VaultCoreError.missing {
      // Older server deployments may not yet expose the integrity endpoint.
    }
    let file = repository.root.appendingPathComponent("drime-verify-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try await downloadEntry(value, to: file)
    return try S3Signature.digest(file) == digest
  }
  private func cleanupPrevious() async throws {
    var journal = try state()
    for session in journal.sessions {
      do {
        _ = try await api(
          "POST", "s3/multipart/abort", body: ["uploadId": session.uploadID, "key": session.key])
        journal.sessions.removeAll { $0.uploadID == session.uploadID }
        try save(journal)
      } catch VaultCoreError.missing {
        journal.sessions.removeAll { $0.uploadID == session.uploadID }
        try save(journal)
      } catch { /* Keep the owned session recorded; never claim it was aborted. */  }
    }
    for record in journal.cleanup {
      do {
        let current = try await entry(record.id)
        // Never trash an entry the user moved/renamed since the plan was committed.
        guard current.name == record.name, current.parent == record.parent,
          record.version == current.version
        else { continue }
        try await trash(current)
        journal.cleanup.removeAll { $0.id == record.id }
        try save(journal)
      } catch VaultCoreError.missing {
        journal.cleanup.removeAll { $0.id == record.id }
        try save(journal)
      } catch { /* committed replacement remains successful; retry cleanup on a later write */  }
    }
  }
  private func recoverMove() async throws {
    guard let plan = try state().move else { return }
    var source = try await entry(plan.sourceID)
    guard [plan.sourceParent, plan.destinationParent].contains(source.parent),
      [plan.sourceName, plan.temporaryName, plan.destinationName].contains(source.name),
      source.directory == plan.directory
    else { throw MobileError.conflict }
    if source.parent == plan.destinationParent && source.name == plan.destinationName {
      try await finish(plan, source: source)
      return
    }
    if let oldID = plan.oldID {
      let old = try await entry(oldID)
      guard old.parent == plan.destinationParent,
        old.version == plan.oldVersion || old.name == plan.backupName
      else { throw MobileError.conflict }
      if old.name != plan.backupName { try await rename(old, plan.backupName) }
      let saved = try await entry(oldID)
      guard saved.name == plan.backupName, saved.parent == plan.destinationParent else {
        throw MobileError.incomplete
      }
      var journal = try state()
      journal.move?.backupVersion = saved.version
      try save(journal)
    }
    if let target = try await named(plan.destinationName, parent: plan.destinationParent),
      target.id != plan.sourceID
    {
      throw MobileError.conflict
    }
    if source.parent != plan.destinationParent {
      if source.name != plan.temporaryName {
        try await rename(source, plan.temporaryName)
        source = try await entry(source.id)
      }
      guard try await named(plan.temporaryName, parent: plan.destinationParent) == nil else {
        throw MobileError.conflict
      }
      _ = try await api(
        "POST", "file-entries/move",
        body: [
          "entryIds": [source.id],
          "destinationId": plan.destinationParent.map { $0 as Any } ?? NSNull(),
        ])
      source = try await entry(source.id)
      guard source.parent == plan.destinationParent else { throw MobileError.incomplete }
    }
    try await rename(source, plan.destinationName)
    try await finish(plan, source: try await entry(source.id))
  }
  private func finish(_ plan: DrimeMovePlan, source: DrimeEntry) async throws {
    guard source.id == plan.sourceID, source.name == plan.destinationName,
      source.parent == plan.destinationParent,
      let listed = try await named(plan.destinationName, parent: plan.destinationParent),
      listed.id == source.id
    else { throw MobileError.incomplete }
    guard source.directory || source.size == plan.size else { throw MobileError.incomplete }
    if !source.directory, !plan.digest.isEmpty {
      if !source.fileHash.isEmpty {
        guard source.fileHash == plan.digest else { throw MobileError.conflict }
      } else {
        guard try await digestMatches(source, digest: plan.digest, size: plan.size) else {
          throw MobileError.incomplete
        }
      }
    }
    var journal = try state()
    if let id = plan.oldID, !journal.cleanup.contains(where: { $0.id == id }) {
      journal.cleanup.append(
        DrimeCleanup(
          id: id, name: plan.backupName, parent: plan.destinationParent,
          version: journal.move?.backupVersion))
    }
    journal.move = nil
    try save(journal)
    // Cleanup errors cannot turn an already verified commit into a failed upload/reupload loop.
    try await cleanupPrevious()
  }
  private func moveEntry(
    _ source: DrimeEntry, destinationParent: Int64?, name: String,
    replace: Bool, digest: String = "", sourcePath: String? = nil, destinationPath: String? = nil
  ) async throws {
    if source.parent == destinationParent && Array(source.name.utf8) == Array(name.utf8) { return }
    let old = try await named(name, parent: destinationParent)
    guard old == nil || (replace && !source.directory && old?.directory == false) else {
      throw VaultCoreError.exists
    }
    var journal = try state()
    guard journal.move == nil, journal.cleanup.count < 128 else { throw MobileError.busy }
    let nonce = UUID().uuidString
    journal.move = DrimeMovePlan(
      sourceID: source.id, sourceParent: source.parent, sourceName: source.name,
      destinationParent: destinationParent, destinationName: name, directory: source.directory,
      size: source.size, digest: digest,
      oldID: old?.id, oldVersion: old?.version, backupName: ".cloudmount-previous-" + nonce,
      temporaryName: ".cloudmount-move-" + nonce)
    journal.move?.sourcePath = sourcePath
    journal.move?.destinationPath = destinationPath
    try save(journal)
    try await recoverMove()
  }
  public func move(_ source: String, to destination: String, directory: Bool, replace: Bool)
    async throws
  {
    let lease = try await lease()
    defer { withExtendedLifetime(lease) {} }
    let source = try MobilePath.checked(source)
    let destination = try MobilePath.checked(destination)
    guard !source.isEmpty, !destination.isEmpty, !destination.hasPrefix(source + "/") else {
      throw MobileError.invalidName
    }
    let pending = try state().move
    try await recoverMove()
    // A retry may just have completed the persisted rename, so the old path is legitimately gone.
    if let pending, pending.sourcePath == source && pending.destinationPath == destination {
      return
    }
    let value = try await resolve(source)
    guard value.directory == directory else { throw MobileError.conflict }
    let (folder, name) = try await parent(destination)
    try await moveEntry(
      value, destinationParent: rootID(folder), name: name, replace: replace, sourcePath: source,
      destinationPath: destination)
  }
  /// A vault retry encrypts again with a new nonce and staging name. Retire only
  /// the earlier owned staging upload; never block all future writes on its old digest.
  private func prepareUpload(path: String, digest: String, size: Int64) async throws {
    var journal = try state()
    guard let prior = journal.upload,
      prior.path != path || prior.digest != digest || prior.size != size
    else { return }
    if let staged = try await named(prior.name, parent: prior.parent) {
      guard prior.entryID == nil || prior.entryID == staged.id,
        try await digestMatches(staged, digest: prior.digest, size: prior.size),
        journal.cleanup.count < 128
      else { throw MobileError.conflict }
      // Integrity verification can populate file_hash (and update the revision).
      let confirmed = try await entry(staged.id)
      guard confirmed.name == staged.name, confirmed.parent == staged.parent,
        confirmed.size == staged.size
      else { throw MobileError.conflict }
      journal.cleanup.append(
        DrimeCleanup(
          id: confirmed.id, name: confirmed.name, parent: confirmed.parent,
          version: confirmed.version))
    } else if let uploadID = prior.uploadID, let key = prior.key {
      // A committed entry no longer has its staging name; don't abort its completed upload.
      let committed: Bool
      if let id = prior.entryID, let value = try? await resolve(prior.path) {
        committed = value.id == id
      } else {
        committed = false
      }
      if !committed {
        guard journal.sessions.count < 16 else { throw MobileError.busy }
        if !journal.sessions.contains(where: { $0.uploadID == uploadID }) {
          journal.sessions.append(DrimeMultipartSession(uploadID: uploadID, key: key))
        }
      }
    }
    journal.upload = nil
    try save(journal)
  }
  public func upload(_ file: URL, to path: String) async throws {
    try await put(file, path: path, expected: nil, requireNew: false)
  }
  public func put(_ file: URL, path: String, expected: String?, requireNew: Bool) async throws {
    let lease = try await lease()
    defer { withExtendedLifetime(lease) {} }
    let path = try MobilePath.checked(path)
    let digest = try S3Signature.digest(file)
    // URL.resourceValues may retain a cached size when an editor rewrites the same URL.
    let size =
      (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
      ?? -1
    guard size >= 0, size <= 5_000_000_000_000 else { throw MobileError.quota }
    try await recoverMove()
    try await prepareUpload(path: path, digest: digest, size: size)
    try await cleanupPrevious()
    let (folder, name) = try await parent(path)
    let parentID = rootID(folder)
    var journal = try state()
    if let prior = journal.upload {
      guard prior.path == path, prior.digest == digest, prior.size == size else {
        throw MobileError.busy
      }
      if let final = try await named(name, parent: parentID), final.id == prior.entryID,
        try await digestMatches(final, digest: digest, size: size)
      {
        journal.upload = nil
        try save(journal)
        return
      }
    }
    let old = try await named(name, parent: parentID)
    if requireNew, old != nil { throw MobileError.conflict }
    if let expected, old?.version != expected { throw MobileError.conflict }
    if old?.directory == true { throw MobileError.conflict }
    if journal.upload == nil {
      journal.upload = DrimeUploadPlan(
        path: path, parent: parentID, name: ".cloudmount-upload-" + UUID().uuidString + ".bin",
        digest: digest, size: size)
      try save(journal)
    }
    var plan = journal.upload!
    let staged: DrimeEntry
    if let found = try await named(plan.name, parent: parentID) {
      guard try await digestMatches(found, digest: digest, size: size) else {
        throw MobileError.conflict
      }
      staged = found
    } else {
      staged = try await uploadStaged(file, plan: &plan)
    }
    guard staged.parent == parentID, staged.name == plan.name,
      try await digestMatches(staged, digest: digest, size: size)
    else { throw MobileError.incomplete }
    plan.entryID = staged.id
    journal = try state()
    journal.upload = plan
    try save(journal)
    let current = try await named(name, parent: parentID)
    guard current?.version == old?.version else { throw MobileError.conflict }
    try await moveEntry(
      staged, destinationParent: parentID, name: name, replace: !requireNew, digest: digest)
    journal = try state()
    journal.upload = nil
    try save(journal)
  }
  public func retryMaintenance() async throws {
    let lease = try await lease()
    defer { withExtendedLifetime(lease) {} }
    try await recoverMove()
    try await cleanupPrevious()
  }
  public nonisolated static func maintenanceStatus(repository: MobileRepository, connectionID: UUID)
    throws -> DrimeMaintenanceStatus
  {
    let journal: DrimeJournal = try repository.read(
      "drime-\(connectionID).json", default: DrimeJournal())
    return DrimeMaintenanceStatus(
      retainedPreviousVersions: journal.cleanup.count,
      interruptedOperation: journal.move != nil || journal.upload != nil,
      pendingMultipartSessions: journal.sessions.count)
  }
  private func uploadStaged(_ file: URL, plan: inout DrimeUploadPlan) async throws -> DrimeEntry {
    if plan.size >= 5_242_880 { return try await multipart(file, plan: &plan) }
    let boundary = "CloudMount" + UUID().uuidString
    let body = repository.root.appendingPathComponent("drime-form-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: body.path, contents: nil) else {
      throw MobileError.quota
    }
    try repository.protect(body)
    defer { try? FileManager.default.removeItem(at: body) }
    let out = try FileHandle(forWritingTo: body)
    defer { try? out.close() }
    func write(_ value: String) throws { try out.write(contentsOf: Data(value.utf8)) }
    let fields = [
      "parentId": plan.parent.map(String.init) ?? "", "workspaceId": String(settings.workspaceID),
      "relativePath": plan.name, "fileHash": plan.digest,
    ]
    for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
      try write(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
    }
    try write(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(plan.name)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
    )
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      try out.write(contentsOf: data)
    }
    try write("\r\n--\(boundary)--\r\n")
    try out.synchronize()
    var r = try request("POST", "uploads")
    r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let result = try await json(r, upload: body)
    guard let raw = result["fileEntry"] else { throw MobileError.incomplete }
    return try DrimeEntry.parse(raw)
  }
  private func multipart(_ file: URL, plan: inout DrimeUploadPlan) async throws -> DrimeEntry {
    // Persist session identity so a later retry can abort only this owned session.
    // Failed transfers retain the original local pending file; no background-completion claim.
    if let uploadID = plan.uploadID, let key = plan.key {
      var journal = try state()
      guard journal.sessions.count < 16 else { throw MobileError.busy }
      if !journal.sessions.contains(where: { $0.uploadID == uploadID }) {
        journal.sessions.append(DrimeMultipartSession(uploadID: uploadID, key: key))
      }
      plan.uploadID = nil
      plan.key = nil
      journal.upload = plan
      try save(journal)
      try await cleanupPrevious()
    }
    let context: [String: Any] = [
      "filename": plan.name, "mime": "application/octet-stream", "extension": "bin",
      "size": plan.size, "parentId": plan.parent.map { $0 as Any } ?? NSNull(),
      "relativePath": plan.name, "workspaceId": settings.workspaceID,
    ]
    let created = try await api("POST", "s3/multipart/create", body: context)
    guard let id = created["uploadId"] as? String, !id.isEmpty, let key = created["key"] as? String,
      !key.isEmpty
    else { throw MobileError.incomplete }
    plan.uploadID = id
    plan.key = key
    var journal = try state()
    journal.upload = plan
    try save(journal)
    let partSize = max(
      Int64(5_242_880), ((plan.size + 9999) / 10000 + 1_048_575) / 1_048_576 * 1_048_576)
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var parts = [[String: Any]]()
    var remaining = plan.size
    var number = 1
    while remaining > 0 {
      try Task.checkCancellation()
      let size = min(remaining, partSize)
      let part = repository.root.appendingPathComponent("drime-part-" + UUID().uuidString)
      guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
        throw MobileError.quota
      }
      try repository.protect(part)
      defer { try? FileManager.default.removeItem(at: part) }
      let out = try FileHandle(forWritingTo: part)
      do {
        var rest = size
        while rest > 0 {
          guard let data = try input.read(upToCount: Int(min(rest, 1_048_576))), !data.isEmpty
          else { throw MobileError.incomplete }
          try out.write(contentsOf: data)
          rest -= Int64(data.count)
        }
        try out.close()
      } catch {
        try? out.close()
        throw error
      }
      let signed = try await api(
        "POST", "s3/multipart/batch-sign-part-urls",
        body: ["uploadId": id, "key": key, "partNumbers": [number]])
      guard let urls = signed["urls"] as? [[String: Any]], urls.count == 1,
        DrimeEntry.integer(urls[0]["partNumber"]) == Int64(number),
        let address = urls[0]["url"] as? String, let url = URL(string: address),
        url.scheme == "https" || (testing && url.scheme == "http" && url.host == "127.0.0.1"),
        url.user == nil, url.password == nil, url.fragment == nil
      else { throw MobileError.incomplete }
      var r = URLRequest(url: url)
      r.httpMethod = "PUT"
      r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
      // No Drime Bearer token on storage-provider signed URLs, including redirects.
      let (_, response) = try await BoundedHTTP.upload(session,request:r,file:part,maximum:65_536)
      let checked = try check(response)
      guard let tag = checked.value(forHTTPHeaderField: "ETag"), !tag.isEmpty else {
        throw MobileError.incomplete
      }
      parts.append(["PartNumber": number, "ETag": tag])
      number += 1
      remaining -= size
      try FileManager.default.removeItem(at: part)
    }
    _ = try await api(
      "POST", "s3/multipart/complete", body: ["uploadId": id, "key": key, "parts": parts])
    let result = try await api(
      "POST", "s3/entries",
      body: [
        "clientMime": "application/octet-stream", "clientName": plan.name,
        "filename": String(key.split(separator: "/").last ?? ""), "size": plan.size,
        "clientExtension": "bin", "parentId": plan.parent.map { $0 as Any } ?? NSNull(),
        "relativePath": plan.name, "workspaceId": settings.workspaceID,
      ])
    guard let raw = result["fileEntry"] else { throw MobileError.incomplete }
    return try DrimeEntry.parse(raw)
  }
}

private final class DrimeSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
private struct DrimeEntry: Sendable {
  var id: Int64, parent: Int64?, workspace: Int64
  var name: String, hash: String, modified: Date, stamp: String, size: Int64, directory: Bool,
    deleted: Bool
  var fileHash: String = ""
  var version: String { "\(id):\(stamp):\(size):\(fileHash)" }
  var item: CipherItem {
    CipherItem(name: name, size: size, modified: modified, version: version, isDirectory: directory)
  }
  static func root(workspace: Int64) -> Self {
    Self(
      id: 0, parent: nil, workspace: workspace, name: "", hash: "", modified: .distantPast,
      stamp: "root", size: 0, directory: true, deleted: false)
  }
  static func integer(_ raw: Any?) -> Int64? {
    if let value = raw as? String { return Int64(value) }
    if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
      value.doubleValue.isFinite,
      value.doubleValue.rounded() == value.doubleValue
    {
      return Int64(value.stringValue)
    }
    return nil
  }
  static func parse(_ raw: Any) throws -> Self {
    guard let raw = raw as? [String: Any], let id = integer(raw["id"]), id > 0,
      let name = raw["name"] as? String, (try? MobilePath.name(name)) != nil,
      let type = raw["type"] as? String, !type.isEmpty,
      let stamp = (raw["updated_at"] ?? raw["created_at"]) as? String,
      let workspace = integer(raw["workspace_id"]), workspace >= 0,
      raw["parent_id"] == nil || raw["parent_id"] is NSNull || integer(raw["parent_id"]) != nil
    else { throw MobileError.incomplete }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = format.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
    let directory = type == "folder"
    let size = integer(raw["file_size"]) ?? (type == "folder" ? 0 : -1)
    let hash = raw["hash"] as? String ?? ""
    guard let date, size >= 0,
      directory
        || (!hash.isEmpty && hash.utf8.count <= 1024
          && hash.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
          })
    else {
      throw MobileError.incomplete
    }
    let fileHash = (raw["file_hash"] as? String ?? "").lowercased()
    return Self(
      id: id, parent: integer(raw["parent_id"]), workspace: workspace, name: name,
      hash: raw["hash"] as? String ?? "", modified: date, stamp: stamp, size: directory ? 0 : size,
      directory: directory,
      deleted: (raw["deleted_at"] != nil && !(raw["deleted_at"] is NSNull))
        || (integer(raw["is_deleted"]) ?? 0) != 0 || raw["is_deleted"] as? Bool == true,
      fileHash: fileHash.count == 64 && fileHash.allSatisfy({ $0.isHexDigit }) ? fileHash : "")
  }
}
private struct DrimeJournal: Codable {
  var move: DrimeMovePlan?
  var upload: DrimeUploadPlan?
  var cleanup: [DrimeCleanup] = []
  var sessions: [DrimeMultipartSession] = []
  enum CodingKeys: String, CodingKey { case move, upload, cleanup, sessions }
  init() {}
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    move = try c.decodeIfPresent(DrimeMovePlan.self, forKey: .move)
    upload = try c.decodeIfPresent(DrimeUploadPlan.self, forKey: .upload)
    cleanup = try c.decodeIfPresent([DrimeCleanup].self, forKey: .cleanup) ?? []
    sessions = try c.decodeIfPresent([DrimeMultipartSession].self, forKey: .sessions) ?? []
  }
}
private struct DrimeMultipartSession: Codable {
  var uploadID: String
  var key: String
}
public struct DrimeMaintenanceStatus: Sendable {
  public var retainedPreviousVersions: Int
  public var interruptedOperation: Bool
  public var pendingMultipartSessions: Int
}
private struct DrimeCleanup: Codable {
  var id: Int64
  var name: String
  var parent: Int64?
  var version: String? = nil
}
private struct DrimeMovePlan: Codable {
  var sourceID: Int64, sourceParent: Int64?, sourceName: String
  var destinationParent: Int64?, destinationName: String, directory: Bool, size: Int64,
    digest: String
  var oldID: Int64?, oldVersion: String?, backupName: String, temporaryName: String
  // Paths are filled by the caller for retry recognition; identifiers are authoritative.
  var sourcePath: String? = nil
  var destinationPath: String? = nil
  var backupVersion: String? = nil
}
private struct DrimeUploadPlan: Codable {
  var path: String, parent: Int64?, name: String, digest: String, size: Int64
  var entryID: Int64?
  var uploadID: String?
  var key: String?
}
