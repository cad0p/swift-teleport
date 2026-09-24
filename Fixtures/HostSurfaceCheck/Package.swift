// swift-tools-version: 6.2
//
// HostSurfaceCheck — a downstream consumer package that mirrors the Phase 2
// host adoption surface of `swift-teleport`.
//
// This is deliberately a *separate package* that path-depends on the parent:
// `package` access is visible to every target inside the parent package, so an
// in-package consumer test cannot catch a `public` → `package` demotion of a
// host-needed symbol. A sibling package sees only `public` — exactly what the
// Phase 2 host (also a different package) sees.
//
// CI builds this package (`swift build --package-path Fixtures/HostSurfaceCheck`);
// see docs/verification.md §1/§2. The mirrors are compile-only: there is no
// test target here, and the library product is never published.
//
// The target mirrors the parent's isolation settings
// (`.defaultIsolation(MainActor.self)`, Swift 6 language mode) because the
// host app builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; a mirror
// that compiled under different isolation would not prove the host contract.

import PackageDescription

let package = Package(
    name: "HostSurfaceCheck",
    platforms: [
        .iOS("16.1"),
        .macOS("13.3"),
    ],
    dependencies: [
        // `name:` pins the package identity so the checkout directory name
        // (worktree vs CI checkout) cannot change it.
        .package(name: "swift-teleport", path: "../.."),
    ],
    targets: [
        .target(
            name: "HostSurfaceCheck",
            dependencies: [
                .product(name: "TeleportCore", package: "swift-teleport"),
                .product(name: "TeleportAuth", package: "swift-teleport"),
                .product(name: "TeleportTesting", package: "swift-teleport"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
