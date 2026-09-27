// swift-tools-version: 5.7
import PackageDescription
let package = Package(
    name: "CardinalNativePrototype",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "CardinalNativePrototype", targets: ["CardinalNative"])],
    targets: [
        .systemLibrary(name: "CNative"),
        .executableTarget(name: "CardinalNative", dependencies: ["CNative"], linkerSettings: [
            .linkedLibrary("cardinal_native_prototype"),
            .linkedFramework("CoreServices"), .linkedFramework("CoreFoundation"),
            .linkedFramework("Security"), .linkedLibrary("iconv"), .linkedLibrary("resolv")
        ])
    ]
)
