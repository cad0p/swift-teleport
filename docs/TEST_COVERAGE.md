# Test Coverage

`swift test` runs **191 tests** across two frameworks and two targets:

| Target | Framework | Suites | Tests |
| --- | --- | --- | --- |
| `TeleportCoreTests` | Swift Testing | 6 | 116 |
| `TeleportCoreTests` | XCTest | 4 | 68 |
| `TeleportCoreConsumerTests` | Swift Testing | 1 | 7 |
| **Total** | | **11** | **191** |

## Ported suites (from `cad0p/vvterm` @ `a18a77b4`)

| Suite | Tests | Subject |
| --- | --- | --- |
| `HostKeyTrustPolicyTests` | 7 | `HostKeyTrustPolicy` (pure trust decision) |
| `OpenSSHCertificateTests` | 19 | `OpenSSHCertificate` (wire-format parser) |
| `OpenSSHHostCertVerifierTests` | 20 | `OpenSSHHostCertVerifier` (Host CA verification) |
| `TeleportClusterTests` | 13 | `TeleportCluster` (`sepKeyLabel`, Codable, Hashable) |
| `TeleportCredentialTests` | 12 | `TeleportCredential` (`isCertValid`, Codable) |
| `TeleportDeviceNameTests` | 27 | `TeleportDeviceName` (sanitization + validation) |
| `TeleportDeviceReadinessTests` | 16 | `TeleportDeviceReadinessResolver` (readiness matrix) |
| `TeleportProxySubsystemTests` | 10 | `TeleportProxySubsystem.request` |
| `SSHTLSTransportTests` | 13 | `SSHTLSTransport` (ALPN, TLS options, socketpair, real loopback handshake) |
| `TeleportTLSTrustTests` | 47 | `TeleportTLSTrust` (chain/name/EKU/ALPN + DER fail-closed matrix) |

## Consumer smoke test

`TeleportCoreConsumerTests/PublicSeamSmokeTests` (7 tests) imports
`TeleportCore` **without `@testable`** and exercises the public seam:
`TeleportProxySubsystem.request`, `SSHTLSTransport.alpnProtocol` /
`offeredALPNProtocols`, `DefaultTeleportLogging`, `TeleportPackageError`
descriptions, `TeleportClusterTLSState` construction/hashability,
`TeleportHostKeyUpdateResult`, and the `TeleportTLSTrust` name/anchor helpers.
It fails to compile if the seam regresses.

## Dropped / deferred suites

- **Not portable (host subjects), dropped**: `TeleportServerModelTests`
  (constructs the host `Server`), `TeleportValidityCopyTests`
  (`TeleportValidityCopy` lives in the host UI `TeleportLoginView.swift`).
- **Deferred with their subjects**: `TeleportIssuedCertValidatorTests` (needs
  the deferred `TLSKeyPair` + the excluded generator protocol),
  `TeleportWebAuthnRPIDTests` and `TeleportGRPCClientConnectionTests` (deferred
  subjects), `FixtureTests` (deferred SEP fixtures), plus the coordinator /
  composition / logging-seam / host-key-persistence suites.
- **Host-only**: the `teleport-e2e` integration legs, the UI tests, and the
  device smoke test stay in `cad0p/vvterm`.

## Reworked during the port

- `TeleportFixtureSupport`: the three `MockTeleportHTTPClient` fixture
  constants it re-exported (`fixtureClock`, `fixedSSHPublicKey`,
  `fixedIssuedUserCert`) are inlined; the two fixed keypair generators and
  their classes were dropped (they conform to the excluded
  `TeleportSSHKeyPairGenerating` / `TeleportTLSKeyPairGenerating` protocols).
- `SSHTLSTransportTests`' error-mapping test asserted the host's
  `SSHError` via `TeleportErrorMapping`; it now asserts only the package's
  `TeleportPackageError` (the host-side mapping is covered in the host repo).
- `TeleportTLSTrustTests` / `LoopbackTLSServerTestSupport` fixture paths
  resolve relative to the package test directory.
- The four XCTest suites are declared `nonisolated final class` with
  `@MainActor` test methods: `XCTestCase`'s inherited initializers are
  nonisolated, so the target's `.defaultIsolation(MainActor.self)` cannot apply
  to the class itself.
- `LoopbackTLSServer`'s `newConnectionHandler` hops to the main actor
  (`@Sendable` closure mutating a MainActor-isolated property).

## Hermeticity

No network, no real Teleport server, no production secrets. The loopback TLS
tests run an in-process `NWListener` against generated test identities; all
other suites are pure logic over committed fixtures.
