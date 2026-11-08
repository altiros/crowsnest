// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crowsnest",
    defaultLocalization: "en",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // Kubernetes client: kubeconfig, auth, API, streaming (exec, port-forward), Helm, metrics.
        .library(name: "CrowsnestKit", targets: ["CrowsnestKit"]),
        // Shared SwiftUI interface for macOS and iPadOS, with extension points (`CrowsnestExtension`).
        .library(name: "CrowsnestUI", targets: ["CrowsnestUI"]),
        // The macOS app (open-source build).
        .executable(name: "Crowsnest", targets: ["Crowsnest"]),
        // Developer tools.
        .executable(name: "crowsnest-probe", targets: ["crowsnest-probe"]),
        .executable(name: "crowsnest-streamcheck", targets: ["crowsnest-streamcheck"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        // Terminal emulator. Its build-tool plugin must be trusted once in Xcode ("Trust & Enable").
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.3"),
    ],
    targets: [
        .target(
            name: "CrowsnestKit",
            dependencies: [
                "Yams",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .target(name: "CrowsnestUI", dependencies: ["CrowsnestKit", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "Crowsnest", dependencies: ["CrowsnestUI"]),
        .executableTarget(name: "crowsnest-probe", dependencies: ["CrowsnestKit"]),
        .executableTarget(name: "crowsnest-streamcheck", dependencies: ["CrowsnestKit"]),
        .testTarget(name: "CrowsnestKitTests", dependencies: ["CrowsnestKit"]),
        .testTarget(name: "CrowsnestUITests", dependencies: ["CrowsnestUI"]),
    ]
)
