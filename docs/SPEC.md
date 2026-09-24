# Specification

## What this package is

`swift-teleport` is the Teleport **client core** for Apple platforms. It owns
the parts of a Teleport client that are pure logic, transport, or state
machinery, with no dependency on an app's UI, storage, or networking stack:

- the OpenSSH SSH-certificate wire-format parser and host-certificate verifier;
- the host-key trust policy;
- the SSH-over-TLS (ALPN `teleport-proxy-ssh`) transport and its TLS trust
  evaluation;
- the `proxy:<node>:<port>[@<cluster>]` subsystem builder;
- the gRPC/protobuf auth transport (HTTP/2 framing + the TLS/ALPN/mTLS dial);
- the WebAuthn/SEP ceremony machinery (CBOR attestation, client data,
  registration/assertion responses, Secure Enclave and software signers);
- the bootstrap/login/registration coordinators, the per-cluster keyring, and
  the web-api HTTP client;
- the **seam protocols** through which a host app supplies its own keychain
  credential store, `os.Logger` factory, and in-app browser presenter;
- the `TeleportTesting` mocks (UI-free, app-type-free).

## Products

| Product | Contents |
| --- | --- |
| `TeleportCore` | domain + transports + gRPC/protobuf + WebAuthn/SEP + wire types + seam protocols |
| `TeleportAuth` | coordinators + keyring + web-api HTTP client |
| `TeleportTesting` | the 7 scripted mocks (`MockSEPKeySigner`, `MockTeleport*`, `MockWebAuthenticationSessionPresenter`) |

Dependency edges: `TeleportTesting → TeleportAuth → TeleportCore`. No
`TeleportCore` file names an `TeleportAuth` symbol (verified per commit by
`swift build`).

## Scope of v0.2.0

`v0.2.0` ships the full client product set D5 describes: the 18-file v0.1.0
skeleton plus the 25 deferred files, the 7 mocks, the committed
`iotest_mfa.pb.swift`, the `iotest_mfa.proto` IDL, and the proto
regeneration script.

Out of scope (host-side by design): the libssh2 channel bridge
(`SSHProxySubsystemTransport` + `SessionMutex`), the host composition root
and adapters, the SwiftUI surfaces and UI-test harnesses, and the host's
`teleport-e2e` / device smoke.

## Dependencies

Declared `from:` at/below the host's resolved set (D7):

| Package | Floor | Why |
| --- | --- | --- |
| `swift-nio` | 2.65.0 | `GRPCClient`/`GRPCTransport` (`NIOCore`, `NIOHTTP1`) |
| `swift-nio-http2` | 1.34.0 | `NIOHTTP2` (the HTTP/2 stream multiplexer) |
| `swift-nio-transport-services` | 1.21.0 | `NIOTransportServices` (the Network.framework TLS dial) |
| `swift-protobuf` | 1.38.1 | the committed `.pb.swift` (bytecode name-map format needs ≥ 1.28) |

The transitive graph (`swift-atomics`, `swift-collections`, `swift-system`)
is Apache-2.0 and listed in [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
The library does not commit `Package.resolved`.

## Platform and toolchain floor

- iOS 16.1+, macOS 13.3+ (arm64).
- **Swift 6.2 / Xcode 26** — required for the SwiftPM `tools-version: 6.2`
  manifest features used here (`.defaultIsolation`), for the
  `swiftLanguageModes: [.v6]` setting, and for the `sec_protocol_metadata_copy_negotiated_protocol`
  API used behind an availability check.

## Swift 6 concurrency

The package builds in **Swift 6 language mode** (`swiftLanguageModes: [.v6]`).

Every target (`TeleportCore`, `TeleportAuth`, `TeleportTesting`, and all
test targets) sets `swiftSettings: [.defaultIsolation(MainActor.self)]`. This
reproduces the host app's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build
setting, under which the imported sources were written: they rely on the
default MainActor isolation to compile without per-declaration annotations.

The host app runs Swift **5** language mode (where the isolation mismatches
below were warnings); this package runs Swift 6 (where they are errors). The
declarations that the default isolation does not cover are marked
`nonisolated`/`@Sendable` explicitly — they are pure functions, thread-safe
`os.Logger` construction, the generated protobuf types, or lock-protected
mutable state. See [`ARCHITECTURE.md`](ARCHITECTURE.md) and
[`PROVENANCE.md`](PROVENANCE.md).

## Privacy

`Sources/TeleportAuth/PrivacyInfo.xcprivacy` is declared as a processed
target resource. `TeleportAuth` is the package's only required-reason API
user: the keyring reads and writes its credential metadata through an
**injected** `UserDefaults` (never `.standard`). The manifest declares
`NSPrivacyAccessedAPICategoryUserDefaults` with reason **`CA92.1`**. No
tracking, no collected data.

## License

MIT. See [`../LICENSE`](../LICENSE) and
[`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
