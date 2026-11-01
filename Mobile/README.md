# CloudMount for iPhone and iPad

This directory contains the iOS/iPadOS source corresponding to **0.4.12 (18)**, the build submitted for App Review. CloudMount lets users connect supported storage and access it in Apple's Files app. It has no CloudMount account or developer-hosted storage service.

## Features in this source snapshot

- Native WebDAV, S3-compatible, FTP, FTPS and SFTP connections, plus Drime integration.
- Files locations for ordinary remote storage and decrypted Cryptomator vaults.
- Create, discover and unlock standard Cryptomator format 8 vaults; lock and recover them with the user's password and recovery phrase.
- Add, edit, rename, move, read and delete files through Apple's File Provider interface, subject to the provider's permissions and synchronization state.
- Traditional Chinese, Simplified Chinese and English, with English fallback.

The mobile app does not run rclone and does not use macFUSE or NFS. It uses native Apple file-provider APIs and native network clients. The Mac app uses a separate rclone-based implementation; see the repository root for its build instructions.

## Build

Requirements: an Apple Silicon Mac, Xcode 27 or newer, and the Apple Development signing assets for the app and its File Provider extensions. This source does not include certificates or provisioning profiles.

1. Generate the Xcode project: `python3 Mobile/generate-project.py`.
2. Open `Mobile/CloudMountMobile.xcodeproj` in Xcode.
3. Configure your own bundle identifiers, App Group, Keychain groups and development team for the app and both extensions.
4. Resolve the pinned Swift Package Manager dependencies and build the `CloudMountMobile` scheme for an iPhone or iPad simulator/device.

Do not reuse the original developer's signing identity. The app, File Provider and File Provider UI extension must use matching identifiers and entitlements. No build step registers a cloud account or uploads user data.

## Use

1. Add a storage connection in CloudMount. For WebDAV, enter the complete HTTPS folder URL and the provider-issued credentials. For S3, provide the endpoint/service, region, bucket and access keys as required by that service.
2. Enable CloudMount under **Files → Browse → … → Edit** if the system asks.
3. Open the CloudMount location in Files. Vaults are unlocked from CloudMount, then appear as decrypted locations in Files.
4. Wait for uploads to finish before locking a vault or removing a connection. Removing a connection removes local app settings; it does not delete the provider account or remote files.

For Cryptomator compatibility details, see [VAULT_FORMAT.md](../VAULT_FORMAT.md). Third-party licenses and notices are retained under `Vendor/` and `Mobile/Resources/Licenses/`. The bundled `Mobile/Resources/Licenses/LICENSING.md` is preserved as it appeared in build 18; its release-status wording is historical and it is not the repository's license notice.
