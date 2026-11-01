import Foundation
import CryptoKit
import CommonCrypto
import Security
import CloudMountVaultCore

enum VaultFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return L10n.string(value) }; return nil }
    static let invalid = Self.message("保險箱資料損壞或格式不支援，未修改任何遠端檔案。")
    static let password = Self.message("密碼不正確，或保險箱描述檔已損壞。")
}

struct VaultSecrets: Codable, Equatable {
    let id: UUID
    let password: String
    let salt: String
    let recoveryCode: String
    var cryptomatorKey: Data? { Data(base64Encoded: password).flatMap { $0.count == 64 ? $0 : nil } }
    static func standard(id: UUID, raw: Data) throws -> Self {
        guard raw.count == 64 else { throw VaultFailure.password }
        let lease = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data(id.uuidString.utf8), info: Data("CloudMountWriter-v8".utf8), outputByteCount: 32)
        return Self(id: id, password: raw.base64EncodedString(), salt: lease.withUnsafeBytes { Data($0).base64EncodedString() }, recoveryCode: try RecoveryWords.encode(raw))
    }
}

/// Public display metadata and legacy test-vault reader. New content uses the
/// complete standard Cryptomator v8 files; this metadata is optional for recovery.
struct VaultEnvelope: Codable, Equatable {
    let format: String
    let version: Int
    let id: UUID
    let name: String
    let kdf: String
    let iterations: Int
    let salt: Data
    let wrappedKeys: Data
    let recoveryKeys: Data
    var descriptor: VaultDescriptor? = nil

    static let filename = "cloudmount-vault.json"
    static let container = ".cloudmount-vaults"
    private static let rounds = 600_000
    private var authentication: Data {
        Data("CloudMountVault|1|\(id.uuidString)|\(name)|PBKDF2-SHA256|\(iterations)|\(salt.base64EncodedString())".utf8)
    }
    func validate() throws {
        if let descriptor {
            let checked = try VaultDescriptor.parse(masterkeyFile: descriptor.masterkeyFile, vaultConfig: descriptor.vaultConfig)
            guard format == "Cryptomator", version == 8, checked == descriptor, id == descriptor.id,
                  !name.isEmpty, name.utf8.count <= 256 else { throw VaultFailure.invalid }
            return
        }
        guard format == "CloudMountVault", version == 1, kdf == "PBKDF2-SHA256",
              iterations == Self.rounds, salt.count == 32, (28...8192).contains(wrappedKeys.count),
              (28...8192).contains(recoveryKeys.count), !name.isEmpty, name.utf8.count <= 256 else { throw VaultFailure.invalid }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_768 else { throw VaultFailure.invalid }
        do { let result = try JSONDecoder().decode(Self.self, from: data); try result.validate(); return result }
        catch { throw VaultFailure.invalid }
    }
    static func create(name: String, password: String) throws -> (Self, VaultSecrets) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256, !name.contains("\n") else { throw VaultFailure.message("請輸入保險箱名稱（最多 256 位元組）。") }
        guard password.count >= 10, password.utf8.count <= 4096 else { throw VaultFailure.message("請使用至少 10 個字元的保險箱密碼。") }
        let (descriptor, raw) = try VaultDescriptor.create(password: password)
        return (standard(descriptor, name: name), try VaultSecrets.standard(id: descriptor.id, raw: raw))
    }
    static func standard(_ descriptor: VaultDescriptor, name: String) -> Self {
        Self(format: "Cryptomator", version: 8, id: descriptor.id, name: name, kdf: "scrypt", iterations: 0,
             salt: Data(), wrappedKeys: Data(), recoveryKeys: Data(), descriptor: descriptor)
    }
    static func createLegacyFixture(name: String, password: String) throws -> (Self, VaultSecrets) {
        guard password.count >= 10, password.utf8.count <= 4096 else {
            throw VaultFailure.message("請使用至少 10 個字元的保險箱密碼。")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256, !name.contains("\n") else { throw VaultFailure.message("請輸入保險箱名稱（最多 256 位元組）。") }
        let id = UUID(), salt = try random(32), recovery = try random(32)
        let code = recovery.map { String(format: "%02X", $0) }.joined()
        let grouped = stride(from: 0, to: code.count, by: 8).map { offset in
            String(code.dropFirst(offset).prefix(8))
        }.joined(separator: "-")
        let keys = VaultSecrets(id: id, password: try random(32).base64EncodedString(), salt: try random(32).base64EncodedString(), recoveryCode: grouped)
        let prototype = Self(format: "CloudMountVault", version: 1, id: id, name: name,
            kdf: "PBKDF2-SHA256", iterations: rounds, salt: salt, wrappedKeys: Data(), recoveryKeys: Data())
        let payload = try JSONEncoder().encode(keys)
        let mainKey = try derive(password: password, salt: salt, rounds: rounds)
        let recoveredKey = recoveryKey(recovery, id: id)
        let mainBox = try AES.GCM.seal(payload, using: mainKey, authenticating: prototype.authentication)
        let recoveryBox = try AES.GCM.seal(payload, using: recoveredKey, authenticating: prototype.authentication)
        guard let main = mainBox.combined, let backup = recoveryBox.combined else { throw VaultFailure.invalid }
        return (Self(format: prototype.format, version: 1, id: id, name: name, kdf: prototype.kdf,
            iterations: rounds, salt: salt, wrappedKeys: main, recoveryKeys: backup), keys)
    }
    func unlock(password: String) throws -> VaultSecrets {
        try validate()
        if let descriptor {
            do { return try VaultSecrets.standard(id: id, raw: descriptor.unlock(password: password)) }
            catch { throw VaultFailure.password }
        }
        guard !password.isEmpty, password.utf8.count <= 4096 else { throw VaultFailure.password }
        return try open(wrappedKeys, key: Self.derive(password: password, salt: salt, rounds: iterations))
    }
    func recover(code: String) throws -> VaultSecrets {
        try validate()
        if let descriptor {
            do {
                let raw = try RecoveryWords.decode(code); try descriptor.authenticate(rawKey: raw)
                return try VaultSecrets.standard(id: id, raw: raw)
            } catch { throw VaultFailure.password }
        }
        let code = code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard code.count == 64, code.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw VaultFailure.password }
        let values = Array(code)
        var bytes = Data()
        for offset in stride(from: 0, to: values.count, by: 2) {
            guard let byte = UInt8(String(values[offset...offset+1]), radix: 16) else { throw VaultFailure.password }
            bytes.append(byte)
        }
        return try open(recoveryKeys, key: Self.recoveryKey(bytes, id: id))
    }
    private func open(_ value: Data, key: SymmetricKey) throws -> VaultSecrets {
        do {
            let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: value), using: key, authenticating: authentication)
            let result = try JSONDecoder().decode(VaultSecrets.self, from: clear)
            guard result.id == id, result.password.count == 44, result.salt.count == 44 else { throw VaultFailure.password }
            return result
        } catch { throw VaultFailure.password }
    }
    private static func derive(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let password = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var output = Data(count: 32)
        let result = output.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), out.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard result == kCCSuccess else { throw VaultFailure.invalid }
        defer { output.resetBytes(in: output.startIndex..<output.endIndex) }
        return SymmetricKey(data: output)
    }
    private static func recoveryKey(_ bytes: Data, id: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: Data(id.uuidString.utf8),
            info: Data("CloudMountVaultRecovery-v1".utf8), outputByteCount: 32)
    }
    private static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VaultFailure.invalid }
        return bytes
    }
}

struct VaultLocation: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let remote: String
    let folder: String
    var automaticUnlock = false
    var formatVersion: Int? = nil
    var root: String { remote + ":" + folder }
    var dataRoot: String { root + "/data" }
    static func isSafeFolder(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(":" ) && !value.contains("\\") &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            !value.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }
    static func parent(_ input: String, s3: Bool) throws -> String {
        let absolute = !s3 && input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard (value.isEmpty || isSafeFolder(value)), !s3 || !value.isEmpty else {
            throw VaultFailure.message("請輸入有效的存放位置；S3 請先指定儲存桶名稱。")
        }
        return value.isEmpty ? VaultEnvelope.container : (absolute ? "/" : "") + value + "/" + VaultEnvelope.container
    }
}

struct VaultRecoveryFile: Codable {
    let format: String
    let envelope: VaultEnvelope
    let code: String
    let folder: String
    var instructions: String? = nil
    func secrets() throws -> VaultSecrets {
        guard format == "CloudMountRecovery-v1" || (format == "CryptomatorRecovery-v8" && envelope.descriptor != nil) else { throw VaultFailure.invalid }
        return try envelope.recover(code: code)
    }
}
