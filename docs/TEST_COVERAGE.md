# Test Coverage

`swift test` runs **319 tests** across two frameworks and three targets:

| Target | Framework | Suites | Tests |
| --- | --- | --- | --- |
| `TeleportCoreTests` | Swift Testing | 6 | 116 |
| `TeleportCoreTests` | XCTest | 4 | 68 |
| `TeleportCoreConsumerTests` | Swift Testing | 2 | 8 |
| `TeleportAuthTests` | Swift Testing | 4 | 27 |
| `TeleportAuthTests` | XCTest | 11 | 100 |
| **Total** | | | **319** |

## Ported suites (from `cad0p/vvterm`)

| Suite | Framework | Subject |
| --- | --- | --- |
| `HostKeyTrustPolicyTests` | Swift Testing | `HostKeyTrustPolicy` (pure trust decision) |
| `OpenSSHCertificateTests` | Swift Testing | `OpenSSHCertificate` (wire-format parser) |
| `OpenSSHHostCertVerifierTests` | Swift Testing | `OpenSSHHostCertVerifier` (Host CA verification) |
| `TeleportClusterTests` | XCTest | `TeleportCluster` (`sepKeyLabel`, Codable, Hashable) |
| `TeleportCredentialTests` | XCTest | `TeleportCredential` (`isCertValid`, Codable) |
| `TeleportDeviceNameTests` | XCTest | `TeleportDeviceName` (sanitization + validation) |
| `TeleportDeviceReadinessTests` | XCTest | `TeleportDeviceReadinessResolver` (readiness matrix) |
| `TeleportProxySubsystemTests` | Swift Testing | `TeleportProxySubsystem.request` |
| `SSHTLSTransportTests` | Swift Testing | `SSHTLSTransport` (ALPN, TLS options, socketpair, real loopback handshake) |
| `TeleportTLSTrustTests` | Swift Testing | `TeleportTLSTrust` (chain/name/EKU/ALPN + DER fail-closed matrix) |
| `TeleportIssuedCertValidatorTests` | Swift Testing | issued-cert binding checks (11) |
| `TeleportWebAuthnRPIDTests` | Swift Testing | rpID resolution through the login coordinator (8) |
| `FixtureTests` | XCTest | the 8 committed Go SEP fixtures, byte-compared (8) |
| `BrowserMFAListenerLoopbackTests` | XCTest | the loopback HTTP contract (27) |
| `BrowserMFACeremonyLoopbackURLTests` | XCTest | real non-zero-port loopback URL + teardown (3) |
| `ProtoWireCompatTests` | XCTest | golden protobuf wire bytes (12) |
| `WebAuthnResponseJSONTests` | XCTest | registration/assertion response JSON (7) |
| `HeadlessLoginWireTests` | XCTest | `HeadlessLogin.post` (URL/200-only/error mapping) + coordinator failure paths (16) |
| `TeleportLoginWireTests` | XCTest | `LoginFinishReq` v16/v17 field compat (1) |
| `SEPSignerAlgorithmTests` | XCTest | signer algorithm/label contract (1) |
| `TeleportFrozenTextTests` | XCTest | frozen error texts + listener defaults wiring (10) |
| `TeleportRedactionTests` | XCTest | log redaction (source-level privacy pin + runtime) (6) |
| `TeleportBootstrapCoordinatorTimeoutTests` | XCTest | timeout classification (9) |

## New package-local suites

| Suite | Framework | Subject |
| --- | --- | --- |
| `TeleportKeyRingTests` | Swift Testing | keyring persistence through an injected `UserDefaults`; readiness; additions-only Host CA refresh (5) |
| `TeleportCoordinatorSmokeTests` | Swift Testing | the three real coordinators against `TeleportTesting` mocks (3) |
| `PublicSeamSmokeTests` | Swift Testing | the non-`@testable` v0.1.0 seam (7) |
| `HostSurfaceCompileTests` | Swift Testing | the compile-only Phase-2 host contract (1) |

## Consumer smoke test

`TeleportCoreConsumerTests` imports the products **without `@testable`** and
exercises the public seam + the host adoption mirrors. It fails to compile if
the seam regresses.

## Kept host-side

Their subjects are host adapters/UI and run against the package in Phase 2:
`TeleportGRPCClientConnectionTests` (tests `LiveTeleportGRPCClient`),
`TeleportLoggingSeamTests` (tests `LiveTeleportGRPCClient`/`AppTeleportLogging`),
`TeleportCertBindingCoordinatorTests`, `TeleportHostKeyPersistenceTests`,
`TeleportCredentialStoreTests`, `TeleportCompositionTests`,
`TeleportBootstrapViewWiringTests`, `TeleportErrorMappingTests`,
`TeleportServerIntegrationTests` (e2e), `AuthMethodTests`,
`TeleportServerModelTests`, `TeleportValidityCopyTests`, and the UI-test
suites.

## Reworked during the port

- `TeleportFixtureSupport` (AuthTests) re-adds the fixture-bound factories the
  host's `MockTeleportHTTPClient` used to carry (`fixedTLSKeyPair`,
  `makeFixtureSuccessResponse`, `makeFixtureLoginFinishResponse`, the fixed
  generators).
- Source-level pin tests (`TeleportRedactionTests`, `TeleportFrozenTextTests`,
  `HeadlessLoginWireTests`) resolve the package root and the
  `Sources/TeleportCore|TeleportAuth/...` paths.
- XCTest suites are `nonisolated final class` with `@MainActor` test methods
  (the target's `.defaultIsolation(MainActor.self)` cannot apply to the
  class's inherited nonisolated initializers).
- `HeadlessLoginWireTests`' loopback server + URLProtocol stub are
  `nonisolated` + lock-guarded (Swift 6).

## Hermeticity

No network, no real Teleport server, no production secrets. The loopback TLS
tests run an in-process `NWListener` against generated test identities; the
SEP fixtures are committed Go-generated data; all other suites are pure logic
over committed fixtures.
