// swift-tools-version: 6.2
//
// swift-teleport — Teleport client core for Apple platforms.
//
// v0.2.0 adds the gRPC/protobuf transport (`TeleportCore`) plus the
// keyring/coordinators (`TeleportAuth`) and the mocks (`TeleportTesting`);
// see docs/PROVENANCE.md for the import inventory and dependency floors.
//
// `.defaultIsolation(MainActor.self)` on all targets reproduces the host
// app's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting: the
// ported Teleport sources rely on that default to compile under Swift 6
// strict concurrency without per-declaration annotations. See docs/SPEC.md.

import PackageDescription

let package = Package(
    name: "swift-teleport",
    platforms: [
        .iOS("16.1"),
        .macOS("13.3"),
    ],
    products: [
        .library(name: "TeleportCore", targets: ["TeleportCore"]),
    ],
    dependencies: [
        // Floors are at/below the host's resolved set (D7): the host app
        // resolves NIO 2.101.3 / NIOHTTP2 1.46 / NIOTS 1.28 / SwiftProtobuf
        // 1.38.1 today, so these floors stay adoptable in Phase 2.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.34.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.21.0"),
        // 1.38.1 is the version the committed `iotest_mfa.pb.swift` is
        // generated with (bytecode name-map format needs >= 1.28).
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "TeleportCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            // The IDL is the source of the committed `.pb.swift`; SwiftPM
            // must not treat it as an unhandled resource. Target-relative:
            // the proto lives under `Infrastructure/`.
            exclude: ["Infrastructure/iotest_mfa.proto"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "TeleportCoreTests",
            dependencies: ["TeleportCore"],
            // Fixtures are read at runtime via `#filePath`-relative paths (the
            // host convention); excluding them keeps SwiftPM from treating the
            // data as target sources.
            exclude: ["Fixtures"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "TeleportCoreConsumerTests",
            dependencies: ["TeleportCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
