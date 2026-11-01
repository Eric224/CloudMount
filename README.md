# CloudMount

CloudMount lets you connect remote storage from Apple devices and work with it in the system file browser. The iPhone and iPad app exposes configured locations in **Files**. The Mac app mounts supported remotes for **Finder**. Standard Cryptomator vaults can be created, unlocked, locked and used across devices.

The app is designed for people who use more than one cloud provider, NAS or self-hosted storage service and want a graphical setup instead of command-line configuration.

## App Store review snapshot

- iOS/iPadOS version: **0.4.12 (18)**
- Platforms in this snapshot: iPhone and iPad
- Mobile file access: Apple's File Provider interface and native network providers
- Vault format: Cryptomator vault format 8
- Languages: Traditional Chinese, Simplified Chinese and English, with English fallback

This source snapshot corresponds to the submitted mobile build. The Mac source in this snapshot is included as reference and may not match the latest Mac release. Neither snapshot contains signing credentials, private cloud settings, or review-account credentials.

## Supported connection types

The mobile version includes native WebDAV and S3 access, and FTP, FTPS and SFTP. macOS additionally packages rclone for its supported backends, including S3-compatible services and numerous cloud-storage protocols. A provider's availability, authentication requirements and API limits still apply.

## Build from source

See [SOURCE-RELEASE.md](SOURCE-RELEASE.md) for the pinned dependencies, build steps and platform-specific requirements. The mobile project is generated with `python3 Mobile/generate-project.py`; the Mac rclone engine is reproducibly built with `python3 Engine/build-engine.py /path/to/go`.

## Privacy and credentials

CloudMount has no CloudMount account or developer-hosted storage service. Remote-service credentials are entered by the user and stored locally by the app. Do not commit personal provider configuration, passwords, API tokens, provisioning profiles, signing certificates, app binaries or test recordings.

## License

CloudMount-authored source is licensed under **AGPL-3.0-only**; see [LICENSE](LICENSE). Third-party code retains its own terms and notices. In particular, the pinned Cryptomator cryptolib's published FOSS option is AGPLv3; the separate commercial license is not included. See [Vendor/LICENSING.md](Vendor/LICENSING.md) and the notices beside the vendored code.

The source license does not claim that Apple's App Store EULA or distribution terms have been independently reviewed or approved for AGPL compatibility.
