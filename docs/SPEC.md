# Specification

## What this package is

`swift-teleport` is the Teleport **client core** for Apple platforms. It owns
the parts of a Teleport client that are pure logic or transport, with no
dependency on an app's UI, storage, or networking stack:

- the OpenSSH SSH-certificate wire-format parser and host-certificate verifier;
- the host-key trust policy;
- the SSH-over-TLS (ALPN `teleport-proxy-ssh`) transport and its TLS trust
  evaluation;
- the `proxy:<node>:<port>[@<cluster>]` subsystem builder;
- the **seam protocols** through which a host app supplies its own keychain
  credential store, `os.Logger` factory, and in-app browser presenter.

## Scope of v0.1.0 (walking skeleton)

`v0.1.0` ships the **dependency-closed** subset only. It is deliberately small
so the repo, CI, and release machinery can be stood up and tagged before the
clean-room rewrite of the Teleport-derived files (Phase 1b, `v0.2.0`).

In scope: the 18 files listed in [`PROVENANCE.md`](PROVENANCE.md), exported as
the `TeleportCore` library product.

Out of scope until `v0.2.0`: the gRPC/protobuf transport (SwiftNIO +
SwiftProtobuf), the keyring, the bootstrap/login/registration coordinators, the
WebAuthn/SEP machinery, the `TeleportAuth` and `TeleportTesting` products, and
the committed `.pb.swift` + proto regeneration script.

**Zero external dependencies.** `Package.swift` declares no package
dependencies. This is a hard constraint for `v0.1.0` and the reason the
NIO/protobuf-dependent files are deferred.

## Platform and toolchain floor

- iOS 16.1+, macOS 13.3+ (arm64).
- **Swift 6.2 / Xcode 26** — required for the SwiftPM `tools-version: 6.2`
  manifest features used here (`.defaultIsolation`), for the
  `swiftLanguageModes: [.v6]` setting, and for the `sec_protocol_metadata_copy_negotiated_protocol`
  API used behind an availability check.

## Swift 6 concurrency

The package builds in **Swift 6 language mode** (`swiftLanguageModes: [.v6]`).

All three targets (`TeleportCore`, `TeleportCoreTests`,
`TeleportCoreConsumerTests`) set
`swiftSettings: [.defaultIsolation(MainActor.self)]`. This reproduces the host
app's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting, under which
the imported sources were written: they rely on the default MainActor isolation
to compile without per-declaration annotations.

The host app runs Swift **5** language mode (where the isolation mismatches
below were warnings); this package runs Swift 6 (where they are errors). The
handful of declarations that the default isolation does not cover are marked
`nonisolated` explicitly — they are all pure functions or thread-safe
`os.Logger` construction. See [`ARCHITECTURE.md`](ARCHITECTURE.md) and
[`PROVENANCE.md`](PROVENANCE.md).

## Privacy

`PrivacyInfo.xcprivacy` is included. In `v0.1.0` the package accesses **no**
required-reason APIs: there is no `UserDefaults` access (the
`TeleportKeychainConfig` type holds an injected `UserDefaults` reference but
never calls an API on it), no file-timestamp access, and no collected data.
The manifest therefore declares an empty accessed-API list. The `UserDefaults`
declaration (`CA92.1`) arrives in `v0.2.0` with the keyring.

## License

MIT. See [`../LICENSE`](../LICENSE) and
[`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
