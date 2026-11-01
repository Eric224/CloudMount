# CloudMount SFTP patches

Upstream https://github.com/orlandos-nl/Citadel, 0.12.1, ae8562f895de06ccb86fdb1cbb65fd99c8976e12. License retained.

- SFTP v3 RENAME does not send a v5 flags field.
- Add advertised OpenSSH posix-rename atomic replacement, without pre-deleting originals.
- Add LSTAT to reject symbolic links as ordinary files.
- Bound directory canonicalization and listing; close directory handle on success/failure.

Cryptographic algorithms unchanged. Transitive dependencies pinned by Package.resolved.

- Rejecting the host key or login closes the established TCP channel.
- Expose strict SHA256 host-key pinning; quiet file-operation logging.
