import Foundation

enum MobileDeadline {
  static func run<T: Sendable>(seconds: Double,
    operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(for: .milliseconds(Int64(max(0, seconds) * 1000)))
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
  }
}
