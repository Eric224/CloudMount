# Corresponding source: iOS/iPadOS 0.4.12 (18)

This source snapshot corresponds to the 0.4.12 (18) submission. The iPhone/iPad app uses native transports and standard Cryptomator format 8; it does not execute rclone, macFUSE or NFS.

## Build

Use Xcode 27 (the version used for this submitted snapshot) and Swift Package Manager. Dependencies are pinned in Package.resolved; locally vendored dependencies and their license texts are in Vendor/. Run `python3 Mobile/generate-project.py`, open `Mobile/CloudMountMobile.xcodeproj`, select CloudMountMobile, and use your own Apple development team, identifiers, App Group and Keychain entitlements. No signing key or provisioning profile is included. Do not assume the original developer's identifiers authorize your own build.

For the Mac engine, `python3 Engine/build-engine.py /path/to/go` downloads the exact pinned rclone source, verifies its checksum, applies the checked-in patch and builds Resources/CloudMountRclone. The precompiled engine is intentionally not committed. Then run build-app.sh and package-dmg.sh with your own signing setup if desired.

## Publication hygiene

Only source/build inputs and necessary vendored notices are included. App binaries, user configurations, cloud credentials, signing assets, review credentials, real-device recordings and personal App Store metadata are excluded. The owner's NAS hostname in development-only physical tests was replaced by nas.example.test; two development fixture cache paths use /Users/example. App runtime source is unchanged.

CloudMount-authored source in this repository is licensed under AGPL-3.0-only. The pinned third-party dependencies retain their own licenses. This source release does not represent legal advice or a determination that the App Store's EULA and distribution terms are compatible with AGPL.
