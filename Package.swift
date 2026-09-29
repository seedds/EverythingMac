// swift-tools-version: 5.7
import PackageDescription
let package = Package(
    name: "EverythingMac",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "EverythingMac", targets: ["EverythingMacNative"])],
    targets: [
        .systemLibrary(name: "CNative"),
        .executableTarget(name: "EverythingMacNative", dependencies: ["CNative"], linkerSettings: [
            .linkedLibrary("everything_mac_native_prototype"),
            .linkedFramework("CoreServices"), .linkedFramework("CoreFoundation"),
            .linkedFramework("Security"), .linkedLibrary("iconv"), .linkedLibrary("resolv")
        ])
    ]
)
