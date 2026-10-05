// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "oDisk",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ODiskCore", targets: ["ODiskCore"]),
        .library(name: "ODiskUI", targets: ["ODiskUI"]),
    ],
    targets: [
        .target(
            name: "CODiskSMART",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "ODiskCore",
            dependencies: ["CODiskSMART"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("DiskArbitration")]
        ),
        .target(
            name: "ODiskUI",
            dependencies: ["ODiskCore"],
            resources: [.copy("Resources/ThirdPartyNotices.txt")],
            swiftSettings: [.define("ODISK_DEBUG_HOOKS", .when(configuration: .debug))]
        ),
        .executableTarget(name: "odisk-cli", dependencies: ["ODiskCore"]),
        .testTarget(
            name: "ODiskCoreTests",
            dependencies: ["ODiskCore"]
        ),
    ]
)
