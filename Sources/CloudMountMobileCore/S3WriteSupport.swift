import CloudMountVaultCore
import CryptoKit
import Foundation

public struct S3WriteSupport: Codable, Sendable {
  public var supported: Bool
  public var checkedAt: Date
  public var retainedProbeKey: String?
}

extension S3Store {
  private static func probeName(endpoint: URL, settings: S3Settings, credentials: S3Credentials)
    -> String
  {
    var fields = [
      "s3-write-policy-2", endpoint.absoluteString, settings.bucket, settings.region,
      credentials.accessKey, credentials.secretKey, credentials.sessionToken ?? "",
    ]
    if !settings.prefix.isEmpty || settings.urlStyle != .path { fields += [settings.prefix, settings.urlStyle.rawValue] }
    let context = fields.joined(separator: "\n")
    return "s3-write-"
      + Data(SHA256.hash(data: Data(context.utf8))).map { String(format: "%02x", $0) }.joined()
      + ".json"
  }
  public static func cachedWriteSupport(
    repository: MobileRepository, endpoint: URL, settings: S3Settings, credentials: S3Credentials
  ) throws -> S3WriteSupport? {
    try repository.read(
      probeName(endpoint: endpoint, settings: settings, credentials: credentials),
      default: Optional<S3WriteSupport>.none)
  }
  /// Tests only generated private probe keys. Wrong conditions must be rejected;
  /// a label saying "S3 compatible" is not proof of compare-and-swap support.
  public func verifyWriteSupport(force: Bool = false) async throws -> S3WriteSupport {
    let repo: MobileRepository
    if let journal {
      repo = journal
    } else {
      repo = try MobileRepository(
        root: FileManager.default.temporaryDirectory.appendingPathComponent(
          "cloudmount-s3-write-checks"))
    }
    let name = Self.probeName(endpoint: endpoint, settings: settings, credentials: credentials)
    let lease = try await repo.lease(String(name.dropLast(5)), timeout: 35)
    defer { withExtendedLifetime(lease) {} }
    let previous = try repo.read(name, default: Optional<S3WriteSupport>.none)
    if !force, let previous {
      let age = Date().timeIntervalSince(previous.checkedAt)
      if age >= 0, age < (previous.supported ? 86_400 : 3_600) { return previous }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    func bounded(_ request: URLRequest) throws -> URLRequest {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
      var r = request
      r.timeoutInterval = 8
      return r
    }
    func removeProbe(_ key: String) async throws {
      // A persisted probe key is untrusted local data: deletion must never be
      // redirected into an arbitrary user object by a modified JSON file.
      let prefix = ".cloudmount-write-check-"
      guard key.hasPrefix(prefix), UUID(uuidString: String(key.dropFirst(prefix.count))) != nil
      else { throw MobileError.incomplete }
      let r = try bounded(request("DELETE", key))
      _ = try await small(r, codes: [200, 204, 404])
    }
    if let old = previous?.retainedProbeKey {
      do { try await removeProbe(old) } catch is CancellationError {
        throw CancellationError()
      } catch let value as URLError where value.code == .cancelled { throw value } catch {
        return previous!
      }  // Do not accumulate more probes if cleanup is forbidden.
    }
    var key = ""
    for _ in 0..<4 {
      let candidate = ".cloudmount-write-check-" + UUID().uuidString
      let r = try bounded(request("HEAD", candidate))
      let (_, response) = try await session.data(for: r)
      if (response as? HTTPURLResponse)?.statusCode == 404 {
        key = candidate
        break
      }
      _ = try check(response, codes: [200])
    }
    guard !key.isEmpty else { throw MobileError.busy }
    var stamp = S3WriteSupport(supported: false, checkedAt: Date(), retainedProbeKey: key)
    // Journal ownership before the first request. Process termination leaves
    // a recoverable cleanup record instead of creating unlimited orphan files.
    try repo.write(stamp, name: name)
    let a = try repo.file("s3-probe-" + UUID().uuidString)
    let b = try repo.file("s3-probe-" + UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: a)
      try? FileManager.default.removeItem(at: b)
    }
    try Data("A".utf8).write(to: a)
    try repo.protect(a)
    try Data("B".utf8).write(to: b)
    try repo.protect(b)
    func put(_ file: URL, _ headers: [String: String]) async throws -> Int {
      let r = try bounded(request("PUT", key, headers: headers, file: file))
      let (_, response) = try await BoundedHTTP.upload(
        session, request: r, file: file, maximum: 65_536)
      guard let http = response as? HTTPURLResponse else { throw MobileError.incomplete }
      if http.statusCode == 401 { throw MobileError.credential }
      if [429, 500, 502, 503, 504].contains(http.statusCode) {
        throw MobileError.network(http.statusCode)
      }
      return http.statusCode
    }
    do {
      let created = try await put(a, ["If-None-Match": "*"])
      if [200, 201, 204].contains(created) {
        let (_, metadata) = try await session.data(for: bounded(request("HEAD", key)))
        _ = try check(metadata, codes: [200])
        let version = (metadata as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") ?? ""
        if !version.isEmpty,
          try await put(b, ["If-Match": "\"cloudmount-wrong-" + UUID().uuidString + "\""]) == 412,
          try await put(b, ["If-None-Match": "*"]) == 412,
          [200, 201, 204].contains(try await put(b, ["If-Match": version])),
          try await put(a, ["If-Match": version]) == 412
        {
          let data = try await small(bounded(request("GET", key)), limit: 16)
          if data == Data("B".utf8) {
            let (_, current) = try await session.data(for: bounded(request("HEAD", key)))
            let tag = (current as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") ?? ""
            let empty = try repo.file("empty-s3-probe-" + UUID().uuidString)
            try Data().write(to: empty)
            try repo.protect(empty)
            defer { try? FileManager.default.removeItem(at: empty) }
            func copy(_ headers: [String: String]) async throws -> Int {
              var h = headers
              h["x-amz-copy-source"] = copySourceHeader(key)
              h["x-amz-metadata-directive"] = "REPLACE"
              let r = try bounded(request("PUT", key, headers: h))
              let (_, response) = try await BoundedHTTP.upload(
                session, request: r, file: empty, maximum: 65_536)
              return (response as? HTTPURLResponse)?.statusCode ?? 0
            }
            let wrong = "\"cloudmount-wrong-" + UUID().uuidString + "\""
            if !tag.isEmpty,
              try await copy(["If-Match": wrong, "x-amz-copy-source-if-match": tag]) == 412,
              try await copy(["If-None-Match": "*", "x-amz-copy-source-if-match": tag]) == 412,
              try await copy(["If-Match": tag, "x-amz-copy-source-if-match": wrong]) == 412,
              [200, 201, 204].contains(
                try await copy(["If-Match": tag, "x-amz-copy-source-if-match": tag]))
            {
              let r = try bounded(request("DELETE", key, headers: ["If-Match": wrong]))
              let (_, response) = try await session.data(for: r)
              stamp.supported = (response as? HTTPURLResponse)?.statusCode == 412
              if stamp.supported {
                stamp.supported =
                  try await small(bounded(request("GET", key)), limit: 16) == Data("B".utf8)
                if stamp.supported {
                  let (_, current) = try await session.data(for: bounded(request("HEAD", key)))
                  let currentTag =
                    (current as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") ?? ""
                  let (_, deleted) = try await session.data(
                    for: bounded(request("DELETE", key, headers: ["If-Match": currentTag])))
                  let (_, absent) = try await session.data(for: bounded(request("HEAD", key)))
                  stamp.supported =
                    !currentTag.isEmpty
                    && [200, 204].contains((deleted as? HTTPURLResponse)?.statusCode ?? 0)
                    && (absent as? HTTPURLResponse)?.statusCode == 404
                }
              }
            }
          }
        }
      }
      do {
        try await removeProbe(key)
        stamp.retainedProbeKey = nil
      } catch { stamp.supported = false }
      stamp.checkedAt = Date()
      try repo.write(stamp, name: name)
      return stamp
    } catch {
      // Preserve the ownership record on cancellation/network failure. A
      // later explicit retry cleans it before issuing any new probe.
      throw error
    }
  }
}
