import Foundation

enum MountMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, fskit, fuse, nfs
    var id: String { rawValue }
    static let preferences: [Self] = [.automatic, .nfs, .fuse]
    var label: String {
        L10n.string([.automatic: "自動（優先 macFUSE）", .fskit: "macFUSE（FSKit）",
                    .fuse: "macFUSE（核心擴充，進階）", .nfs: "NFS（免安裝）"][self]!)
    }
    var command: String { self == .nfs ? "nfsmount" : "mount" }
    var rcMountType: String { self == .nfs ? "nfsmount" : "cmount" }
    var extraOptions: [String] {
        switch self { case .nfs: return ["locallocks", "noquota"]; case .fskit: return ["backend=fskit"]; default: return [] }
    }
    func mountOptions(label: String) -> [String: Any] { ["VolName": label, "ExtraOptions": extraOptions] }
}

enum TransferDirection: String, CaseIterable, Identifiable {
    case upload = "Mac → 遠端"
    case download = "遠端 → Mac"
    var id: String { rawValue }
}

struct DetectedMount: Equatable {
    let source: String
    let destination: String
    let fileSystem: String
    let remote: String?
    let remoteConfigured: Bool
    let folder: String
}

enum RcloneHelpers {
    static func normalizedMountPath(_ input: String) -> String {
        var path = input
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path; break
        }
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(part) }
        }
        return "/" + components.joined(separator: "/")
    }
    static func normalizedFolder(_ folder: String) -> String {
        folder.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func isValidRemoteName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: #"^[\p{L}\p{N}_][\p{L}\p{N}_. -]*$"#, options: .regularExpression) != nil
    }
    static func pathKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    static func pathsEqual(_ a: String, _ b: String) -> Bool { pathKey(a) == pathKey(b) }
    static func pathContains(_ parent: String, _ path: String) -> Bool {
        let a = pathKey(parent), b = pathKey(path)
        return a == b || b.hasPrefix(a == "/" ? "/" : a + "/")
    }
    static func redactLog(_ text: String) -> String {
        var value = text
        for (pattern, replacement) in [
            (#"(?i)(https?://)[^/@\s]+:[^/@\s]+@"#, "$1[hidden]@"),
            (#"(?i)(authorization\s*:\s*(?:bearer|basic)\s+)[^\s]+"#, "$1[hidden]"),
            (#"(?i)((?:access_token|refresh_token|bearer_token|password2?|pass|recoveryCode|client_secret|secret_access_key)[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)"#, "$1[hidden]")
        ] {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return value
    }

    static func mountDirectoryBlockers(_ contents: [String]) -> [String] {
        let harmlessFinderMetadata: Set<String> = [".DS_Store", ".localized"]
        return contents.filter { !harmlessFinderMetadata.contains($0) }
    }

    static func normalizedConfigurationValues(provider: String, values: [String: String]) -> [String: String] {
        var normalized = values
        // rclone's generic WebDAV setup explicitly uses vendor=other. Keeping
        // this default in the generated config avoids backend-specific behavior
        // when the optional vendor question is left blank.
        if provider == "webdav", normalized["vendor"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            normalized["vendor"] = "other"
        }
        if provider == "s3", normalized["provider"]?.isEmpty != false {
            normalized["provider"] = "Other"
        }
        return normalized
    }

    static func s3NeedsCompatibleProvider(_ values: [String: String]) -> Bool {
        guard values["provider"] == "AWS", let endpoint = values["endpoint"],
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let host = URLComponents(string: endpoint)?.host?.lowercased() else { return false }
        // AWS private endpoints also end in these suffixes. Do not infer a
        // compatible-service provider for genuine AWS endpoints.
        return !["amazonaws.com", "amazonaws.com.cn"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func s3AllowsPathStyle(provider: String) -> Bool {
        // rclone 1.75.2 backend/s3/provider/*.yaml: providers without the
        // force_path_style quirk always override this flag to false.
        ["ArvanCloud", "BizflyCloud", "Ceph", "ChinaMobile", "Cloudflare", "Exaba", "Fastly", "FileLu", "FlashBlade", "HCP", "IBMCOS", "IDrive", "IONOS", "Liara", "Magalu", "Mega", "Minio", "Other", "Outscale", "Qiniu", "Rclone", "Scality", "SeaweedFS", "SpectraLogic", "Zadara", "ZeroServices"].contains(provider)
    }

    static func s3BucketError(_ bucket: String) -> String? {
        let value = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return L10n.string("請填寫或選擇 S3 儲存桶名稱。") }
        // S3 gateways may expose existing folders as buckets, including Unicode
        // and spaces. Do not impose AWS's DNS rules on path-style services.
        guard value.utf8.count <= 1024, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            return L10n.string("儲存桶請只填名稱，不要填網址或資料夾路徑。")
        }
        return nil
    }

    static func splitS3MountPath(_ path: String) -> (bucket: String, subfolder: String) {
        let parts = normalizedFolder(path).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        return (parts.first.map(String.init) ?? "", parts.count > 1 ? String(parts[1]) : "")
    }

    static func s3MountPath(bucket: String, subfolder: String) -> String {
        let bucket = normalizedFolder(bucket)
        guard !bucket.isEmpty else { return "" }
        let folder = normalizedFolder(subfolder).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return bucket + (folder.isEmpty ? "" : "/" + folder)
    }

    static func s3PrefixError(bucket: String, prefix: String) -> String? {
        guard !normalizedFolder(prefix).isEmpty else { return nil }
        guard !normalizedFolder(bucket).isEmpty else { return L10n.string("填寫路徑前綴時，請同時指定儲存桶。") }
        guard prefix.rangeOfCharacter(from: .controlCharacters) == nil,
              !prefix.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return L10n.string("路徑前綴不能包含控制字元或 .、.. 路徑。")
        }
        return nil
    }

    static func remoteErrorStatus(in output: String) -> String? {
        let message = output.lowercased()
        if message.contains("401 unauthorized") || message.contains("unauthorized") {
            return L10n.string("驗證失敗（401）")
        }
        if message.contains("403 forbidden") || message.contains("forbidden") {
            return L10n.string("存取遭拒（403）")
        }
        if message.contains("no such host") {
            if message.contains("operation error s3:") { return L10n.string("S3 網址無法解析") }
            return L10n.string("找不到伺服器位址")
        }
        if message.contains("connection refused") || message.contains("network is unreachable") {
            return L10n.string("無法連線到伺服器")
        }
        return nil
    }

    static func configurationStartArguments(remote: String, provider: String, updating: Bool, values: [String: String]) -> [String] {
        var arguments = ["config", updating ? "update" : "create", remote]
        if !updating { arguments.append(provider) }
        arguments += ["--non-interactive", "--obscure"]
        if !values.isEmpty { arguments.append("--") }
        for key in values.keys.sorted() { arguments += [key, values[key]!] }
        return arguments
    }
    static func configurationContinuationArguments(remote: String, state: String, answer: String,
                                                    defaults: [String: String]) -> [String] {
        var arguments = ["config", "update", remote, "--continue", "--state", state,
                         "--result", answer, "--non-interactive", "--obscure"]
        let keys = defaults.keys.filter { defaults[$0]?.isEmpty == false }.sorted()
        if !keys.isEmpty { arguments.append("--") }
        for key in keys { arguments += [key, defaults[key]!] }
        return arguments
    }

    static func identifyMountedVolumes(_ volumes: [SystemMount], remotes: [String], homeDirectory: String) -> [DetectedMount] {
        let supported: Set<String> = ["nfs", "macfuse", "fuse-t", "fuse", "fusefs", "macfuse_fskit", "macfuse.fskit"]
        let root = homeDirectory + "/CloudMounts/"
        return volumes.compactMap { volume in
            let fileSystem = volume.fileSystem.lowercased()
            guard supported.contains(fileSystem) else { return nil }
            let sourceRemote = volume.source.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            var remote = remotes.first { $0 == sourceRemote }
            if remote == nil && volume.destination.hasPrefix(root) {
                let candidate = String(volume.destination.dropFirst(root.count).split(separator: "/").first ?? "")
                remote = remotes.first { safeDirectoryName($0) == candidate }
                if remote == nil && !sourceRemote.isEmpty { remote = sourceRemote }
            }
            let folder = remote.flatMap { volume.source.hasPrefix($0 + ":") ? normalizedFolder(String(volume.source.dropFirst($0.count + 1))) : nil } ?? ""
            return DetectedMount(source: volume.source, destination: volume.destination, fileSystem: fileSystem,
                remote: remote, remoteConfigured: remote.map { remotes.contains($0) } ?? false, folder: folder)
        }
    }
    static func parseMountedVolumes(_ output: String, remotes: [String], homeDirectory: String) -> [DetectedMount] {
        let entries: [SystemMount] = output.components(separatedBy: .newlines).compactMap { line in
            guard let on = line.range(of: " on "), let attributes = line.range(of: " (", options: .backwards), on.upperBound <= attributes.lowerBound else { return nil }
            let source = String(line[..<on.lowerBound])
            let destination = String(line[on.upperBound..<attributes.lowerBound]).replacingOccurrences(of: "\\040", with: " ")
            let fileSystem = String(line[attributes.upperBound...]).split(separator: ",").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: ") ")) ?? ""
            return SystemMount(source: source, destination: destination, fileSystem: fileSystem)
        }
        return identifyMountedVolumes(entries, remotes: remotes, homeDirectory: homeDirectory)
    }

    static func parseRemotes(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix(":") && $0.count > 1 }
            .map { String($0.dropLast()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func remotePath(name: String, folder: String) -> String {
        // Leading slashes distinguish absolute and home-relative paths in
        // SFTP/FTP/local backends. Let the backend interpret the path.
        return name + ":" + normalizedFolder(folder)
    }

    static func safeDirectoryName(_ remote: String) -> String {
        let name = remote.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return name.isEmpty || name == ".." ? "remote" : name
    }

    static func mountArguments(method: MountMethod, remote: String, folder: String,
                               destination: String, readOnly: Bool, cacheReadFiles: Bool = false,
                               cacheMaxSizeGB: Int = 20, cacheMaxAgeHours: Int = 24,
                               cacheDirectoryMinutes: Int = 5,
                               allowNonEmpty: Bool = false) -> [String] {
        var arguments = [method.command, remotePath(name: remote, folder: folder), destination,
                         "--vfs-cache-mode", cacheReadFiles ? "full" : "writes",
                         "--vfs-cache-max-size", "\(max(1, min(cacheMaxSizeGB, 1000)))G",
                         "--vfs-cache-max-age", "\(max(1, min(cacheMaxAgeHours, 8760)))h",
                         "--volname", remote]
        arguments += MountCachePolicy.arguments(directoryMinutes: cacheDirectoryMinutes)
        if readOnly { arguments.append("--read-only") }
        for option in method.extraOptions { arguments += ["--option", option] }
        if (method == .fuse || method == .fskit) && allowNonEmpty { arguments.append("--allow-non-empty") }
        return arguments
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func transferArguments(command: String, remote: String, remoteFolder: String,
                                  local: String, direction: TransferDirection,
                                  dryRun: Bool) -> [String] {
        let remote = remotePath(name: remote, folder: remoteFolder)
        let endpoints = direction == .upload ? [local, remote] : [remote, local]
        return [command] + endpoints + (dryRun ? ["--dry-run"] : []) + ["--stats", "5s"]
    }
}


enum AutoMountPolicy {
    static func requestedRemotes(enabled: Bool, selected: Set<String>, available: [String], recovering: Bool, quitting: Bool) -> [String] {
        guard enabled, !recovering, !quitting else { return [] }
        return available.filter { selected.contains($0) }
    }
}
