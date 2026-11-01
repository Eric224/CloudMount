import CloudMountVaultCore
import Foundation
import CryptoKit

/// Stable entity identity for listings/stat. This does not promote a weak
/// wire ETag into a valid If-Match validator; put() separately checks that.
enum DAVRevision {
  static func normalized(_ value: String) -> String {
    value.hasPrefix("W/\"") && value.hasSuffix("\"") ? String(value.dropFirst(2)) : value
  }
}
enum DAVRedirectPolicy {
  static func permits(from source: URL, to target: URL) -> Bool {
    guard let a = URLComponents(url: source, resolvingAgainstBaseURL: false),
      let b = URLComponents(url: target, resolvingAgainstBaseURL: false),
      a.scheme?.lowercased() == b.scheme?.lowercased(),
      a.host?.lowercased() == b.host?.lowercased(),
      (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80)),
      b.user == nil, b.password == nil, b.fragment == nil,
      a.percentEncodedQuery == b.percentEncodedQuery
    else { return false }
    let left = normalizedEscapes(a.percentEncodedPath), right = normalizedEscapes(b.percentEncodedPath)
    // Percent-escape hexadecimal case is equivalent in URLs. Preserve actual
    // filename case and never decode reserved characters such as an encoded '/'.
    return a.percentEncodedPath != b.percentEncodedPath &&
      (left == right || left + "/" == right || right + "/" == left)
  }
  private static func normalizedEscapes(_ value: String) -> String {
    var bytes = Array(value.utf8), index = 0
    while index + 2 < bytes.count {
      if bytes[index] == 37 {
        for offset in 1...2 where (97...102).contains(bytes[index+offset]) {
          bytes[index+offset] -= 32
        }
        index += 3
      } else { index += 1 }
    }
    return String(decoding:bytes,as:UTF8.self)
  }
}
private final class DAVSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Redirects are replayed explicitly below. Automatic redirects can turn
    // WebDAV methods into GET or drop a file-upload body.
    completionHandler(nil)
  }
}
public protocol NativeConditionalStore: CiphertextStore {
  func put(_ file: URL, path: String, expected: String?, requireNew: Bool) async throws
}
public final class WebDAVStore: NativeConditionalStore, @unchecked Sendable {
  let base: URL
  private let authorization: String
  private let session: URLSession
  private let delegate = DAVSessionDelegate()
  public init(endpoint: URL, username: String, password: String, allowLoopbackHTTP: Bool = false)
    throws
  {
    guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
      let host = parts.host,
      !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil,
      parts.fragment == nil,
      parts.scheme == "https"
        || (allowLoopbackHTTP && parts.scheme == "http"
          && ["127.0.0.1", "localhost", "::1"].contains(host))
    else { throw MobileError.invalidAddress }
    if !parts.path.hasSuffix("/") { parts.path += "/" }
    guard let url = parts.url else { throw MobileError.invalidAddress }
    base = url
    authorization = "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 25
    config.timeoutIntervalForResource = 120
    config.httpMaximumConnectionsPerHost = 2
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }
  func url(_ path: String, directory: Bool = false) throws -> URL {
    let path = try MobilePath.checked(path)
    var result = base
    for component in path.split(separator: "/") {
      result.appendPathComponent(String(component), isDirectory: false)
    }
    if directory && !result.path.hasSuffix("/") {
      result.appendPathComponent("", isDirectory: true)
    }
    return result
  }
  private func request(_ method: String, _ path: String, directory: Bool = false) throws
    -> URLRequest
  {
    var request = URLRequest(url: try url(path, directory: directory))
    request.httpMethod = method
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    request.setValue("no-cache",forHTTPHeaderField:"Cache-Control")
    return request
  }
  private func check(_ response: URLResponse, codes: Set<Int>) throws {
    guard let response = response as? HTTPURLResponse else { throw MobileError.network(0) }
    guard codes.contains(response.statusCode) else {
      switch response.statusCode {
      case 401: throw MobileError.credential
      case 403: throw MobileError.forbidden
      case 404: throw VaultCoreError.missing
      case 409, 412: throw MobileError.conflict
      case 507: throw MobileError.quota
      default: throw MobileError.network(response.statusCode)
      }
    }
  }
  private func canonicalRequest(_ response: URLResponse, original: URLRequest, attempt: Int)
    -> URLRequest?
  {
    guard let response = response as? HTTPURLResponse,
      [301,302,307,308].contains(response.statusCode), let source = response.url,
      let location = response.value(forHTTPHeaderField: "Location"),
      let target = URL(string: location, relativeTo: source)?.absoluteURL
    else { return nil }
    guard attempt < 2, DAVRedirectPolicy.permits(from: source, to: target) else { return nil }
    var next = original
    next.url = target
    return next
  }
  private func downloadResponse(_ original: URLRequest, maximum:Int? = nil) async throws -> (URL, URLResponse) {
    var request = original
    for attempt in 0...2 {
      try Task.checkCancellation()
      let (file,response): (URL,URLResponse)
      if let maximum { (file,response) = try await BoundedHTTP.download(session,request:request,maximum:maximum) }
      else { (file,response) = try await session.download(for:request) }
      if let next = canonicalRequest(response, original: request, attempt: attempt) {
        try? FileManager.default.removeItem(at: file)
        request = next
      } else { return (file,response) }
    }
    throw MobileError.network(301)
  }
  private func uploadResponse(_ original: URLRequest, file: URL) async throws -> URLResponse {
    var request = original
    for attempt in 0...2 {
      try Task.checkCancellation()
      // Start a fresh upload from the protected file on every canonical hop.
      // Preserve method, complete body, authorization and If-Match/If-None-Match.
      let (_,response) = try await BoundedHTTP.upload(session,request:request,file:file,maximum:65_536)
      if let next = canonicalRequest(response, original: request, attempt: attempt) {
        request = next
      } else { return response }
    }
    throw MobileError.network(301)
  }
  private func small(_ request: URLRequest, codes: Set<Int>, limit: Int = 8_388_608) async throws
    -> Data
  {
    let (file, response) = try await downloadResponse(request,maximum:limit)
    defer { try? FileManager.default.removeItem(at: file) }
    try check(response, codes: codes)
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard size <= limit else { throw MobileError.incomplete }
    return try Data(contentsOf: file)
  }
  private func properties(_ path: String, depth: String, rawETag: Bool = false) async throws -> [CipherItem] {
    var request = try request("PROPFIND", path, directory: depth == "1")
    request.setValue(depth, forHTTPHeaderField: "Depth")
    request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>"
        .utf8)
    let data = try await small(request, codes: [207])
    let parser = DAVParser(data: data, base: base, requested: try url(path), rawETag: rawETag)
    let items = try parser.parse()
    if depth == "0" {
      guard items.count == 1 else { throw MobileError.incomplete }
      return items.map(\.item)
    }
    let expected = try url(path).path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return items.filter { $0.path != expected }.map(\.item)
  }
  public func stat(_ path: String) async throws -> CipherItem {
    try await properties(path, depth: "0")[0]
  }
  public func list(_ path: String) async throws -> [CipherItem] {
    try await properties(path, depth: "1")
  }
  public func read(_ path: String, limit: Int) async throws -> Data {
    guard try await stat(path).size <= limit else { throw MobileError.incomplete }
    return try await small(request("GET", path), codes: [200], limit: limit)
  }
  public func download(_ path: String, to file: URL) async throws {
    let (temporary, response) = try await downloadResponse(request("GET", path))
    defer { try? FileManager.default.removeItem(at: temporary) }
    try check(response, codes: [200])
    try Task.checkCancellation()
    guard !FileManager.default.fileExists(atPath: file.path) else { throw MobileError.conflict }
    try FileManager.default.copyItem(at: temporary, to: file)
  }
  public func upload(_ file: URL, to path: String) async throws {
    try await put(file, path: path, expected: nil, requireNew: false)
  }
  public func put(_ file: URL, path: String, expected: String?, requireNew: Bool) async throws {
    var request = try request("PUT", path)
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    if requireNew {
      request.setValue("*", forHTTPHeaderField: "If-None-Match")
    } else if let expected {
      // Never promote a weak property ETag into a strong HTTP validator.
      // Some DAV servers temporarily expose a weak property after creation;
      // HEAD with identity encoding can supply the actual strong wire tag.
      let current = try await properties(path, depth: "0", rawETag: true)[0]
      guard DAVRevision.normalized(current.version) == DAVRevision.normalized(expected) else {
        throw MobileError.conflict
      }
      var validator = current.version
      if validator.hasPrefix("W/\"") {
        for attempt in 0..<4 {
          var head = try self.request("HEAD", path)
          head.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
          let (body,response) = try await downloadResponse(head)
          try? FileManager.default.removeItem(at:body)
          try check(response,codes:[200])
          guard let tag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField:"ETag"),
            DAVRevision.normalized(tag) == DAVRevision.normalized(expected) else { throw MobileError.conflict }
          validator = tag
          if !validator.hasPrefix("W/") { break }
          if attempt < 3 { try await Task.sleep(for:.milliseconds(200 * (1 << attempt))) }
        }
      }
      guard validator.hasPrefix("\""), validator.hasSuffix("\"") else { throw MobileError.unsupported }
      request.setValue(validator,forHTTPHeaderField:"If-Match")
    }
    if let validator = request.value(forHTTPHeaderField:"If-Match") {
      try await replace(file,path:path,validator:validator)
      return
    }
    let response = try await uploadResponse(request, file: file)
    try check(response, codes: [200, 201, 204])
  }
  private func replace(_ file: URL, path: String, validator: String) async throws {
    let parent = path.split(separator:"/").dropLast().joined(separator:"/")
    let staged = (parent.isEmpty ? "" : parent+"/")+"cloudmount-upload-"+UUID().uuidString+".tmp"
    try await put(file,path:staged,expected:nil,requireNew:true)
    do {
      let uploaded = try await stat(staged)
      var commit = try request("MOVE",staged)
      let destination = try url(path).absoluteString
      commit.setValue(destination,forHTTPHeaderField:"Destination")
      commit.setValue("T",forHTTPHeaderField:"Overwrite")
      // RFC 4918 tagged If applies to the destination, unlike HTTP If-Match
      // on the MOVE source. Do not delete the original before committing.
      commit.setValue("<"+destination+"> (["+validator+"])",forHTTPHeaderField:"If")
      do { _ = try await small(commit,codes:[200,201,204]) }
      catch {
        let recover: Bool
        if case MobileError.network(let code) = error { recover = code >= 500 }
        else if let value = error as? URLError { recover = [.timedOut,.networkConnectionLost].contains(value.code) }
        else { recover = false }
        guard recover, try await matches(file,path:path) else { throw error }
        try? await delete(staged,directory:false)
        return
      }
      let after = try await stat(path)
      if after.size != uploaded.size || after.version != uploaded.version {
        guard try await matches(file,path:path) else { throw MobileError.conflict }
      }
    } catch {
      // Only this generated staging object is eligible for cleanup. The local
      // journal remains available to the caller if the commit was ambiguous.
      try? await delete(staged,directory:false)
      throw error
    }
  }
  private func matches(_ source: URL, path: String) async throws -> Bool {
    let before = try await stat(path)
    let (file,response) = try await downloadResponse(request("GET",path))
    defer { try? FileManager.default.removeItem(at:file) }
    try check(response,codes:[200])
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:file.path)
    #endif
    func hash(_ file:URL) throws -> Data {
      let handle = try FileHandle(forReadingFrom:file)
      defer { try? handle.close() }
      var hash = SHA256()
      while let data = try handle.read(upToCount:1_048_576), !data.isEmpty { hash.update(data:data) }
      return Data(hash.finalize())
    }
    guard try hash(source) == hash(file) else { return false }
    let after = try await stat(path)
    return before.version == after.version && before.size == after.size
  }
  public func mkdir(_ path: String) async throws {
    let parts = try MobilePath.checked(path).split(separator: "/")
    for count in 1...max(1, parts.count) {
      if parts.isEmpty { return }
      let prefix = parts.prefix(count).joined(separator: "/")
      // MKCOL is not consistently idempotent across DAV servers. pCloud may
      // return a self-redirect for an existing collection rather than 405.
      do {
        guard try await stat(prefix).isDirectory else { throw MobileError.conflict }
        continue
      } catch VaultCoreError.missing {}
      let request = try request("MKCOL", prefix, directory: true)
      let (body, response) = try await downloadResponse(request)
      defer { try? FileManager.default.removeItem(at: body) }
      if let r = response as? HTTPURLResponse, [301,302,307,308,405].contains(r.statusCode) {
        // Another client may create it after our existence check. Verify the
        // requested path directly; never follow a redirect to another resource.
        do {
          guard try await stat(prefix).isDirectory else { throw MobileError.conflict }
        } catch VaultCoreError.missing { try check(response, codes: [200,201,204]) }
      } else {
        try check(response, codes: [200, 201, 204])
      }
    }
  }
  public func move(_ source: String, to destination: String, directory: Bool, replace: Bool)
    async throws
  {
    let before = try await stat(source)
    guard before.isDirectory == directory else { throw MobileError.conflict }
    let children = directory ? try await list(source) : []
    var request = try request("MOVE", source, directory: directory)
    // A Destination identifies the new resource, not an existing container.
    // Some DAV servers mis-handle a trailing slash on a collection rename.
    request.setValue(try url(destination).absoluteString, forHTTPHeaderField: "Destination")
    request.setValue(replace ? "T" : "F", forHTTPHeaderField: "Overwrite")
    let failure: Error?
    do { _ = try await small(request, codes: [200, 201, 204]); failure = nil }
    catch { failure = error }

    // A response may be lost or report 5xx after a committed rename. A success
    // response can also be inaccurate. Verify the destination and source
    // disappearance. Error recovery additionally requires the same revision;
    // an acknowledged rename may legitimately change a file's timestamp/tag.
    for attempt in 0..<6 {
      do {
        let after = try await stat(destination)
        guard after.isDirectory == before.isDirectory, after.size == before.size else { throw MobileError.conflict }
        if directory {
          // Collection timestamps may change on rename; compare children.
          let movedChildren = try await list(destination)
          guard children.sorted(by:{$0.name < $1.name}) == movedChildren.sorted(by:{$0.name < $1.name}) else { throw MobileError.conflict }
        } else if failure != nil, after.version != before.version { throw MobileError.conflict }
        do {
          _ = try await stat(source)
          var head = try self.request("HEAD",source)
          head.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
          let (body,response) = try await downloadResponse(head)
          try? FileManager.default.removeItem(at:body)

          try check(response,codes:[200,404])
          guard (response as? HTTPURLResponse)?.statusCode == 404 else { throw MobileError.conflict }
        } catch VaultCoreError.missing {}
        return
      } catch {
        // DAV indexes can lag their completed mutation briefly. Retry only
        // verification, never the MOVE itself; keep the main actor responsive.
        switch error {
        case MobileError.conflict, VaultCoreError.missing: break
        default: throw failure ?? error
        }
        guard attempt < 5 else {
          if case VaultCoreError.missing = error { throw failure ?? MobileError.conflict }
          throw failure ?? error
        }
        try await Task.sleep(for:.milliseconds(min(100 * (1 << attempt),800)))
      }
    }
    throw failure ?? MobileError.conflict
  }

  public func delete(_ path: String, directory: Bool) async throws {
    guard !path.isEmpty else { throw MobileError.invalidName }
    if directory {
      for child in try await list(path) {
        // The directory index may lag a completed rename/delete. Only ignore
        // a stale entry after the actual child resource confirms 404. Any
        // existing child or unsupported/failed HEAD keeps deletion blocked.
        let childPath = try MobilePath.join(path,child.name)
        var head = try request("HEAD",childPath)
        head.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
        var absent = false
        for attempt in 0..<5 {
          let (body,response) = try await downloadResponse(head)
          try? FileManager.default.removeItem(at:body)
          try check(response,codes:[200,404])
          if (response as? HTTPURLResponse)?.statusCode == 404 { absent = true; break }
          if attempt < 4 { try await Task.sleep(for:.milliseconds(100 * (1 << attempt))) }
        }
        guard absent else { throw VaultCoreError.busy }
      }
    }
    _ = try await small(request("DELETE", path, directory: directory), codes: [200, 204])
  }
}

/// Reject partial/malformed/multi-status errors; a failed listing is never an
/// authoritative empty directory. Decode paths exactly once; enforce origin.
final class DAVParser: NSObject, XMLParserDelegate {
  struct Entry { let path: String; let item: CipherItem }
  let data: Data, base: URL, requested: URL
  let rawETag: Bool
  var stack: [String] = [], texts: [String] = []
  var href = "", responseStatus: Int?, propStatus: Int?
  var props: [String: String] = [:], accepted: [String: String] = [:]
  var entries: [Entry] = [], valid = true, sawRoot = false
  var seen = Set<Data>()
  init(data: Data, base: URL, requested: URL, rawETag: Bool = false) { self.data = data; self.base = base; self.requested = requested; self.rawETag = rawETag }
  func parse() throws -> [Entry] {
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = self
    guard parser.parse(), valid, sawRoot, entries.count <= 20_000,
      entries.contains(where: { $0.path == canonical(requested) }) else { throw MobileError.incomplete }
    return entries
  }
  private func canonical(_ url: URL) -> String { url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
  private func code(_ value: String) -> Int? {
    let parts = value.split(whereSeparator: \.isWhitespace)
    return parts.count >= 2 && parts[0].hasPrefix("HTTP/") ? Int(parts[1]) : nil
  }
  private func port(_ url: URL) -> Int? { url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil) }
  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
    let tag = namespaceURI == "DAV:" ? name : "other:" + name
    stack.append(tag); texts.append("")
    if tag == "multistatus", stack.count == 1 { sawRoot = true }
    if tag == "response" { href = ""; responseStatus = nil; accepted = [:] }
    if tag == "propstat" { props = [:]; propStatus = nil }
    if tag == "resourcetype", stack.dropLast().last == "prop" { props["resourcetype"] = "file" }
    if tag == "collection", stack.dropLast().last == "resourcetype" { props["resourcetype"] = "directory" }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard !texts.isEmpty else { return }
    texts[texts.count - 1] += string
    if texts[texts.count - 1].utf8.count > 65_536 { valid = false; parser.abortParsing() }
  }
  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    let tag = stack.last ?? "", parent = stack.dropLast().last
    let value = (texts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if parent == "prop", ["getcontentlength", "getetag", "getlastmodified"].contains(tag) { props[tag] = value }
    if tag == "href", parent == "response" { href = value }
    if tag == "status", parent == "propstat" { propStatus = code(value) }
    if tag == "status", parent == "response" { responseStatus = code(value) }
    if tag == "propstat" {
      // Failed optional properties (e.g. a directory's content length) are
      // absent, not malformed values. Only successful propstats contribute.
      if propStatus == 200 {
        for (key, value) in props {
          if let previous = accepted[key], previous != value { valid = false }
          accepted[key] = value
        }
      } else if propStatus == nil { valid = false }
    }
    if tag == "response" { finishResponse() }
    _ = stack.popLast(); _ = texts.popLast()
  }
  private func finishResponse() {
    guard responseStatus == nil || responseStatus == 200,
      let kind = accepted["resourcetype"], let url = URL(string: href, relativeTo: base)?.absoluteURL,
      url.host?.lowercased() == base.host?.lowercased(), url.scheme == base.scheme, port(url) == port(base),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else { valid = false; return }
    let path = canonical(url), requestPath = canonical(requested)
    let prefix = requestPath.isEmpty ? "" : requestPath + "/"
    guard path == requestPath || (path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/")),
      !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), seen.insert(Data(path.utf8)).inserted
    else { valid = false; return }
    let directory = kind == "directory"
    let size: Int64
    if directory { size = 0 }
    else {
      guard let text = accepted["getcontentlength"], let value = Int64(text), value >= 0 else { valid = false; return }
      size = value
    }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    let date = accepted["getlastmodified"].flatMap { f.date(from: $0) } ?? .distantPast
    let etag = accepted["getetag"] ?? ""
    entries.append(Entry(path: path, item: CipherItem(name: url.lastPathComponent, size: size, modified: date,
      version: etag.isEmpty ? "\(size):\(date.timeIntervalSince1970)" : (rawETag ? etag : DAVRevision.normalized(etag)), isDirectory: directory)))
  }
}

public struct PrefixedCiphertextStore: CiphertextStore {
  public let store: any CiphertextStore
  public let prefix: String
  public init(store: any CiphertextStore, prefix: String) throws {
    self.store = store
    self.prefix = try MobilePath.checked(prefix)
  }
  private func path(_ value: String) throws -> String {
    let value = try MobilePath.checked(value)
    return prefix.isEmpty ? value : (value.isEmpty ? prefix : prefix + "/" + value)
  }
  public func stat(_ value: String) async throws -> CipherItem { try await store.stat(path(value)) }
  public func list(_ value: String) async throws -> [CipherItem] {
    try await store.list(path(value))
  }
  public func read(_ value: String, limit: Int) async throws -> Data {
    try await store.read(path(value), limit: limit)
  }
  public func download(_ value: String, to file: URL) async throws {
    try await store.download(path(value), to: file)
  }
  public func upload(_ file: URL, to value: String) async throws {
    try await store.upload(file, to: path(value))
  }
  public func mkdir(_ value: String) async throws { try await store.mkdir(path(value)) }
  public func move(_ source: String, to destination: String, directory: Bool, replace: Bool)
    async throws
  {
    try await store.move(
      path(source), to: path(destination), directory: directory, replace: replace)
  }
  public func delete(_ value: String, directory: Bool) async throws {
    try await store.delete(path(value), directory: directory)
  }
}
