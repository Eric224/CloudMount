import CloudMountVaultCore
import Foundation

/// Completed tasks are removed immediately, rather than retained until the OS
/// eventually destroys a File Provider enumerator. No synchronous waits.
public final class MobileTaskRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var invalidated = false
  private let maximum: Int
  public init(maximum: Int = 8) { self.maximum = max(1, maximum) }
  public var activeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return tasks.count
  }
  public func start(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    guard !invalidated, tasks.count < maximum else { return nil }
    let id = UUID()
    // Insert while holding the lock: an immediately completed task cannot
    // race its insertion and leave a finished task permanently registered.
    let task = Task {
      defer { self.finished(id) }
      await work()
    }
    tasks[id] = task
    return task
  }
  private func finished(_ id: UUID) {
    lock.lock()
    tasks.removeValue(forKey: id)
    lock.unlock()
  }
  public func invalidate() {
    lock.lock()
    invalidated = true
    let active = Array(tasks.values)
    tasks.removeAll()
    lock.unlock()
    active.forEach { $0.cancel() }
  }
}

/// File locks impose one shared budget across the app and both extensions.
/// The OS releases slots automatically when a process exits or is killed.
actor MobileResourceGate {
  static let shared = MobileResourceGate()
  private var waiting = 0
  func acquire(_ repository: MobileRepository, crypto: Bool = false, timeout: TimeInterval = 15)
    async throws -> MobileLease
  {
    guard waiting < (crypto ? 4 : 16) else { throw MobileError.busy }
    waiting += 1
    defer { waiting -= 1 }
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(max(0, timeout) * 1000)))
    while true {
      try Task.checkCancellation()
      for slot in 0..<(crypto ? 1 : 2) {
        do {
          return try await repository.lease(
            "resource-\(crypto ? "crypto" : "cloud")-\(slot)", timeout: 0)
        } catch MobileError.busy { continue }
      }
      guard ContinuousClock.now < deadline else { throw MobileError.busy }
      try await Task.sleep(for: .milliseconds(75))
    }
  }
}

/// Construct transports only after acquiring a slot, so a burst of requests
/// cannot allocate an unbounded number of URLSession/SSH connections.
struct BudgetedStore: NativeConditionalStore, PagedCiphertextStore, Sendable {
  let repository: MobileRepository
  let factory: @Sendable () throws -> any CiphertextStore
  private func run<T: Sendable>(_ work: (any CiphertextStore) async throws -> T) async throws -> T {
    let slot = try await MobileResourceGate.shared.acquire(repository)
    defer { withExtendedLifetime(slot) {} }
    try Task.checkCancellation()
    return try await work(factory())
  }
  func stat(_ path: String) async throws -> CipherItem { try await run { try await $0.stat(path) } }
  func list(_ path: String) async throws -> [CipherItem] {
    try await run { try await $0.list(path) }
  }
  func listPage(_ path: String, continuation: String?, limit: Int) async throws -> CipherDirectoryPage {
    try await run {
      guard let paged = $0 as? any PagedCiphertextStore else { throw MobileError.unsupported }
      return try await paged.listPage(path, continuation: continuation, limit: limit)
    }
  }
  func read(_ path: String, limit: Int) async throws -> Data {
    try await run { try await $0.read(path, limit: limit) }
  }
  func download(_ path: String, to file: URL) async throws {
    try await run { try await $0.download(path, to: file) }
  }
  func upload(_ file: URL, to path: String) async throws {
    try await run { try await $0.upload(file, to: path) }
  }
  func put(_ file: URL, path: String, expected: String?, requireNew: Bool) async throws {
    try await run {
      guard let native = $0 as? any NativeConditionalStore else { throw MobileError.unsupported }
      try await native.put(file, path: path, expected: expected, requireNew: requireNew)
    }
  }
  func mkdir(_ path: String) async throws { try await run { try await $0.mkdir(path) } }
  func move(_ source: String, to destination: String, directory: Bool, replace: Bool) async throws {
    try await run {
      try await $0.move(source, to: destination, directory: directory, replace: replace)
    }
  }
  func delete(_ path: String, directory: Bool) async throws {
    try await run { try await $0.delete(path, directory: directory) }
  }
}
