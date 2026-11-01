import Foundation

/// Bounds metadata responses while they arrive, rather than after an
/// arbitrarily large download has consumed disk or an upload response RAM.
enum BoundedHTTP {
  static func download(_ session: URLSession, request: URLRequest, maximum: Int) async throws -> (
    URL, URLResponse
  ) {
    let cancellation = TransferCancellation()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let delegate = DownloadLimit(maximum: maximum, continuation: continuation)
        let task = session.downloadTask(with: request)
        task.delegate = delegate
        cancellation.add { [delegate] in withExtendedLifetime(delegate) { task.cancel() } }
        task.resume()
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  static func upload(
    _ session: URLSession, request: URLRequest, file: URL, maximum: Int = 8_388_608
  ) async throws -> (Data, URLResponse) {
    let cancellation = TransferCancellation()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let delegate = UploadLimit(maximum: maximum, continuation: continuation)
        let task = session.uploadTask(with: request, fromFile: file)
        task.delegate = delegate
        // Retain the per-task delegate explicitly until this operation ends.
        cancellation.add { [delegate] in withExtendedLifetime(delegate) { task.cancel() } }
        task.resume()
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
}

private final class DownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  let maximum: Int
  private var overflow = false
  private var file: URL?
  private var failure: Error?
  private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
  init(maximum: Int, continuation: CheckedContinuation<(URL, URLResponse), Error>) {
    self.maximum = maximum
    self.continuation = continuation
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum {
      overflow = true
      downloadTask.cancel()
    }
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      guard !overflow,
        try (location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= maximum
      else { throw MobileError.incomplete }
      // Foundation removes its temporary file after this callback returns.
      let target = FileManager.default.temporaryDirectory.appendingPathComponent(
        "cloudmount-metadata-" + UUID().uuidString)
      try FileManager.default.moveItem(at: location, to: target)
      file = target
    } catch { failure = error }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let result = continuation else { return }
    continuation = nil
    if !overflow, failure == nil, error == nil, let file, let response = task.response {
      result.resume(returning: (file, response))
      self.file = nil
    } else {
      if let file { try? FileManager.default.removeItem(at: file) }
      result.resume(
        throwing: overflow ? MobileError.incomplete : (failure ?? error ?? MobileError.incomplete))
    }
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

private final class UploadLimit: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let maximum: Int
  private var bytes = Data()
  private var overflow = false
  private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
  init(maximum: Int, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
    self.maximum = maximum
    self.continuation = continuation
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if response.expectedContentLength > maximum {
      overflow = true
      completionHandler(.cancel)
    } else {
      completionHandler(.allow)
    }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard data.count <= maximum - bytes.count else {
      overflow = true
      dataTask.cancel()
      return
    }
    bytes.append(data)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let result = continuation else { return }
    continuation = nil
    if overflow {
      result.resume(throwing: MobileError.incomplete)
    } else if let error {
      result.resume(throwing: error)
    } else if let response = task.response {
      result.resume(returning: (bytes, response))
    } else {
      result.resume(throwing: MobileError.incomplete)
    }
    bytes.removeAll(keepingCapacity: false)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
