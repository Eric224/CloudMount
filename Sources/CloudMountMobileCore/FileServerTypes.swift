import Foundation
import CloudMountVaultCore

public enum FileServerKind: String, Codable, Sendable, CaseIterable {
  case ftp, ftps, sftp
}
public struct FileServerSettings: Codable, Sendable {
  public var kind: FileServerKind
  public var implicitTLS: Bool
  public var hostKeyFingerprint: String?
  public init(kind: FileServerKind, implicitTLS: Bool = false, hostKeyFingerprint: String? = nil) {
    self.kind = kind; self.implicitTLS = implicitTLS; self.hostKeyFingerprint = hostKeyFingerprint
  }
}
public struct SSHHostVerification: Error, LocalizedError, Sendable {
  public let host: String
  public let fingerprint: String
  public let changed: Bool
  public var errorDescription: String? {
    changed ? MobileText.text("伺服器身分已改變，已停止連線。請先向管理員確認。", "服务器身份已改变，已停止连接。请先向管理员确认。", "The server identity changed. Connection stopped; verify with your administrator.") : MobileText.text("第一次連接此 SFTP 伺服器，請確認伺服器指紋。", "首次连接此 SFTP 服务器，请确认服务器指纹。", "First connection to this SFTP server. Verify its fingerprint.")
  }
}
struct FileServerAddress: Sendable {
  let host: String, port: Int, root: String
  init(_ endpoint: URL, settings: FileServerSettings) throws {
    guard endpoint.scheme == settings.kind.rawValue, let host = endpoint.host, !host.isEmpty,
      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
    else { throw MobileError.invalidAddress }
    let port = endpoint.port ?? (settings.kind == .sftp ? 22 : settings.implicitTLS ? 990 : 21)
    guard (1...65535).contains(port) else { throw MobileError.invalidAddress }
    let root = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    _ = try MobilePath.checked(root)
    self.host = host; self.port = port; self.root = root.isEmpty ? "/" : "/" + root
  }
  func path(_ relative: String) throws -> String {
    _ = try MobilePath.checked(relative)
    return relative.isEmpty ? root : (root == "/" ? "/" : root + "/") + relative
  }
}
// A control/data connection is cancelled as one unit. The timer is owned by the
// request and never survives its completion. URLSession also bounds each read.
final class TransferCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var actions: [UUID: @Sendable (Error) -> Void] = [:]
  private var failure: Error?
  @discardableResult func add(_ action: @escaping @Sendable () -> Void) -> UUID { register { _ in action() } }
  func register(_ action: @escaping @Sendable (Error) -> Void) -> UUID {
    let id = UUID()
    lock.lock(); if let failure { lock.unlock(); action(failure); return id }
    actions[id] = action; lock.unlock(); return id
  }
  func remove(_ id: UUID) { lock.lock(); actions.removeValue(forKey: id); lock.unlock() }
  func cancel(_ error: Error = CancellationError()) {
    lock.lock(); if failure == nil { failure = error }; let current = actions; actions = [:]; lock.unlock()
    for action in current.values { action(error) }
  }
}
private final class TransferReply<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?
  init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
  func finish(_ result: Result<T, Error>) {
    lock.lock(); let value = continuation; continuation = nil; lock.unlock()
    value?.resume(with: result)
  }
}
/// URLSessionStreamTask can omit its read/write callback after a TLS error.
/// Resolve locally on cancellation/deadline, even when Foundation never calls it.
func transferReply<T>(_ cancellation: TransferCancellation, timeout: TimeInterval = 25,
  start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    let reply = TransferReply<T>(continuation)
    let id = cancellation.register { reply.finish(.failure($0)) }
    let timer = DispatchWorkItem { cancellation.cancel(URLError(.timedOut)) }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
    start { result in
      timer.cancel(); cancellation.remove(id); reply.finish(result)
    }
  }
}

func fileServerTrace(_ text: String) {
  #if DEBUG
  if ProcessInfo.processInfo.environment["CLOUDMOUNT_TRACE_FILE_SERVERS"] == "1" { FileHandle.standardError.write(Data(("FTP fixture: " + text + "\n").utf8)) }
  #endif
}
