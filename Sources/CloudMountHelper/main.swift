import Foundation
import AppKit
import Darwin
import FSKit

struct SystemMount: Codable {
    let source: String
    let destination: String
    let fileSystem: String
}
struct Preparation: Codable {
    let path: String
    let allowNonEmpty: Bool
}
struct HelperFailure: Error { let message: String }

func cString<T>(_ input: T) -> String {
    withUnsafeBytes(of: input) { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
func snapshot() throws -> [SystemMount] {
    let initialCount = getfsstat(nil, 0, MNT_NOWAIT)
    guard initialCount >= 0, initialCount < 100_000 else { throw HelperFailure(message: "snapshot_failed") }
    let capacity = max(Int(initialCount) + 32, 32)
    let entries = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
    defer { entries.deallocate() }
    let count = getfsstat(entries, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
    guard count >= 0, Int(count) < capacity else { throw HelperFailure(message: "snapshot_failed") }
    return (0..<Int(count)).map { index in
        let item = entries[index]
        return SystemMount(source: cString(item.f_mntfromname), destination: cString(item.f_mntonname),
                           fileSystem: cString(item.f_fstypename))
    }
}
func contains(_ parent: String, _ path: String) -> Bool {
    let a = parent.precomposedStringWithCanonicalMapping.lowercased()
    let b = path.precomposedStringWithCanonicalMapping.lowercased()
    return a == b || b.hasPrefix(a == "/" ? "/" : a + "/")
}
func prepare(_ proposed: String) throws -> Preparation {
    guard proposed.hasPrefix("/"), !proposed.contains("\n"), !proposed.contains("\0") else {
        throw HelperFailure(message: "invalid_path")
    }
    var rawPath = proposed
    for alias in ["/tmp", "/var", "/etc"] where rawPath == alias || rawPath.hasPrefix(alias + "/") {
        rawPath = "/private" + rawPath; break
    }
    var components: [Substring] = []
    for part in rawPath.split(separator: "/") {
        if part == "." { continue }
        if part == ".." { if !components.isEmpty { components.removeLast() } }
        else { components.append(part) }
    }
    let path = "/" + components.joined(separator: "/")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path != "/", path != home, path != "/Users", path != "/Volumes", path != "/tmp", path != "/private/tmp",
          !["/System", "/Library", "/bin", "/sbin", "/usr", "/dev", "/proc"].contains(where: { contains($0, path) }),
          !contains(path, Bundle.main.bundleURL.path) else { throw HelperFailure(message: "unsafe_path") }
    let mounts = try snapshot()
    // Never traverse a remote or an existing mount point, including a mount
    // mounted by another app. MNT_NOWAIT reads only the kernel's cached table.
    let closest = mounts.filter { contains($0.destination, path) }.max { $0.destination.count < $1.destination.count }
    guard let closest, ["apfs", "hfs", "tmpfs", "devfs"].contains(closest.fileSystem.lowercased()),
          !mounts.contains(where: { contains(path, $0.destination) }) else {
        throw HelperFailure(message: "mounted_path")
    }
    var ancestor = URL(fileURLWithPath: path)
    while ancestor.path != "/" {
        var info = stat()
        if lstat(ancestor.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw HelperFailure(message: "symlink_path")
        }
        ancestor.deleteLastPathComponent()
    }
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
        throw HelperFailure(message: "unsafe_path")
    }
    let contents = try FileManager.default.contentsOfDirectory(atPath: path)
    var blockers: [String] = []
    for name in contents {
        var item = stat()
        let metadata = [".DS_Store", ".localized"].contains(name)
        let regular = lstat(URL(fileURLWithPath: path).appendingPathComponent(name).path, &item) == 0 &&
            (item.st_mode & S_IFMT) == S_IFREG && item.st_size <= 1_048_576
        if !metadata || !regular { blockers.append(name) }
    }
    guard blockers.isEmpty else { throw HelperFailure(message: "not_empty:" + blockers.prefix(10).joined(separator: ", ")) }
    return Preparation(path: path, allowNonEmpty: !contents.isEmpty)
}
func write<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try JSONEncoder().encode(value))
}
struct FinderReply: Encodable { let status: String }
func openFinder(_ path: String) throws -> FinderReply {
    guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else {
        throw HelperFailure(message: "invalid_path")
    }
    // Inspect the cached kernel table only. Do not stat or list this directory.
    guard try snapshot().contains(where: { $0.destination == path }) else {
        return FinderReply(status: "not-mounted")
    }
    let completed = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var accepted = false
    DispatchQueue.global(qos: .userInitiated).async {
        // Explicit directory hints avoid Foundation's implicit filesystem probe.
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
        NSWorkspace.shared.open([directory], withApplicationAt: finder,
                                configuration: NSWorkspace.OpenConfiguration()) { app, error in
            lock.lock(); accepted = app != nil && error == nil; lock.unlock()
            completed.signal()
        }
    }
    guard completed.wait(timeout: .now() + 3) == .success else { return FinderReply(status: "unconfirmed") }
    lock.lock(); defer { lock.unlock() }
    return FinderReply(status: accepted ? "accepted" : "unconfirmed")
}
func dirtyCache(path: String, root: String) throws -> Int {
    guard path.hasPrefix("/"), root.hasPrefix("/"), contains(root, path),
          !path.split(separator: "/").contains(".."), !root.split(separator: "/").contains("..") else { throw HelperFailure(message: "unsafe_cache") }
    let mounts = try snapshot()
    guard let closest = mounts.filter({ contains($0.destination, root) }).max(by: { $0.destination.count < $1.destination.count }),
          ["apfs", "hfs", "tmpfs"].contains(closest.fileSystem.lowercased()),
          !mounts.contains(where: { contains(root, $0.destination) }) else { throw HelperFailure(message: "unsafe_cache") }
    var ancestor = URL(fileURLWithPath: path)
    while ancestor.path != "/" {
        var info = stat()
        if lstat(ancestor.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw HelperFailure(message: "unsafe_cache") }
        ancestor.deleteLastPathComponent()
    }
    var info = stat()
    if lstat(path, &info) != 0 {
        guard errno == ENOENT else { throw HelperFailure(message: "unknown_cache") }
        return 0
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw HelperFailure(message: "unsafe_cache") }
    var failed = false
    guard let entries = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in failed = true; return false }) else { throw HelperFailure(message: "unknown_cache") }
    var dirty = 0, count = 0
    for case let url as URL in entries {
        count += 1
        guard count <= 20_000 else { throw HelperFailure(message: "large_cache") }
        var item = stat()
        if lstat(url.path, &item) != 0 {
            guard errno == ENOENT else { throw HelperFailure(message: "unknown_cache") }
            continue
        }
        if (item.st_mode & S_IFMT) == S_IFDIR { continue }
        guard (item.st_mode & S_IFMT) == S_IFREG, item.st_size <= 1_048_576 else { throw HelperFailure(message: "unsafe_cache") }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["Dirty"] as? Bool else { throw HelperFailure(message: "unknown_cache") }
            if value { dirty += 1 }
        } catch { throw HelperFailure(message: "unknown_cache") }
    }
    guard !failed else { throw HelperFailure(message: "unknown_cache") }
    return dirty
}
func saveRecovery(_ path: String) throws {
    guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw HelperFailure(message: "unsafe_export") }
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    let mounts = try snapshot()
    guard let closest = mounts.filter({ contains($0.destination, directory.path) }).max(by: { $0.destination.count < $1.destination.count }),
          ["apfs", "hfs", "tmpfs"].contains(closest.fileSystem.lowercased()) else { throw HelperFailure(message: "local_export_only") }
    var ancestor = URL(fileURLWithPath: path)
    while ancestor.path != "/" {
        var info = stat()
        if lstat(ancestor.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw HelperFailure(message: "unsafe_export") }
        ancestor.deleteLastPathComponent()
    }
    var content = Data()
    while let part = try FileHandle.standardInput.read(upToCount: 65_537 - content.count), !part.isEmpty {
        content.append(part)
        guard content.count <= 65_536 else { throw HelperFailure(message: "invalid_export") }
    }
    guard let object = try JSONSerialization.jsonObject(with: content) as? [String: Any], ["CloudMountRecovery-v1", "CryptomatorRecovery-v8"].contains(object["format"] as? String ?? "") else { throw HelperFailure(message: "invalid_export") }
    let temporary = directory.appendingPathComponent(".cloudmount-recovery-" + UUID().uuidString)
    let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw HelperFailure(message: "export_failed") }
    defer { unlink(temporary.path) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: content); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, path) == 0 else { throw HelperFailure(message: "export_failed") }
    } catch { try? handle.close(); throw error }
}
do {
    let args = CommandLine.arguments
    switch args.dropFirst().first {
    case "open-finder":
        guard args.count == 3 else { throw HelperFailure(message: "invalid_path") }
        try write(openFinder(args[2]))
    case "save-vault-recovery":
        guard args.count == 3 else { throw HelperFailure(message: "invalid_export") }
        try saveRecovery(args[2]); try write(true)
    case "vault-cache":
        guard args.count == 4 else { throw HelperFailure(message: "unsafe_cache") }
        try write(dirtyCache(path: args[2], root: args[3]))
    case "macfuse-status":
        // Query only. Never start a mount or request system approval here.
        // This helper can be stopped by the caller if FSKit does not reply.
        FSClient.shared.fetchInstalledExtensions { modules, error in
            let module = modules?.first { $0.bundleIdentifier == "io.macfuse.app.fsmodule.macfuse" }
            do {
                try write(["visible": module != nil, "enabled": module?.isEnabled == true])
                exit(error == nil ? 0 : 1)
            } catch { exit(1) }
        }
        dispatchMain()
    case "snapshot": try write(snapshot())
    case "prepare":
        guard args.count == 3 else { throw HelperFailure(message: "invalid_path") }
        try write(prepare(args[2]))
    case "directory":
        guard args.count == 3, args[2].hasPrefix("/") else { throw HelperFailure(message: "invalid_path") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: args[2], isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HelperFailure(message: "directory_missing")
        }
        try write(true)
    default: throw HelperFailure(message: "invalid_command")
    }
} catch {
    let message = (error as? HelperFailure)?.message ?? error.localizedDescription
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
