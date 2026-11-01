import CloudMountVaultCore
import Foundation

/// Native FTP/FTPS using bounded SwiftNIO streams and Apple SecTrust. Explicit
/// FTPS requires AUTH TLS and PROT P; it never falls back to plaintext.
public struct FTPStore: NativeConditionalStore, Sendable {
  private let address: FileServerAddress
  private let settings: FileServerSettings
  private let username: String, password: String
  private var testingAnchor: Data?
  public init(endpoint: URL, settings: FileServerSettings, username: String, password: String) throws {
    guard settings.kind == .ftp || settings.kind == .ftps,
      !username.contains(where: { $0.isNewline || $0 == "\0" }),
      !password.contains(where: { $0.isNewline || $0 == "\0" }) else { throw MobileError.invalidAddress }
    address = try FileServerAddress(endpoint, settings: settings)
    self.settings = settings; self.username = username; self.password = password; self.testingAnchor = nil
  }
  #if DEBUG
  init(endpoint: URL, settings: FileServerSettings, username: String, password: String, testingAnchor: Data) throws {
    try self.init(endpoint: endpoint, settings: settings, username: username, password: password)
    guard ["127.0.0.1","localhost","::1"].contains(address.host) else { throw MobileError.invalidAddress }
    self.testingAnchor = testingAnchor
  }
  #endif
  private func session<T: Sendable>(_ work: @escaping @Sendable (FTPSession) async throws -> T) async throws -> T {
    let cancellation = TransferCancellation()
    let timer = DispatchWorkItem { cancellation.cancel(URLError(.timedOut)) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timer)
    defer { timer.cancel(); cancellation.cancel() }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let ftp = try await FTPSession.connect(address: address, settings: settings, cancellation: cancellation, testingAnchor: testingAnchor)
      try await ftp.login(username: username, password: password)
      return try await work(ftp)
    } onCancel: { cancellation.cancel() }
  }
  public func stat(_ path: String) async throws -> CipherItem {
    let full = try address.path(path)
    return try await session { try await $0.stat(full) }
  }
  public func list(_ path: String) async throws -> [CipherItem] {
    let full = try address.path(path)
    return try await session { try await $0.list(full) }
  }
  public func read(_ path: String, limit: Int) async throws -> Data {
    guard limit >= 0 else { throw MobileError.incomplete }
    let full = try address.path(path)
    return try await session { ftp in
      guard try await ftp.stat(full).size <= limit else { throw MobileError.incomplete }
      return try await ftp.receive("RETR " + full, limit: limit)
    }
  }
  public func download(_ path: String, to file: URL) async throws {
    let full = try address.path(path)
    try await session { ftp in
      let original = try await ftp.stat(full)
      guard !original.isDirectory else { throw MobileError.unsupported }
      FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let handle = try FileHandle(forWritingTo: file)
      do {
        try await ftp.receive("RETR " + full) { try handle.write(contentsOf: $0) }
        try handle.close()
        let current = try await ftp.stat(full)
        guard current.version == original.version,
          (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value == original.size
        else { throw MobileError.conflict }
      } catch { try? handle.close(); try? FileManager.default.removeItem(at: file); throw error }
    }
  }
  public func upload(_ file: URL, to path: String) async throws {
    try await put(file, path: path, expected: nil, requireNew: false)
  }
  public func put(_ file: URL, path: String, expected: String?, requireNew: Bool) async throws {
    let full = try address.path(path)
    guard !path.isEmpty else { throw MobileError.invalidName }
    try await session { ftp in
      let previous = try await ftp.optionalStat(full)
      guard !requireNew || previous == nil, expected == nil || previous?.version == expected,
        previous?.isDirectory != true else { throw MobileError.conflict }
      let temporary = (full as NSString).deletingLastPathComponent + "/.cloudmount-upload-" + UUID().uuidString
      do {
        try await ftp.sendFile(file, command: "STOR " + temporary)
        let current = try await ftp.optionalStat(full)
        guard current?.version == previous?.version else { throw MobileError.conflict }
        try await ftp.rename(temporary, to: full)
      } catch {
        // Only this request's newly generated temporary path may be removed.
        _ = try? await ftp.command("DELE " + temporary)
        throw error
      }
    }
  }
  public func mkdir(_ path: String) async throws {
    let parts = try MobilePath.checked(path).split(separator: "/")
    try await session { ftp in
      for count in 1...max(1, parts.count) where !parts.isEmpty {
        let full = try address.path(parts.prefix(count).joined(separator: "/"))
        if let current = try await ftp.optionalStat(full) {
          guard current.isDirectory else { throw MobileError.conflict }
        } else { _ = try await ftp.command("MKD " + full, expected: [257]) }
      }
    }
  }
  public func move(_ source: String, to destination: String, directory: Bool, replace: Bool) async throws {
    guard !source.isEmpty, !destination.isEmpty else { throw MobileError.invalidName }
    let from = try address.path(source), to = try address.path(destination)
    try await session { ftp in
      if try await ftp.optionalStat(to) != nil, !replace || directory { throw VaultCoreError.exists }
      try await ftp.rename(from, to: to)
    }
  }
  public func delete(_ path: String, directory: Bool) async throws {
    guard !path.isEmpty else { throw MobileError.invalidName }
    let full = try address.path(path)
    try await session { _ = try await $0.command((directory ? "RMD " : "DELE ") + full, expected: [250]) }
  }
}

private final class FTPSession: @unchecked Sendable {
  let address: FileServerAddress, settings: FileServerSettings, cancellation: TransferCancellation
  let control: FTPTransport
  let testingAnchor: Data?
  var buffered = Data()
  private init(address: FileServerAddress, settings: FileServerSettings, cancellation: TransferCancellation, control: FTPTransport, testingAnchor: Data?) {
    self.address = address; self.settings = settings; self.cancellation = cancellation; self.control = control; self.testingAnchor = testingAnchor
  }
  static func connect(address: FileServerAddress, settings: FileServerSettings, cancellation: TransferCancellation, testingAnchor: Data?) async throws -> FTPSession {
    let control = try await FTPTransport.connect(host: address.host, port: address.port, cancellation: cancellation)
    if settings.kind == .ftps && settings.implicitTLS { try await control.startTLS(host: address.host, testingAnchor: testingAnchor) }
    return FTPSession(address: address, settings: settings, cancellation: cancellation, control: control, testingAnchor: testingAnchor)
  }
  func login(username: String, password: String) async throws {
    let greeting = try await reply()
    guard greeting.0 == 220 else { throw MobileError.network(greeting.0) }
    if settings.kind == .ftps && !settings.implicitTLS {
      _ = try await command("AUTH TLS", expected: [234])
      try await control.startTLS(host: address.host, testingAnchor: testingAnchor)
    }
    let user = try await command("USER " + username)
    if user.0 == 331 { _ = try await command("PASS " + password, expected: [230]) }
    else if user.0 != 230 { throw MobileError.credential }
    if settings.kind == .ftps {
      _ = try await command("PBSZ 0", expected: [200])
      _ = try await command("PROT P", expected: [200])
    }
    _ = try await command("TYPE I", expected: [200])
    let utf = try await command("OPTS UTF8 ON")
    guard [200, 202, 500, 501, 502, 504].contains(utf.0) else { throw MobileError.network(utf.0) }
  }
  func command(_ line: String, expected: Set<Int>? = nil) async throws -> (Int, [String]) {
    try Task.checkCancellation()
    guard !line.contains("\r"), !line.contains("\n"), !line.contains("\0") else { throw MobileError.invalidName }
    fileServerTrace("send " + String(line.split(separator: " ").first ?? ""))
    try await write(Data((line + "\r\n").utf8), stream: control)
    let result = try await reply()
    fileServerTrace("reply " + String(result.0))
    if result.0 == 530 { throw MobileError.credential }
    if let expected, !expected.contains(result.0) {
      if result.0 == 550 { throw MobileError.forbidden }
      if result.0 == 552 { throw MobileError.quota }
      throw MobileError.network(result.0)
    }
    return result
  }
  func reply() async throws -> (Int, [String]) {
    var lines = [String]()
    var end: String?
    while lines.count < 1024 {
      while buffered.range(of: Data([13,10])) == nil {
        let (data, eof) = try await read(control)
        guard !eof, !data.isEmpty, buffered.count + data.count <= 262_144 else { throw MobileError.incomplete }
        buffered.append(data)
      }
      let range = buffered.range(of: Data([13,10]))!
      guard let line = String(data: buffered[..<range.lowerBound], encoding: .utf8) else { throw MobileError.incomplete }
      buffered.removeSubrange(..<range.upperBound)
      lines.append(line)
      if lines.count == 1 {
        guard line.utf8.count >= 4, let code = Int(line.prefix(3)) else { throw MobileError.incomplete }
        let separator = line.dropFirst(3).first
        if separator == " " { return (code, lines) }
        guard separator == "-" else { throw MobileError.incomplete }
        end = String(line.prefix(3)) + " "
      } else if let end, line.hasPrefix(end) { return (Int(line.prefix(3))!, lines) }
    }
    throw MobileError.incomplete
  }
  func optionalStat(_ path: String) async throws -> CipherItem? {
    do { return try await stat(path) } catch VaultCoreError.missing { return nil }
  }
  func stat(_ path: String) async throws -> CipherItem {
    let result = try await command("MLST " + path)
    if result.0 == 550 { throw VaultCoreError.missing }
    guard result.0 == 250 else { throw MobileError.unsupported }
    for line in result.1 {
      let candidate = line.hasPrefix(" ") ? String(line.dropFirst()) : line
      if candidate.lowercased().hasPrefix("type=") || candidate.lowercased().contains(";type=") {
        if var item = try Self.entry(candidate, includeDots: true) {
          item.name = (path as NSString).lastPathComponent
          return item
        }
      }
    }
    throw MobileError.incomplete
  }
  func list(_ path: String) async throws -> [CipherItem] {
    let data = try await receive("MLSD " + path, limit: 8 * 1024 * 1024)
    guard let text = String(data: data, encoding: .utf8) else { throw MobileError.incomplete }
    var items = [CipherItem](), names = Set<Data>()
    for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
      if let item = try Self.entry(line) {
        guard items.count < 20_000, names.insert(Data(item.name.utf8)).inserted else { throw MobileError.incomplete }
        items.append(item)
      }
    }
    return items
  }
  static func entry(_ line: String, includeDots: Bool = false) throws -> CipherItem? {
    guard let split = line.firstIndex(of: " ") else { throw MobileError.incomplete }
    let name = String(line[line.index(after: split)...])
    var facts = [String: String]()
    for fact in line[..<split].split(separator: ";") {
      guard let at = fact.firstIndex(of: "=") else { throw MobileError.incomplete }
      let key = fact[..<at].lowercased()
      guard facts[key] == nil else { throw MobileError.incomplete }
      facts[key] = String(fact[fact.index(after: at)...])
    }
    let type = facts["type"]?.lowercased()
    if (type == "cdir" || type == "pdir") && !includeDots { return nil }
    guard type == "file" || type == "dir" || (includeDots && (type == "cdir" || type == "pdir")) else { throw MobileError.unsupported }
    if !includeDots { _ = try MobilePath.name(name) }
    let directory = type != "file"
    guard let stamp = facts["modify"], let size = directory ? Int64(0) : facts["size"].flatMap(Int64.init), size >= 0 else { throw MobileError.incomplete }
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
    guard let modified = formatter.date(from: String(stamp.prefix(14))) else { throw MobileError.incomplete }
    return CipherItem(name: name, size: size, modified: modified, version: stamp + ":" + String(size) + ":" + (facts["unique"] ?? ""), isDirectory: directory)
  }
  func rename(_ from: String, to: String) async throws {
    _ = try await command("RNFR " + from, expected: [350])
    _ = try await command("RNTO " + to, expected: [250])
  }
  func dataConnection() async throws -> FTPTransport {
    let reply = try await command("EPSV")
    let port: Int
    if reply.0 == 229, let first = reply.1.last?.firstIndex(of: "("), let last = reply.1.last?.lastIndex(of: ")"), let text = reply.1.last {
      let body = String(text[text.index(after: first)..<last])
      guard let delimiter = body.first else { throw MobileError.incomplete }
      let parts = body.split(separator: delimiter, omittingEmptySubsequences: false)
      guard parts.count == 5, parts[0].isEmpty, parts[1].isEmpty, parts[2].isEmpty, parts[4].isEmpty, let value = Int(parts[3]) else { throw MobileError.incomplete }
      port = value
    } else if [500,501,502,522].contains(reply.0) {
      let passive = try await command("PASV", expected: [227])
      guard let text = passive.1.last, let first = text.firstIndex(of: "("), let last = text.lastIndex(of: ")") else { throw MobileError.incomplete }
      let numbers = text[text.index(after: first)..<last].split(separator: ",").compactMap { Int($0) }
      guard numbers.count == 6, numbers.allSatisfy({ (0...255).contains($0) }) else { throw MobileError.incomplete }
      port = numbers[4] * 256 + numbers[5]
    } else { throw MobileError.network(reply.0) }
    guard (1...65535).contains(port) else { throw MobileError.incomplete }
    // Ignore the advertised PASV address: bind data transfers to the selected
    // control host, preventing FTP bounce/credential redirection.
    let stream = try await FTPTransport.connect(host: address.host, port: port, cancellation: cancellation)
    if settings.kind == .ftps { try await stream.startTLS(host: address.host, testingAnchor: testingAnchor) }
    return stream
  }
  func receive(_ command: String, limit: Int) async throws -> Data {
    var result = Data()
    try await receive(command) { chunk in
      guard chunk.count <= limit - result.count else { throw MobileError.incomplete }
      result.append(chunk)
    }
    return result
  }
  func receive(_ command: String, consume: (Data) throws -> Void) async throws {
    let stream = try await dataConnection(); defer { stream.cancel() }
    _ = try await self.command(command, expected: [125,150])
    while true {
      let (chunk, eof) = try await read(stream)
      try consume(chunk)
      if eof { break }
    }
    let result = try await reply()
    guard result.0 == 226 || result.0 == 250 else { throw MobileError.network(result.0) }
  }
  func sendFile(_ file: URL, command: String) async throws {
    let stream = try await dataConnection(); defer { stream.cancel() }
    _ = try await self.command(command, expected: [125,150])
    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
    while let data = try handle.read(upToCount: 262_144), !data.isEmpty { try await write(data, stream: stream) }
    fileServerTrace("upload close")
    try await stream.closeWrite()
    fileServerTrace("upload closed")
    let result = try await reply()
    guard result.0 == 226 || result.0 == 250 else { throw MobileError.network(result.0) }
  }
  func read(_ stream: FTPTransport) async throws -> (Data, Bool) { try await stream.read() }
  func write(_ data: Data, stream: FTPTransport) async throws { try await stream.write(data) }
}
