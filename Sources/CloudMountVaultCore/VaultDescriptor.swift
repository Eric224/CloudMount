import Foundation
import CryptoKit
import CryptomatorCryptoLib

public enum VaultCoreError: Error, Sendable {
    case malformed, password, unsupported, missing, exists, conflict, busy, unavailable, unsafePath
}

public struct VaultDescriptor: Codable, Equatable, Sendable {
    public let masterkeyFile: Data
    public let vaultConfig: Data
    public let id: UUID
    public let shorteningThreshold: Int
    public let scheme: CryptorScheme
    public static let configName = "vault.cryptomator"
    public static let keyName = "masterkey.cryptomator"

    public static func create(password: String) throws -> (VaultDescriptor, Data) {
        guard password.count >= 10, password.utf8.count <= 4096 else { throw VaultCoreError.password }
        let key = try Masterkey.createNew(), id = UUID()
        var raw = key.rawKey
        defer { _ = raw.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT", "kid": "masterkeyfile:masterkey.cryptomator"]
        let payload: [String: Any] = ["jti": id.uuidString, "format": 8, "cipherCombo": "SIV_GCM", "shorteningThreshold": 220]
        let a = base64url(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let b = base64url(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signed = a + "." + b
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(signed.utf8), using: SymmetricKey(data: raw)))
        let config = Data((signed + "." + base64url(mac)).utf8)
        let master = try MasterkeyFile.lock(masterkey: key, vaultVersion: 999, passphrase: password.precomposedStringWithCanonicalMapping)
        return (try parse(masterkeyFile: master, vaultConfig: config), Data(raw))
    }
    public static func parse(masterkeyFile: Data, vaultConfig: Data) throws -> VaultDescriptor {
        guard masterkeyFile.count <= 65_536, vaultConfig.count <= 65_536,
              let key = try? JSONSerialization.jsonObject(with: masterkeyFile) as? [String: Any],
              let n = key["scryptCostParam"] as? Int, n >= 2, n <= 262_144, n & (n - 1) == 0,
              let r = key["scryptBlockSize"] as? Int, (1...8).contains(r),
              n <= 268_435_456 / (128 * r) else { throw VaultCoreError.malformed }
        let parts = try tokenParts(vaultConfig)
        guard let header = try JSONSerialization.jsonObject(with: parts.header) as? [String: Any],
              ["HS256", "HS384", "HS512"].contains(header["alg"] as? String ?? ""),
              header["kid"] as? String == "masterkeyfile:masterkey.cryptomator",
              let value = try JSONSerialization.jsonObject(with: parts.payload) as? [String: Any],
              value["format"] as? Int == 8,
              let idText = value["jti"] as? String, let id = UUID(uuidString: idText),
              let threshold = value["shorteningThreshold"] as? Int, (32...255).contains(threshold),
              let combo = value["cipherCombo"] as? String, let scheme = CryptorScheme(rawValue: combo) else { throw VaultCoreError.unsupported }
        return VaultDescriptor(masterkeyFile: masterkeyFile, vaultConfig: vaultConfig, id: id,
                               shorteningThreshold: threshold, scheme: scheme)
    }
    public func unlock(password: String) throws -> Data {
        // Codable input must pass resource bounds before any scrypt work.
        try validateFields()
        guard !password.isEmpty, password.utf8.count <= 4096 else { throw VaultCoreError.password }
        do {
            let key = try MasterkeyFile.withContentFromData(data: masterkeyFile).unlock(passphrase: password.precomposedStringWithCanonicalMapping)
            let raw = Data(key.rawKey)
            try authenticate(rawKey: raw)
            return raw
        } catch { throw VaultCoreError.password }
    }
    public func authenticate(rawKey: Data) throws {
        guard rawKey.count == 64 else { throw VaultCoreError.password }
        try validateFields()
        let parts = try Self.tokenParts(vaultConfig)
        guard let header = try JSONSerialization.jsonObject(with: parts.header) as? [String: Any] else { throw VaultCoreError.malformed }
        let key = SymmetricKey(data: rawKey), valid: Bool
        switch header["alg"] as? String {
        case "HS256": valid = HMAC<SHA256>.isValidAuthenticationCode(parts.signature, authenticating: parts.message, using: key)
        case "HS384": valid = HMAC<SHA384>.isValidAuthenticationCode(parts.signature, authenticating: parts.message, using: key)
        case "HS512": valid = HMAC<SHA512>.isValidAuthenticationCode(parts.signature, authenticating: parts.message, using: key)
        default: valid = false
        }
        guard valid else { throw VaultCoreError.password }
    }
    private func validateFields() throws {
        let validated = try Self.parse(masterkeyFile: masterkeyFile, vaultConfig: vaultConfig)
        guard validated.id == id, validated.shorteningThreshold == shorteningThreshold,
              validated.scheme == scheme else { throw VaultCoreError.malformed }
    }
    public func cryptor(rawKey: Data) throws -> Cryptor {
        try authenticate(rawKey: rawKey)
        return Cryptor(masterkey: try Masterkey.createFromRaw(rawKey: Array(rawKey)), scheme: scheme)
    }
    static func base64url(_ value: Data) -> String {
        value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func unbase64url(_ text: Substring) -> Data? {
        let value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
    private static func tokenParts(_ bytes: Data) throws -> (header: Data, payload: Data, signature: Data, message: Data) {
        guard let text = String(data: bytes, encoding: .utf8) else { throw VaultCoreError.malformed }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let a = unbase64url(parts[0]), let b = unbase64url(parts[1]), let c = unbase64url(parts[2]) else { throw VaultCoreError.malformed }
        return (a, b, c, Data((parts[0] + "." + parts[1]).utf8))
    }
}
