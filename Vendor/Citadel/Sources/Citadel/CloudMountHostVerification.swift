// CloudMount integration: expose a strict OpenSSH SHA-256 host-key pin without
// accepting a server key implicitly. Original NIOSSH/Crypto key code is reused.
import Foundation
import Crypto
import NIO
import NIOSSH

extension SSHHostKeyValidator {
    public static func sha256Pinned(_ expected: String?, mismatch: @escaping @Sendable (String, Bool) -> Error) -> SSHHostKeyValidator {
        .custom(CloudMountPin(expected: expected, mismatch: mismatch))
    }
}
private struct CloudMountPin: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let expected: String?
    let mismatch: @Sendable (String, Bool) -> Error
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        hostKey.write(to: &buffer)
        let hash = "SHA256:" + Data(SHA256.hash(data: Data(buffer.readableBytesView))).base64EncodedString().replacingOccurrences(of: "=", with: "")
        if expected == hash { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(mismatch(hash, expected != nil)) }
    }
}
