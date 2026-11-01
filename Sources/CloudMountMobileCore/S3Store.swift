import CloudMountVaultCore
import CryptoKit
import Foundation

public enum S3Signature {
  static func hex(_ data: some Sequence<UInt8>) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
  public static func encode(_ value: String) -> String {
    value.utf8.map { byte in
      if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        || [45, 46, 95, 126].contains(byte)
      {
        return String(UnicodeScalar(byte))
      }
      return String(format: "%%%02X", byte)
    }.joined()
  }
  static func digest(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hash.update(data: data)
    }
    return hex(hash.finalize())
  }
  static func signed(
    _ request: URLRequest, payload: String, credentials: S3Credentials, region: String,
    date: Date = Date()
  ) throws -> URLRequest {
    guard let url = request.url,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host
    else { throw MobileError.invalidAddress }
    var result = request
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let timestamp = formatter.string(from: date)
    let day = String(timestamp.prefix(8))
    result.setValue(host + (parts.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host")
    result.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
    result.setValue(payload, forHTTPHeaderField: "x-amz-content-sha256")
    if let token = credentials.sessionToken, !token.isEmpty {
      result.setValue(token, forHTTPHeaderField: "x-amz-security-token")
    }
    let headers = (result.allHTTPHeaderFields ?? [:]).map {
      ($0.key.lowercased(), $0.value.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }.sorted { $0.0 < $1.0 }
    let names = headers.map(\.0).joined(separator: ";")
    let canonicalHeaders = headers.map { $0.0 + ":" + $0.1 + "\n" }.joined()
    let encodedQuery: [(String, String)] = (parts.queryItems ?? []).map {
      (encode($0.name), encode($0.value ?? ""))
    }
    let sortedQuery = encodedQuery.sorted { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
    let query = sortedQuery.map { $0.0 + "=" + $0.1 }.joined(separator: "&")
    let canonical = [
      result.httpMethod ?? "GET", parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath,
      query, canonicalHeaders, names, payload,
    ].joined(separator: "\n")
    let scope = day + "/" + region + "/s3/aws4_request"
    let message =
      "AWS4-HMAC-SHA256\n" + timestamp + "\n" + scope + "\n"
      + hex(SHA256.hash(data: Data(canonical.utf8)))
    func mac(_ data: String, _ key: Data) -> Data {
      Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: SymmetricKey(data: key)))
    }
    let key = mac(
      "aws4_request", mac("s3", mac(region, mac(day, Data(("AWS4" + credentials.secretKey).utf8)))))
    let signature = hex(mac(message, key))
    result.setValue(
      "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(names), Signature=\(signature)",
      forHTTPHeaderField: "Authorization")
    return result
  }
}
private final class S3SessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
public final class S3Store: NativeConditionalStore, PagedCiphertextStore, @unchecked Sendable {
  let endpoint: URL, settings: S3Settings, credentials: S3Credentials
  let journal: MobileRepository?
  private let delegate = S3SessionDelegate()
  let session: URLSession
  public init(
    endpoint: URL, settings: S3Settings, credentials: S3Credentials,
    journal: MobileRepository? = nil, allowLoopbackHTTP: Bool = false
  ) throws {
    guard let c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), let host = c.host,
      !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
      c.scheme == "https"
        || (allowLoopbackHTTP && c.scheme == "http" && ["127.0.0.1", "localhost"].contains(host)),
      !settings.bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, settings.bucket.utf8.count <= 1024, !settings.bucket.contains("/"),
      !settings.bucket.contains("\\"), settings.bucket != ".", settings.bucket != "..",
      !settings.bucket.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      }),
      !settings.region.isEmpty, settings.region.utf8.count <= 64,
      settings.region.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
      !credentials.accessKey.isEmpty,
      !credentials.accessKey.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      }), !credentials.secretKey.isEmpty
    else { throw MobileError.invalidAddress }
    _ = try MobilePath.checked(settings.prefix)
    guard settings.prefix.utf8.count <= 1024 else { throw MobileError.invalidAddress }
    if settings.urlStyle == .virtualHosted {
      guard settings.bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil,
        !settings.bucket.contains(".."), !host.contains(":"), !host.hasPrefix("["),
        host.range(of: "^[0-9.]+$", options: .regularExpression) == nil
      else { throw MobileError.invalidAddress }
    }
    self.endpoint = endpoint
    self.settings = settings
    self.credentials = credentials
    self.journal = journal
    let config = URLSessionConfiguration.ephemeral
    config.httpMaximumConnectionsPerHost = 2
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForRequest = 25
    config.timeoutIntervalForResource = 180
    session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }
  private func url(_ key: String, query: [String: String] = [:]) throws -> URL {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    let prefix = endpoint.path.split(separator: "/").map(String.init)
    let buckets = settings.urlStyle == .path ? [settings.bucket] : []
    if settings.urlStyle == .virtualHosted { components.host = settings.bucket + "." + (components.host ?? "") }
    let actual = key.isEmpty ? "" : objectKey(key)
    guard actual.utf8.count <= 1024 else { throw MobileError.invalidName }
    let path = prefix + buckets + actual.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    components.percentEncodedPath = "/" + path.map(S3Signature.encode).joined(separator: "/")
    if key.isEmpty {
      components.percentEncodedPath =
        "/" + (prefix + buckets).map(S3Signature.encode).joined(separator: "/")
    }
    components.percentEncodedQuery =
      query.isEmpty
      ? nil
      : query.sorted { $0.key < $1.key }.map {
        S3Signature.encode($0.key) + "=" + S3Signature.encode($0.value)
      }.joined(separator: "&")
    guard let url = components.url else { throw MobileError.invalidAddress }
    return url
  }
  private var rootPrefix: String { settings.prefix.isEmpty ? "" : settings.prefix + "/" }
  private func objectKey(_ key: String) -> String { rootPrefix + key }
  func copySourceHeader(_ source: String) -> String {
    "/" + ([settings.bucket] + objectKey(source).split(separator: "/", omittingEmptySubsequences: false).map(String.init))
      .map(S3Signature.encode).joined(separator: "/")
  }
  func request(
    _ method: String, _ key: String, query: [String: String] = [:], headers: [String: String] = [:],
    file: URL? = nil
  ) throws -> URLRequest {
    var request = URLRequest(url: try url(key, query: query))
    request.httpMethod = method
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    return try S3Signature.signed(
      request,
      payload: file.map { try S3Signature.digest($0) }
        ?? S3Signature.hex(SHA256.hash(data: Data())), credentials: credentials,
      region: settings.region)
  }
  func check(_ response: URLResponse, codes: Set<Int>) throws -> HTTPURLResponse {
    guard let r = response as? HTTPURLResponse else { throw MobileError.network(0) }
    guard codes.contains(r.statusCode) else {
      switch r.statusCode {
      case 401, 403: throw MobileError.credential
      case 404: throw VaultCoreError.missing
      case 409, 412: throw MobileError.conflict
      case 507: throw MobileError.quota
      default: throw MobileError.network(r.statusCode)
      }
    }
    return r
  }
  func small(_ request: URLRequest, codes: Set<Int> = [200, 204], limit: Int = 8_388_608)
    async throws -> Data
  {
    let (file, response) = try await BoundedHTTP.download(session, request: request, maximum: limit)
    defer { try? FileManager.default.removeItem(at: file) }
    _ = try check(response, codes: codes)
    guard try (file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= limit else {
      throw MobileError.incomplete
    }
    return try Data(contentsOf: file)
  }
  func head(_ key: String) async throws -> CipherItem {
    let (_, response) = try await session.data(for: request("HEAD", key))
    let r = try check(response, codes: [200])
    guard let version = r.value(forHTTPHeaderField:"ETag"), !version.isEmpty else { throw MobileError.incomplete }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return CipherItem(
      name: key.split(separator: "/").last.map(String.init) ?? "", size: r.expectedContentLength,
      modified: formatter.date(from: r.value(forHTTPHeaderField: "Last-Modified") ?? "")
        ?? .distantPast, version: version,
      isDirectory: key.hasSuffix("/"))
  }
  public func stat(_ path: String) async throws -> CipherItem {
    let path = try MobilePath.checked(path)
    if path.isEmpty {
      return CipherItem(
        name: "", size: 0, modified: .distantPast, version: "root", isDirectory: true)
    }
    do { return try await head(path) } catch VaultCoreError.missing {}
    do { return try await head(path + "/") } catch VaultCoreError.missing {}
    if !(try await objects(prefix: path + "/", delimiter: "/", maximum: 1)).isEmpty {
      return CipherItem(
        name: path.split(separator: "/").last.map(String.init) ?? "", size: 0,
        modified: .distantPast, version: "directory:" + path, isDirectory: true)
    }
    throw VaultCoreError.missing
  }
  private struct Object: Codable {
    var key: String
    var size: Int64
    var date: Date
    var etag: String
    var prefix: Bool
  }
  private func objects(prefix: String, delimiter: String?, maximum: Int = 20_000) async throws
    -> [Object]
  {
    var result: [Object] = []
    var token: String?
    var seen = Set<String>()
    for _ in 0..<100 {
      try Task.checkCancellation()
      var query = ["list-type": "2", "prefix": objectKey(prefix), "max-keys": String(min(maximum, 1000))]
      if let delimiter { query["delimiter"] = delimiter }
      if let token { query["continuation-token"] = token }
      let data = try await small(request("GET", "", query: query))
      let parser = S3XML(data: data)
      try parser.parse()
      guard parser.root == "ListBucketResult" else { throw MobileError.incomplete }
      result += parser.entries.map {
        Object(key: String($0.key.dropFirst(rootPrefix.count)), size: $0.size, date: $0.date, etag: $0.etag, prefix: $0.prefix)
      }
      guard parser.entries.allSatisfy({ $0.key.hasPrefix(objectKey(prefix)) }) else { throw MobileError.incomplete }
      if maximum == 1 { return Array(result.prefix(1)) }
      guard result.count <= maximum else { throw MobileError.incomplete }
      if !parser.truncated { return result }
      guard let next = parser.nextToken, !next.isEmpty, seen.insert(next).inserted else {
        throw MobileError.incomplete
      }
      token = next
    }
    throw MobileError.incomplete
  }
  public func list(_ path: String) async throws -> [CipherItem] {
    let path = try MobilePath.checked(path)
    let prefix = path.isEmpty ? "" : path + "/"
    let values = try await objects(prefix: prefix, delimiter: "/")
    var result: [CipherItem] = []
    for value in values where value.key != prefix {
      guard value.key.hasPrefix(prefix) else { throw MobileError.incomplete }
      var name = String(value.key.dropFirst(prefix.count))
      let directory = value.prefix || name.hasSuffix("/")
      if directory && name.hasSuffix("/") { name.removeLast() }
      _ = try MobilePath.name(name)
      result.append(
        CipherItem(
          name: name, size: value.size, modified: value.date,
          version: directory ? "directory:" + value.key : value.etag, isDirectory: directory))
    }
    guard Set(result.map(\.name)).count == result.count else { throw MobileError.conflict }
    return result
  }
  public func listPage(_ path: String, continuation: String?, limit: Int) async throws -> CipherDirectoryPage {
    let path = try MobilePath.checked(path)
    let prefix = path.isEmpty ? "" : path + "/"
    let maximum = max(1, min(limit, 200))
    if let continuation, continuation.isEmpty || continuation.utf8.count > 8192 { throw MobileError.expiredPage }
    var query = ["list-type": "2", "prefix": objectKey(prefix), "delimiter": "/", "max-keys": String(maximum)]
    if let continuation { query["continuation-token"] = continuation }
    let data = try await MobileDeadline.run(seconds: 15) {
      try await self.small(self.request("GET", "", query: query), limit: 2_097_152)
    }
    let parser = S3XML(data: data)
    try parser.parse()
    guard parser.root == "ListBucketResult", parser.entries.count <= maximum,
      parser.entries.allSatisfy({ $0.key.hasPrefix(objectKey(prefix)) }) else { throw MobileError.incomplete }
    var items: [CipherItem] = []
    for value in parser.entries where value.key != objectKey(prefix) {
      var name = String(value.key.dropFirst(objectKey(prefix).count))
      let directory = value.prefix || name.hasSuffix("/")
      if directory && name.hasSuffix("/") { name.removeLast() }
      _ = try MobilePath.name(name)
      guard directory || !value.etag.isEmpty else { throw MobileError.incomplete }
      items.append(CipherItem(name: name, size: value.size, modified: value.date,
        version: directory ? "directory:" + prefix + name : value.etag, isDirectory: directory))
    }
    let next = parser.truncated ? parser.nextToken : nil
    if parser.truncated {
      guard let next, !next.isEmpty, next != continuation, next.utf8.count <= 8192 else { throw MobileError.incomplete }
    }
    guard Set(items.map(\.name)).count == items.count else { throw MobileError.conflict }
    return CipherDirectoryPage(items: items, next: next)
  }
  public func read(_ path: String, limit: Int) async throws -> Data {
    guard try await stat(path).size <= limit else { throw MobileError.incomplete }
    let data = try await small(request("GET", MobilePath.checked(path)), limit: limit)
    guard data.count <= limit else { throw MobileError.incomplete }
    return data
  }
  public func download(_ path: String, to file: URL) async throws {
    let (temporary, response) = try await session.download(
      for: request("GET", MobilePath.checked(path)))
    defer { try? FileManager.default.removeItem(at: temporary) }
    _ = try check(response, codes: [200])
    try Task.checkCancellation()
    guard !FileManager.default.fileExists(atPath: file.path) else { throw MobileError.conflict }
    try FileManager.default.copyItem(at: temporary, to: file)
  }
  public func upload(_ file: URL, to path: String) async throws {
    try await put(file, path: path, expected: nil, requireNew: false)
  }
  public func put(_ file: URL, path: String, expected: String?, requireNew: Bool) async throws {
    let path = try MobilePath.checked(path)
    try await putKey(file, key: path, expected: expected, requireNew: requireNew)
  }
  private func putKey(_ file: URL, key: String, expected: String?, requireNew: Bool) async throws {
    guard try await verifyWriteSupport().supported else { throw MobileError.unsafeWrites }
    guard
      (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 5 * 1024 * 1024
        * 1024
    else { throw MobileError.unsupported }
    var headers = ["Content-Type": "application/octet-stream"]
    if requireNew { headers["If-None-Match"] = "*" }
    if let expected { headers["If-Match"] = expected }
    let request = try request("PUT", key, headers: headers, file: file)
    let (_, response) = try await BoundedHTTP.upload(
      session, request: request, file: file, maximum: 65_536)
    _ = try check(response, codes: [200, 201, 204])
  }
  public func mkdir(_ path: String) async throws {
    let parts = try MobilePath.checked(path).split(separator: "/")
    guard !parts.isEmpty else { return }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "s3-empty-" + UUID().uuidString)
    try Data().write(to: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    for count in 1...parts.count {
      try await putKey(
        temporary, key: parts.prefix(count).joined(separator: "/") + "/", expected: nil,
        requireNew: false)
    }
  }
  private func remove(_ key: String, expected: String? = nil) async throws {
    _ = try await small(
      request("DELETE", key, headers: expected.map { ["If-Match": $0] } ?? [:]), codes: [200, 204])
  }
  public func delete(_ path: String, directory: Bool) async throws {
    guard try await verifyWriteSupport().supported else { throw MobileError.unsafeWrites }
    let path = try MobilePath.checked(path)
    guard !path.isEmpty else { throw MobileError.invalidName }
    if directory {
      guard try await list(path).isEmpty else { throw VaultCoreError.busy }
      do {
        let current = try await head(path + "/")
        try await remove(path + "/", expected: current.version)
      } catch VaultCoreError.missing { return }
    } else {
      let current = try await head(path)
      try await remove(path, expected: current.version)
    }
  }
  private func copy(
    _ source: String, to destination: String, expected: String, destinationVersion: String? = nil
  ) async throws
    -> String
  {
    let copySource = copySourceHeader(source)
    var headers = ["x-amz-copy-source": copySource]
    if let destinationVersion {
      headers["If-Match"] = destinationVersion
    } else {
      headers["If-None-Match"] = "*"
    }
    if !expected.isEmpty { headers["x-amz-copy-source-if-match"] = expected }
    let data = try await small(request("PUT", destination, headers: headers))
    let xml = S3XML(data: data)
    try xml.parse()
    guard xml.root == "CopyObjectResult", let etag = xml.copyETag, !etag.isEmpty else {
      throw MobileError.incomplete
    }
    return etag
  }
  private struct MovePlan: Codable {
    var source: String
    var destination: String
    var objects: [Object]
    var copied: [String: String]
  }
  public func move(_ source: String, to destination: String, directory: Bool, replace: Bool)
    async throws
  {
    guard try await verifyWriteSupport().supported else { throw MobileError.unsafeWrites }
    let source = try MobilePath.checked(source)
    let destination = try MobilePath.checked(destination)
    guard !source.isEmpty, !destination.isEmpty, !destination.hasPrefix(source + "/") else {
      throw MobileError.invalidName
    }
    if !directory {
      let value = try await head(source)
      var destinationVersion: String?
      do {
        let existing = try await head(destination)
        guard replace else { throw MobileError.conflict }
        destinationVersion = existing.version
      } catch VaultCoreError.missing {}
      let version = try await copy(
        source, to: destination, expected: value.version, destinationVersion: destinationVersion)
      guard try await head(destination).version == version else { throw MobileError.conflict }
      try await remove(source, expected: value.version)
      return
    }
    guard !replace, let journal else { throw MobileError.unsupported }
    var identity = endpoint.absoluteString + "/" + settings.bucket + "/" + source + "/" + destination
    if !settings.prefix.isEmpty || settings.urlStyle != .path { identity += "\n" + settings.prefix + "\n" + settings.urlStyle.rawValue }
    let name = "s3-move-" + S3Signature.hex(SHA256.hash(data: Data(identity.utf8))) + ".json"
    let planURL = try journal.file(name)
    var plan: MovePlan
    if FileManager.default.fileExists(atPath: planURL.path) {
      guard let saved = try journal.read(name,default:Optional<MovePlan>.none) else { throw MobileError.incomplete }
      plan = saved
      guard plan.source == source, plan.destination == destination, plan.objects.count <= 20_000,
        plan.objects.allSatisfy({ $0.key.hasPrefix(source+"/") && !$0.prefix && !$0.etag.isEmpty }) else {
        throw MobileError.incomplete
      }
    } else {
      do {
        _ = try await stat(destination)
        throw MobileError.conflict
      } catch VaultCoreError.missing {}
      let values = try await objects(prefix: source + "/", delimiter: nil)
      guard !values.isEmpty, values.allSatisfy({ !$0.prefix && $0.size < 5 * 1024 * 1024 * 1024 })
      else { throw MobileError.unsupported }
      plan = MovePlan(source: source, destination: destination, objects: values, copied: [:])
      try journal.write(plan, name: name)
    }
    for object in plan.objects {
      try Task.checkCancellation()
      let target = destination + object.key.dropFirst(source.count)
      if let version = plan.copied[object.key] {
        guard try await head(target).version == version else { throw MobileError.conflict }
        continue
      }
      let version = try await copy(object.key, to: target, expected: object.etag)
      plan.copied[object.key] = version
      try journal.write(plan, name: name)
    }
    // Keep every source until every destination copy is acknowledged. A
    // failed/interrupted move resumes from its protected per-device plan.
    for object in plan.objects {
      let target = destination + object.key.dropFirst(source.count)
      guard try await head(target).version == plan.copied[object.key] else {
        throw MobileError.conflict
      }
    }
    for object in plan.objects {
      try Task.checkCancellation()
      do {
        let current = try await head(object.key)
        guard current.version == object.etag else { throw MobileError.conflict }
        try await remove(object.key, expected: current.version)
      } catch VaultCoreError.missing { continue }
    }
    guard try await objects(prefix: source + "/", delimiter: nil).isEmpty else {
      throw MobileError.conflict
    }
    try FileManager.default.removeItem(at: planURL)
  }
}
private final class S3XML: NSObject, XMLParserDelegate {
  struct Entry { var key = "", size: Int64 = 0, date = Date.distantPast, etag = "", prefix = false }
  let data: Data
  var root = "", stack: [String] = [], text = "", entries: [Entry] = [], current: Entry?,
    truncated = false, nextToken: String?, copyETag: String?, valid = true
  init(data: Data) { self.data = data }
  func parse() throws {
    let p = XMLParser(data: data)
    p.shouldProcessNamespaces = true
    p.shouldResolveExternalEntities = false
    p.delegate = self
    guard p.parse(), valid, !root.isEmpty, root != "Error" else { throw MobileError.incomplete }
  }
  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    if stack.isEmpty { root = name }
    stack.append(name)
    text = ""
    if name == "Contents" || name == "CommonPrefixes" {
      current = Entry()
      current?.prefix = name == "CommonPrefixes"
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch name {
    case "Key": current?.key = text
    case "Prefix": if current?.prefix == true { current?.key = text }
    case "Size": if let n = Int64(value), n >= 0 { current?.size = n } else { valid = false }
    case "ETag":
      if current != nil {
        current?.etag = value
      } else if root == "CopyObjectResult" {
        copyETag = value
      }
    case "LastModified":
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      current?.date =
        f.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? .distantPast
    case "IsTruncated":
      if value == "true" { truncated = true } else if value != "false" { valid = false }
    case "NextContinuationToken": nextToken = value
    case "Contents", "CommonPrefixes":
      if let current, !current.key.isEmpty { entries.append(current) } else { valid = false }
      current = nil
    default: break
    }
    _ = stack.popLast()
    text = ""
  }
}
