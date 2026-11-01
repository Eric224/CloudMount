import XCTest
import Foundation
@testable import CloudMountVaultCore

final class CryptomatorCoreTests: XCTestCase {
    let password = "互通測試-password-123"
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cm-format8-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    func filesystem(_ root: URL, scratch: URL) throws -> VaultFileSystem {
        let descriptor = try VaultDescriptor.parse(masterkeyFile: Data(contentsOf: root.appendingPathComponent(VaultDescriptor.keyName)), vaultConfig: Data(contentsOf: root.appendingPathComponent(VaultDescriptor.configName)))
        return try VaultFileSystem(store: LocalCiphertextStore(root: root), descriptor: descriptor, rawKey: descriptor.unlock(password: password), scratch: scratch)
    }
    func create(_ root: URL, scratch: URL) async throws -> VaultFileSystem {
        let (descriptor, raw) = try VaultDescriptor.create(password: password)
        try descriptor.masterkeyFile.write(to: root.appendingPathComponent(VaultDescriptor.keyName))
        try descriptor.vaultConfig.write(to: root.appendingPathComponent(VaultDescriptor.configName))
        let fs = try VaultFileSystem(store: LocalCiphertextStore(root: root), descriptor: descriptor, rawKey: raw, scratch: scratch)
        try await fs.initialize()
        return fs
    }
    func put(_ text: String, path: String, fs: VaultFileSystem, scratch: URL) async throws {
        let input = scratch.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data(text.utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        try await fs.upload(input, to: path)
    }
    func read(_ path: String, fs: VaultFileSystem, scratch: URL) async throws -> String {
        let output = scratch.appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await fs.download(path, to: output)
        return try String(contentsOf: output, encoding: .utf8)
    }
    func testPasswordAuthenticationAndOfficialRecoveryWords() throws {
        let (d, key) = try VaultDescriptor.create(password: password)
        XCTAssertEqual(try d.unlock(password: password), key)
        XCTAssertThrowsError(try d.unlock(password: "wrong password"))
        var altered = d.vaultConfig; altered[altered.count - 2] ^= 1
        if let broken = try? VaultDescriptor.parse(masterkeyFile: d.masterkeyFile, vaultConfig: altered) {
            XCTAssertThrowsError(try broken.authenticate(rawKey: key))
        }
        XCTAssertEqual(try RecoveryWords.decode(RecoveryWords.encode(key)), key)
        let official = "pathway lift abuse plenty export texture gentleman landscape beyond ceiling around leaf cafe charity border breakdown victory surely computer cat linger restrict infer crowd live computer true written amazed investor boot depth left theory snow whereby terminal weekly reject happiness circuit partial cup ad"
        let decoded = try RecoveryWords.decode(official)
        XCTAssertEqual(try RecoveryWords.encode(decoded), official)
        XCTAssertThrowsError(try RecoveryWords.decode(official.replacingOccurrences(of: "cup ad", with: "cup wrong")))
    }
    func testCRUDUnicodeLongNamesAndConflict() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try temporary(); defer { try? FileManager.default.removeItem(at: scratch) }
        let fs = try await create(root, scratch: scratch), long = String(repeating: "長", count: 80) + ".txt"
        try await fs.mkdir("中文資料")
        try await put("初次", path: "中文資料/" + long, fs: fs, scratch: scratch)
        let first = try await fs.stat("中文資料/" + long)
        try await put("覆寫", path: "中文資料/" + long, fs: fs, scratch: scratch)
        let stale = scratch.appendingPathComponent("stale"); try Data("過期內容".utf8).write(to: stale)
        do { try await fs.upload(stale, to: "中文資料/" + long, expectedVersion: first.version); XCTFail("stale revision accepted") }
        catch VaultCoreError.conflict {}
        let text = try await read("中文資料/" + long, fs: fs, scratch: scratch); XCTAssertEqual(text, "覆寫")
        try await fs.move("中文資料/" + long, to: "移出.txt", replace: false)
        try await fs.move("中文資料", to: "改名資料夾", replace: false)
        let moved = try await read("移出.txt", fs: fs, scratch: scratch); XCTAssertEqual(moved, "覆寫")
        try await fs.delete("移出.txt"); try await fs.delete("改名資料夾")
        let children = try await fs.list(""); XCTAssertTrue(children.isEmpty)
        do { try await fs.mkdir("../escape"); XCTFail("unsafe path accepted") } catch VaultCoreError.unsafePath {}
    }
    func testEmptyAndChunkBoundarySizesAreExactAndTamperingFails() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try temporary(); defer { try? FileManager.default.removeItem(at: scratch) }
        let fs = try await create(root, scratch: scratch)
        for size in [0, 1, 32767, 32768, 32769, 65536] {
            let input = scratch.appendingPathComponent("input", isDirectory: false)
            let output = scratch.appendingPathComponent("output", isDirectory: false)
            let data = Data(repeating: 127, count: size)
            try data.write(to: input)
            try await fs.upload(input, to: "file-\(size)")
            let stat = try await fs.stat("file-\(size)"); XCTAssertEqual(stat.size, Int64(size))
            _ = try await fs.download("file-\(size)", to: output)
            XCTAssertEqual(try Data(contentsOf: output), data)
        }
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("d"), includingPropertiesForKeys: nil))
        let cipher = try XCTUnwrap(files.allObjects.compactMap { $0 as? URL }.first { $0.pathExtension == "c9r" && $0.lastPathComponent != "dirid.c9r" })
        var bytes = try Data(contentsOf: cipher); bytes[0] ^= 1; try bytes.write(to: cipher)
        var rejected = false
        for size in [0, 1, 32767, 32768, 32769, 65536] {
            do { _ = try await fs.download("file-\(size)", to: scratch.appendingPathComponent("tampered", isDirectory: false)) }
            catch { rejected = true; break }
        }
        XCTAssertTrue(rejected)
    }
    func testLocalAdapterRejectsSymlinkAncestors() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = try temporary(); defer { try? FileManager.default.removeItem(at: outside) }
        try Data("private".utf8).write(to: outside.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let store = LocalCiphertextStore(root: root)
        do { _ = try await store.read("escape/secret", limit: 100); XCTFail("symlink traversal") }
        catch VaultCoreError.unsafePath {}
    }
    func testIndependentOfficialCryptofsBothDirections() async throws {
        guard let java = ProcessInfo.processInfo.environment["CLOUDMOUNT_INTEROP_JAVA"],
              let classes = ProcessInfo.processInfo.environment["CLOUDMOUNT_INTEROP_CLASSES"] else { throw XCTSkip("Set Java 25 and compiled official interop harness paths") }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try temporary(); defer { try? FileManager.default.removeItem(at: scratch) }
        let fs = try await create(root, scratch: scratch), long = String(repeating: "長", count: 80) + ".txt"
        try await fs.mkdir("中文資料")
        try await put("Swift 原始內容", path: "中文資料/測試.txt", fs: fs, scratch: scratch)
        try await put("長檔名內容", path: "中文資料/" + long, fs: fs, scratch: scratch)
        try await put("刪除", path: "待刪除.txt", fs: fs, scratch: scratch)
        func official(_ mode: String, _ path: URL) throws {
            let p = Process(), input = Pipe(), output = Pipe()
            p.executableURL = URL(fileURLWithPath: java, isDirectory: false)
            p.arguments = ["-cp", classes + ":/Applications/Cryptomator.app/Contents/app/mods/*", "CryptomatorInterop", mode, path.path]
            p.standardInput = input; p.standardOutput = output; p.standardError = output
            try p.run(); try input.fileHandleForWriting.write(contentsOf: Data(password.utf8)); try input.fileHandleForWriting.close()
            let log = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, String(decoding: log, as: UTF8.self))
        }
        try official("edit", root)
        let changed = try await read("中文資料/測試.txt", fs: fs, scratch: scratch); XCTAssertEqual(changed, "官方覆寫內容")
        let renamed = try await read("官方改名.txt", fs: fs, scratch: scratch); XCTAssertEqual(renamed, "長檔名內容")
        let created = try await read("官方建立/跨平台.txt", fs: fs, scratch: scratch); XCTAssertEqual(created, "Cryptomator 官方寫入")
        let other = scratch.appendingPathComponent("official", isDirectory: true)
        try official("create", other)
        let officialFS = try filesystem(other, scratch: scratch)
        let reverse = try await read("官方建立/" + long, fs: officialFS, scratch: scratch); XCTAssertEqual(reverse, "官方長檔名")
    }
}

/// Models an acknowledged mapping write followed by a failed remote commit.
private actor InterruptedCiphertextStore: CiphertextStore {
    let base: LocalCiphertextStore
    var failNextMove = true
    init(root: URL) { base = LocalCiphertextStore(root: root) }
    func stat(_ path: String) async throws -> CipherItem { try await base.stat(path) }
    func list(_ path: String) async throws -> [CipherItem] { try await base.list(path) }
    func read(_ path: String, limit: Int) async throws -> Data { try await base.read(path, limit: limit) }
    func download(_ path: String, to file: URL) async throws { try await base.download(path, to: file) }
    func upload(_ file: URL, to path: String) async throws { try await base.upload(file, to: path) }
    func mkdir(_ path: String) async throws { try await base.mkdir(path) }
    func delete(_ path: String, directory: Bool) async throws { try await base.delete(path, directory: directory) }
    func move(_ source: String, to destination: String, directory: Bool, replace: Bool) async throws {
        if failNextMove { failNextMove = false; throw VaultCoreError.unavailable }
        try await base.move(source, to: destination, directory: directory, replace: replace)
    }
}

extension CryptomatorCoreTests {
    func testInterruptedLongNameCommitCanRetryWithoutLosingSource() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try temporary(); defer { try? FileManager.default.removeItem(at: scratch) }
        let (descriptor, raw) = try VaultDescriptor.create(password: password)
        let fs = try VaultFileSystem(store: InterruptedCiphertextStore(root: root), descriptor: descriptor, rawKey: raw, scratch: scratch)
        try await fs.initialize()
        let source = scratch.appendingPathComponent("source", isDirectory: false), bytes = Data("保留並重試".utf8)
        try bytes.write(to: source)
        let name = String(repeating: "長", count: 80) + ".txt"
        do { try await fs.upload(source, to: name); XCTFail("injected commit failure was hidden") } catch VaultCoreError.unavailable {}
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        try await fs.upload(source, to: name)
        let result = try await read(name, fs: fs, scratch: scratch)
        XCTAssertEqual(result, "保留並重試")
        let items = try await fs.list(""); XCTAssertEqual(items.map(\.name), [name])
    }
}

private actor MetadataCountingStore: CiphertextStore {
    let base: LocalCiphertextStore
    var stats = 0, listings = 0
    init(root: URL) { base = LocalCiphertextStore(root: root) }
    func reset() { stats = 0; listings = 0 }
    func counts() -> (Int, Int) { (stats, listings) }
    func stat(_ path: String) async throws -> CipherItem { stats += 1; return try await base.stat(path) }
    func list(_ path: String) async throws -> [CipherItem] { listings += 1; return try await base.list(path) }
    func read(_ path: String, limit: Int) async throws -> Data { try await base.read(path, limit: limit) }
    func download(_ path: String, to file: URL) async throws { try await base.download(path, to: file) }
    func upload(_ file: URL, to path: String) async throws { try await base.upload(file, to: path) }
    func mkdir(_ path: String) async throws { try await base.mkdir(path) }
    func delete(_ path: String, directory: Bool) async throws { try await base.delete(path, directory: directory) }
    func move(_ source: String, to destination: String, directory: Bool, replace: Bool) async throws {
        try await base.move(source, to: destination, directory: directory, replace: replace)
    }
}
extension CryptomatorCoreTests {
    func testListingUsesExistingMetadataInsteadOfPerFileCloudStats() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try temporary(); defer { try? FileManager.default.removeItem(at: scratch) }
        let (descriptor, raw) = try VaultDescriptor.create(password: password), store = MetadataCountingStore(root: root)
        let fs = try VaultFileSystem(store: store, descriptor: descriptor, rawKey: raw, scratch: scratch)
        try await fs.initialize()
        for i in 0..<20 { try await put("\(i)", path: "資料-\(i).txt", fs: fs, scratch: scratch) }
        await store.reset()
        let listing = try await fs.list("")
        let (stats, directories) = await store.counts()
        XCTAssertEqual(listing.count, 20)
        XCTAssertEqual(directories, 1)
        XCTAssertEqual(stats, 0, "A slow backend must not receive one extra request per file")
        for item in listing { XCTAssertEqual(item.size, Int64(String(item.name.dropFirst(3).dropLast(4)).utf8.count)) }
    }
}
