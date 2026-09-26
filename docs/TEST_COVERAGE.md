# Test Coverage

`swift test` runs **359 tests** across two frameworks and three targets:

| Target | Framework | Suites | Tests |
| --- | --- | --- | --- |
| `TeleportCoreTests` | Swift Testing | 6 | 116 |
| `TeleportCoreTests` | XCTest | 6 | 75 |
| `TeleportCoreConsumerTests` | Swift Testing | 1 | 7 |
| `TeleportPackageTests` | Swift Testing | 5 | 37 |
| `TeleportPackageTests` | XCTest | 13 | 124 |
| **Total** | | | **359** |

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
| `HeadlessIDTests` | XCTest | `HeadlessID.compute` UUIDv5 golden vectors (4) |
| `TeleportProxySubsystemTests` | Swift Testing | `TeleportProxySubsystem.request` |
| `SSHTLSTransportTests` | Swift Testing | `SSHTLSTransport` (ALPN, TLS options, socketpair, real loopback handshake) (13) |
| `SSHTLSTransportPumpFDCloserTests` | XCTest | pump-fd single ownership (fd reuse, source tripwire, `SO_NOSIGPIPE`) (3) |
| `TeleportTLSTrustTests` | Swift Testing | `TeleportTLSTrust` (chain/name/EKU/ALPN + DER fail-closed matrix) |
| `TeleportIssuedCertValidatorTests` | Swift Testing | issued-cert binding checks (11) |
| `TeleportCertBindingCoordinatorTests` | Swift Testing | the coordinators store nothing on a cert/key mismatch (10) |
| `TeleportWebAuthnRPIDTests` | Swift Testing | rpID resolution through the login coordinator (8) |
| `FixtureTests` | XCTest | the 8 committed Go SEP fixtures, byte-compared (8) |
| `BrowserMFAListenerLoopbackTests` | XCTest | the loopback HTTP contract (27) |
| `BrowserMFACeremonyLoopbackURLTests` | XCTest | real non-zero-port loopback URL + teardown (3) |
| `ProtoWireCompatTests` | XCTest | golden protobuf wire bytes (12) |
| `WebAuthnResponseJSONTests` | XCTest | registration/assertion response JSON (7) |
| `HeadlessLoginWireTests` | XCTest | `HeadlessLogin.post` (URL/200-only/error mapping) + coordinator failure paths (16) |
| `TeleportLoginWireTests` | XCTest | `LoginFinishReq` v16/v17 field compat (1) |
| `SEPSignerAlgorithmTests` | XCTest | signer algorithm/label contract + nested SEP key attributes (2) |
| `TeleportFrozenTextTests` | XCTest | frozen error texts + listener defaults wiring + OSStatus signer classification (14) |
| `TeleportRedactionTests` | XCTest | log redaction (source-level privacy pin + runtime + listener rejection reasons) (16) |
| `TeleportBootstrapCoordinatorTimeoutTests` | XCTest | timeout classification + wrapped-cancel asymmetry (10) |
| `TeleportBootstrapCoordinatorGenerationTests` | XCTest | stale-continuation request-generation guards (7) |
| `TeleportSynchronousReleaseTests` | XCTest | isolated-deinit synchronous release (1) |

## New package-local suites

| Suite | Framework | Subject |
| --- | --- | --- |
| `TeleportKeyRingTests` | Swift Testing | keyring persistence through an injected `UserDefaults`; readiness; additions-only Host CA refresh (5) |
| `TeleportCoordinatorSmokeTests` | Swift Testing | the three real coordinators against `TeleportTesting` mocks (3) |
| `PublicSeamSmokeTests` | Swift Testing | the non-`@testable` v0.1.0 seam (7) |

## Consumer smoke test

`TeleportCoreConsumerTests` imports the products **without `@testable`** and
exercises the public seam. It fails to compile if the seam regresses to
`internal`, but it cannot catch a `public` → `package` demotion (`package`
access is visible to every target in this package). That check is the sibling
fixture package `Fixtures/HostSurfaceCheck`, built in CI.

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
