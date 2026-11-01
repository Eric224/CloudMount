import Foundation
import NIO
import NIOSSL
import NIOTLS
import Security

/// Backpressured byte stream. Both plain and TLS traffic have a single owner;
/// no run-loop polling and no per-connection threads are created.
final class FTPTransport: @unchecked Sendable {
  private let channel: Channel
  private let pipe: FTPBytePipe
  private let cancellation: TransferCancellation
  private init(channel: Channel, pipe: FTPBytePipe, cancellation: TransferCancellation) {
    self.channel = channel; self.pipe = pipe; self.cancellation = cancellation
  }
  static func connect(host: String, port: Int, cancellation: TransferCancellation) async throws -> FTPTransport {
    let pipe = FTPBytePipe(port: port, cancellation: cancellation)
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connectTimeout(.seconds(20)).channelOption(ChannelOptions.autoRead, value: false)
      .channelInitializer { $0.pipeline.addHandler(pipe) }
      .connect(host: host, port: port).get()
    cancellation.add {
      channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in channel.close(promise: nil) }
    }
    return FTPTransport(channel: channel, pipe: pipe, cancellation: cancellation)
  }
  func startTLS(host: String, testingAnchor: Data? = nil) async throws {
    var configuration = TLSConfiguration.makeClientConfiguration()
    configuration.minimumTLSVersion = .tlsv12
    configuration.certificateVerification = .fullVerification
    // Full chain, hostname, validity and system-root checks are delegated to
    // SecTrust below, so no separately shipped CA bundle becomes stale.
    configuration.trustRoots = .certificates([])
    let context = try NIOSSLContext(configuration: configuration)
    let cancellation = self.cancellation
    let channel = self.channel
    let ip = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    try await channel.eventLoop.submit {
    let handler = try NIOSSLClientHandler(context: context, serverHostname: ip ? nil : host) { certificates, promise in
      DispatchQueue.global(qos: .utility).async {
        do {
          let chain = try certificates.map { cert -> SecCertificate in
            guard let value = SecCertificateCreateWithData(nil, Data(try cert.toDERBytes()) as CFData) else { throw URLError(.serverCertificateUntrusted) }
            return value
          }
          guard !chain.isEmpty else { throw URLError(.serverCertificateUntrusted) }
          var trust: SecTrust?
          let policy = SecPolicyCreateSSL(true, host as CFString)
          guard SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess, let trust else { throw URLError(.serverCertificateUntrusted) }
          #if DEBUG
          // Only @testable code supplies an anchor, only on loopback. Release
          // connections always use the device's system trust and hostname policy.
          if let testingAnchor, ["127.0.0.1","localhost","::1"].contains(host) {
            guard let anchor = SecCertificateCreateWithData(nil, testingAnchor as CFData),
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { throw URLError(.serverCertificateUntrusted) }
          }
          #endif
          guard SecTrustEvaluateWithError(trust, nil) else { throw URLError(.serverCertificateUntrusted) }
          fileServerTrace("certificate verified")
          promise.succeed(.certificateVerified)
        } catch { cancellation.cancel(error); promise.fail(error) }
      }
    }
    try channel.pipeline.syncOperations.addHandler(handler, position: .first)
    }.get()
    // A queued FTP command can wait for the TLS handshake to flush. Read the
    // handshake proactively; restore backpressure when TLS is established.
    try await channel.setOption(ChannelOptions.autoRead, value: true).get()
  }
  func read() async throws -> (Data, Bool) {
    try Task.checkCancellation()
    return try await transferReply(cancellation) { completion in
      channel.eventLoop.execute { self.pipe.read(on: self.channel).whenComplete(completion) }
    }
  }
  func write(_ data: Data) async throws {
    try Task.checkCancellation()
    let _: Void = try await transferReply(cancellation) { completion in
      self.channel.writeAndFlush(ByteBuffer(bytes: data)).whenComplete(completion)
    }
  }
  func closeWrite() async throws {
    try await channel.setOption(ChannelOptions.autoRead, value: true).get()
    let _: Void = try await transferReply(cancellation) { completion in
      self.channel.close(mode: .all).whenComplete(completion)
    }
  }
  func cancel() {
    channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in self.channel.close(promise: nil) }
  }
}
private final class FTPBytePipe: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  let port: Int
  let cancellation: TransferCancellation
  init(port: Int, cancellation: TransferCancellation) { self.port = port; self.cancellation = cancellation }
  private var chunks: [Data] = []
  private var bytes = 0
  private var waiter: EventLoopPromise<(Data,Bool)>?
  private var ended = false
  private var failure: Error?
  func read(on channel: Channel) -> EventLoopFuture<(Data,Bool)> {
    channel.eventLoop.preconditionInEventLoop()
    fileServerTrace("read port \(port) buffered \(chunks.count) ended \(ended)")
    if !chunks.isEmpty { let value = chunks.removeFirst(); bytes -= value.count; return channel.eventLoop.makeSucceededFuture((value,false)) }
    if let failure { return channel.eventLoop.makeFailedFuture(failure) }
    if ended { return channel.eventLoop.makeSucceededFuture((Data(),true)) }
    guard waiter == nil else { return channel.eventLoop.makeFailedFuture(MobileError.busy) }
    let promise = channel.eventLoop.makePromise(of: (Data,Bool).self); waiter = promise; channel.read(); return promise.futureResult
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let value = Data(unwrapInboundIn(data).readableBytesView)
    fileServerTrace("bytes port \(port): \(value.count)")
    guard !value.isEmpty else { context.read(); return }
    if let promise = waiter { waiter = nil; promise.succeed((value,false)) }
    else {
      guard bytes + value.count <= 1_048_576 else { errorCaught(context: context, error: MobileError.incomplete); return }
      chunks.append(value); bytes += value.count
    }
  }
  func channelReadComplete(context: ChannelHandlerContext) {
    // TLS may consume a TCP read entirely for handshake/session-ticket
    // records. Keep reading while the caller still awaits application bytes.
    if waiter != nil { context.read() }
    context.fireChannelReadComplete()
  }
  func channelInactive(context: ChannelHandlerContext) {
    fileServerTrace("inactive port \(port)")
    ended = true; let promise = waiter; waiter = nil
    if let failure { promise?.fail(failure) } else { promise?.succeed((Data(),true)) }
    context.fireChannelInactive()
  }
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls {
      fileServerTrace("TLS handshake complete")
      context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure {
        self.errorCaught(context: context, error: $0)
      }
      // A data read may already be waiting while the TLS handshake consumed
      // its socket-read demand. Re-issue demand after restoring backpressure.
      if waiter != nil { context.read() }
    }
    fileServerTrace("event port \(port): \(event)")
    context.fireUserInboundEventTriggered(event)
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    #if DEBUG
    if ProcessInfo.processInfo.environment["CLOUDMOUNT_TRACE_FILE_SERVERS"] == "1" {
      FileHandle.standardError.write(Data(("CloudMount test TLS/stream error: \(error)\n").utf8))
    }
    #endif
    failure = error; cancellation.cancel(error); let promise = waiter; waiter = nil; promise?.fail(error); context.close(promise:nil)
  }
}
