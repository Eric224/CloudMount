import Foundation

/// Official Cryptomator desktop WordEncoder/RecoveryKeyFactory representation:
/// 64 key bytes + first two little-endian CRC32 bytes => 44 12-bit words.
public enum RecoveryWords {
    private static let words: [String] = {
        guard let url = Bundle.module.url(forResource: "4096words_en", withExtension: "txt") ?? Bundle.module.url(forResource: "4096words_en", withExtension: "txt", subdirectory: "Resources"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).prefix(4096).map(String.init)
    }()
    private static let indices: [String: Int] = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
    public static func encode(_ raw: Data) throws -> String {
        guard raw.count == 64, words.count == 4096 else { throw VaultCoreError.malformed }
        let crc = crc32(raw)
        let bytes = Array(raw) + [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
        var result: [String] = []
        for i in stride(from: 0, to: 66, by: 3) {
            let first = (Int(bytes[i]) << 4) | (Int(bytes[i + 1]) >> 4)
            let second = ((Int(bytes[i + 1]) & 15) << 8) | Int(bytes[i + 2])
            result.append(words[first]); result.append(words[second])
        }
        return result.joined(separator: " ")
    }
    public static func decode(_ phrase: String) throws -> Data {
        let parts = phrase.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 44, words.count == 4096 else { throw VaultCoreError.password }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: parts.count, by: 2) {
            guard let a = indices[parts[i]], let b = indices[parts[i + 1]] else { throw VaultCoreError.password }
            bytes += [UInt8(a >> 4), UInt8((a & 15) << 4 | b >> 8), UInt8(b & 255)]
        }
        let raw = Data(bytes.prefix(64)), crc = crc32(raw)
        guard bytes[64] == UInt8(truncatingIfNeeded: crc), bytes[65] == UInt8(truncatingIfNeeded: crc >> 8) else { throw VaultCoreError.password }
        return raw
    }
    private static func crc32(_ value: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in value {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0) }
        }
        return ~crc
    }
}
