import CloudMountMobileCore
import FileProvider
import Foundation

/// A timeout stops this UI action, never the upload or an OS file operation.
/// Registration removal is attempted only after the barrier actually succeeds.
enum SystemSyncBarrier {
  static func wait(_ manager: NSFileProviderManager) async throws {
    try await wait(timeout: 15) { completion in
      manager.waitForChanges(below: .rootContainer, completionHandler: completion)
    }
  }
  static func wait(timeout: TimeInterval, start: (@escaping (Error?) -> Void) -> Void) async throws
  {
    try await withCheckedThrowingContinuation { continuation in
      let reply = BarrierReply(continuation)
      let timer = DispatchWorkItem { reply.finish(MobileError.busy) }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
      start { error in
        timer.cancel()
        reply.finish(error)
      }
    }
  }
}
private final class BarrierReply: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
  func finish(_ error: Error?) {
    lock.lock()
    let value = continuation
    continuation = nil
    lock.unlock()
    if let error { value?.resume(throwing: error) } else { value?.resume() }
  }
}
