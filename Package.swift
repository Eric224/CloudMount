// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CloudMount",
    platforms: [.macOS("26.0"), .iOS(.v17)],
    products: [.library(name: "CloudMountVaultCore", targets: ["CloudMountVaultCore"]),
               .library(name: "CloudMountMobileCore", targets: ["CloudMountMobileCore"]),
               // One shared mobile framework avoids Xcode promoting transitive package products
               // independently when the app, extensions and hosted tests share the same modules.
               .library(name: "CloudMountMobileRuntime", type: .dynamic, targets: ["CloudMountMobileCore", "CloudMountVaultCore", "CloudMountLocalization"]),
               .executable(name: "CloudMountVaultHelper", targets: ["CloudMountVaultHelper"]),.executable(name: "CloudMount", targets: ["CloudMount"]),
               .executable(name: "CloudMountHelper", targets: ["CloudMountHelper"])],
    dependencies: [.package(path: "Vendor/CryptomatorCryptoLib"),
                   .package(path: "Vendor/Citadel"),
                   .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5")],
    targets: [
        .target(name: "CloudMountLocalization"),
        .target(name: "CloudMountVaultCore", dependencies: [.product(name: "CryptomatorCryptoLib", package: "CryptomatorCryptoLib")], resources: [.process("Resources")]),
        .target(name: "CloudMountMobileCore", dependencies: ["CloudMountVaultCore", "CloudMountLocalization", .product(name: "Citadel", package: "Citadel"), .product(name: "NIOSSL", package: "swift-nio-ssl")]),
        .testTarget(name: "CloudMountMobileCoreTests", dependencies: ["CloudMountMobileCore", "CloudMountLocalization"]),
        .executableTarget(name: "CloudMountVaultHelper", dependencies: ["CloudMountVaultCore"]),
        .executableTarget(name: "CloudMount", dependencies: ["CloudMountVaultCore", "CloudMountLocalization"]),
        .executableTarget(name: "CloudMountHelper"),
        .testTarget(name: "CloudMountTests", dependencies: ["CloudMount", "CloudMountVaultCore"], resources: [.copy("Fixtures")])
    ]
)
