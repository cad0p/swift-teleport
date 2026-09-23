# Provenance

## Import source

All files under `Sources/TeleportCore/` were imported from
[`cad0p/vvterm`](https://github.com/cad0p/vvterm) at commit `a18a77b4`
("chore: sweep fork-new AGPL headers to MIT + Teleport-derived carve-out
(package extraction Phase 0c)"), the post-hardening Teleport client.

The import preserves file content except for:

1. **Access-level promotion** — the D6 seam protocols, the transports, and
   every type reachable from their public signatures are now `public`
   (the package's contract). Model internals stay `internal`.
2. **Minimal Swift 6 diagnostics** — the host app builds these files in Swift
   **5** language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; this
   package builds them in Swift **6** language mode with
   `.defaultIsolation(MainActor.self)`. The handful of declarations the
   default isolation does not cover are marked `nonisolated` (see below).

Nothing else changed.

## Imported set (18 files)

| Path | Origin |
| --- | --- |
| `Domain/BrowserMFAPresenting.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/HostKeyTrustPolicy.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/OpenSSHCertificate.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/OpenSSHHostCertVerifier.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportChannelTransport.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportCluster.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportClusterTLSState.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportCredential.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportCredentialStore.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportDeviceName.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportDeviceReadiness.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportKeychainConfig.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportLogging.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportPackageError.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Application/SSHCertExpiryParser.swift` | `VVTerm/Features/Teleport/Application/` |
| `Infrastructure/SSHTLSTransport.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/TeleportProxySubsystem.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/TeleportTLSTrust.swift` | `VVTerm/Features/Teleport/Infrastructure/` |

### Inclusion criterion

Every imported file is consumed by another imported file or by a host-side file
that will import the package in Phase 2:

- `SSHTLSTransport`, `SSHCertExpiryParser`, `TeleportProxySubsystem` by the host
  `SSHSession` / seam bridge;
- `TeleportTLSTrust` by `SSHTLSTransport` in-package;
- the seam protocols by the host composition root.

`TeleportWebAuthnRPID` was **in the plan's 19-file list but fails the
criterion**: its only consumers are the deferred login/registration
coordinators (and its own test), with no host-side Phase-2 consumer. It is
therefore deferred, making the skeleton **18 files**. This is the plan's
W4 inclusion criterion applied as written — it defers any file whose only
consumers are deferred.

## Deferred set (25 files)

### Teleport-derived — Phase 1b clean-room rewrite gate (9)

These files are Go ports/adaptations of Teleport source and carry
`AGPL-3.0-or-later` in the host. They **must not** enter this MIT package until
a clean-room rewrite lands (Phase 1b, `v0.2.0`); the byte-exact Go-generated
fixtures are the oracle.

- `HeadlessID`, `HeadlessLogin`
- `BrowserMFAListener`, `BrowserMFACeremony`
- `SEPWebAuthn/{Attestation, Signer, WebAuthn, SecureEnclaveSigner}`
- `iotest_mfa.pb.swift` (and the `iotest_mfa.proto` IDL + regen script, per D8)

### Cascade (8)

Dependency-closed but only reachable through the deferred derived files:

- `TeleportBootstrapCoordinator`, `TeleportLoginCoordinator`,
  `TeleportRegistrationCoordinator`
- `TeleportInfrastructureProtocols`, `TeleportKeyRing`
- `MFALoginWireTypes`, `TeleportHTTPClient`
- `SEPWebAuthn/SoftwareSigner`

### No consumer / NIO + protobuf (4)

- `GRPCClient`, `GRPCTransport` — need SwiftNIO + SwiftProtobuf
- `SEPWebAuthn/CBOR`, `SEPWebAuthn/SSHPubKey` — no consumer in the core

`v0.1.0` is intentionally **zero-dependency**; the NIO/protobuf files arrive
with the `v0.2.0` gRPC mapping.

### Deferred consumer (4)

Consumed only by deferred files (or by the host UI):

- `TeleportWebAuthnRPID` — deferred coordinators
- `TeleportTrustSession` — deferred consumers
- `TLSKeyPair` — deferred bootstrap coordinator
- `TeleportIssuedCertValidator` — deferred coordinators + its own test

`TeleportIssuedCertValidatorTests` is deferred with its subject: it needs
`TLSKeyPair` plus the excluded `TeleportSSHKeyPairGenerating` protocol.

### Host-side by design (not part of the package)

- `SSHProxySubsystemTransport` — the libssh2 channel bridge (14 libssh2 calls +
  `SessionMutex`); exposed to the package only through
  `TeleportChannelTransportFactory` (D6).
- `UI/*`, `UITesting/*` — the app's SwiftUI surfaces and UI-test mocks.

## Swift 6 changes (minimal, behavior-preserving)

| Declaration | Change | Why |
| --- | --- | --- |
| `TeleportTLSTrust` (enum) | `nonisolated` | pure-function enum; called from `SSHTLSTransport`'s nonisolated statics |
| `TeleportLogging.logger(category:)` | `nonisolated` | `os.Logger` construction is thread-safe; requested from the transport actor |
| `DefaultTeleportLogging.logger(category:)` | `nonisolated` | protocol witness |

The host app runs Swift 5 language mode, where these were warnings; the package
runs Swift 6, where they are errors. No behavior changed.

Three imported files carry no SPDX line because they carried none upstream
(`TeleportCluster.swift`, `TeleportCredential.swift`,
`TeleportDeviceReadiness.swift`). The package-level `LICENSE` (MIT) governs;
no file carries an AGPL marker.

## Fixtures

`Tests/TeleportCoreTests/Fixtures/` is imported from
`VVTermTests/Features/Teleport/Fixtures/` at the same commit. The material is
**test-only, generated, public**: OpenSSH CA/host/user certs + keys, generated
loopback TLS identities (PKCS#12 + PEM) with the well-known test password, and
captured public certificate chains. No production secret is present. Fixtures
are read at runtime via `#filePath`-relative paths (the host convention) and are
declared `exclude` in `Package.swift` so SwiftPM does not treat them as target
sources.

## Phase 1b gate

The 9 Teleport-derived files above must be rewritten clean-room (specs: W3C
WebAuthn L2, CTAP2 canonical CBOR, RFC 9562 UUIDv5, OpenSSH authorized_keys,
the public Teleport client API contract; oracle: the byte-exact Go-generated
fixtures) before they can be imported into this MIT package. The remaining
deferred files are then imported alongside them, together with `TeleportTesting`
and the proto/regen script, cutting `v0.2.0`.
