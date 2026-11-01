import Foundation

/// Shared by ordinary mounts and vault workers. Keep remote change detection
/// intact: no fast fingerprints, no disabled checksums, no long attr timeout.
enum MountCachePolicy {
    static func directoryMinutes(_ value: Int) -> Int { max(1, min(value, 60)) }

    // These are buffer limits, not a claim to cap the process's total memory.
    static let processArguments = ["--buffer-size", "4M", "--max-buffer-memory", "64M", "--transfers", "2"]

    static func arguments(directoryMinutes: Int) -> [String] {
        processArguments + [
            "--dir-cache-time", "\(self.directoryMinutes(directoryMinutes))m",
            "--vfs-cache-min-free-space", "1G",
            "--vfs-read-chunk-size", "8M", "--vfs-read-chunk-size-limit", "64M",
            "--vfs-read-chunk-streams", "0", "--vfs-read-ahead", "0",
        ]
    }

    static func vaultOptions(sizeGB: Int, ageHours: Int, directoryMinutes: Int) -> [String: Any] {
        ["CacheMode": 3,
         "CacheMaxSize": Int64(max(1, min(sizeGB, 1000))) * 1_073_741_824,
         "CacheMaxAge": Int64(max(1, min(ageHours, 8760))) * 3_600_000_000_000,
         "CacheMinFreeSpace": Int64(1_073_741_824),
         "DirCacheTime": Int64(self.directoryMinutes(directoryMinutes)) * 60_000_000_000,
         "ChunkSize": 8_388_608, "ChunkSizeLimit": 67_108_864, "ChunkStreams": 0,
         "ReadAhead": 0, "WriteBack": Int64(5_000_000_000)]
    }
}
