// swift-tools-version: 6.2
//
// swift-teleport — Teleport client core for Apple platforms.
//
// Zero external dependencies in v0.1.0: the walking skeleton ships only the
// package-movable, dependency-closed Teleport client seam + transports. The
// gRPC/protobuf transport, keyring, coordinators, and the WebAuthn/SEP
// machinery arrive in v0.2.0 (see docs/PROVENANCE.md).
//
// `.defaultIsolation(MainActor.self)` on all three targets reproduces the
// host app's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting: the
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
    targets: [
        .target(
            name: "TeleportCore",
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
