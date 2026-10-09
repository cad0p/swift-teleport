# Test Coverage

`swift test` runs **509 tests** across two frameworks and three targets:

| Target | Framework | Suites | Tests |
| --- | --- | --- | --- |
| `TeleportCoreTests` | Swift Testing | 8 | 144 |
| `TeleportCoreTests` | XCTest | 6 | 84 |
| `TeleportCoreConsumerTests` | Swift Testing | 2 | 10 |
| `TeleportPackageTests` | Swift Testing | 14 | 88 |
| `TeleportPackageTests` | XCTest | 16 | 183 |
| **Total** | | | **509** |

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
| `SSHTLSTransportPumpFDCloserTests` | XCTest | pump-fd single ownership and the #237 shutdown/release split (`shutdownOnce` wakes without freeing, `closeOnce` releases exactly once, fd reuse, join ordering, full-buffer write, large outstanding send (hang regression for the parked-send case), actor-gone release, source tripwire, `SO_NOSIGPIPE`) (10) |
| `TeleportTLSTrustTests` | Swift Testing | `TeleportTLSTrust` (chain/name/EKU/ALPN + DER fail-closed matrix) |
| `TeleportHostLoginTests` | Swift Testing | `TeleportHostLogin` resolver + normalization + failure redaction (21) |
| `TeleportIssuedCertValidatorTests` | Swift Testing | issued-cert binding checks (12) |
| `TeleportCertBindingCoordinatorTests` | Swift Testing | the coordinators store nothing on a cert/key mismatch; keyID binding; the pair-write failure direction (commits nothing and fails the flow) (12) |
| `TeleportWebAuthnRPIDTests` | Swift Testing | rpID resolution through the login coordinator (8) |
| `TeleportCredentialReuseMatcherTests` | Swift Testing | the generalized duplicate-row reuse matcher (9) |
| `TeleportCredentialInvalidationPolicyTests` | Swift Testing | the pure credential clear rule (6) |
| `FixtureTests` | XCTest | the 8 committed Go SEP fixtures, byte-compared (8) |
| `BrowserMFAListenerLoopbackTests` | XCTest | the loopback HTTP contract, including the A4 wait guards/token, the A5 over-cap discard-only drain, the A3 decode boundary, and the D2 complete-header 400 (38) |
| `BrowserMFACeremonyLoopbackURLTests` | XCTest | real non-zero-port loopback URL + teardown + the not-started fail-fast (A7), with the #405 presentation assertions driven through the injected listener stub (4) |
| `BrowserMFACeremonyFailFastPinsTests` | Swift Testing | the #401/#405 listener-seam source pins: no wall clock in the fail-fast/approval-page/redaction ceremony tests, `run` builds through `makeListener(logger)`, the init keeps the production default (5) |
| `MockTeleportBootstrapCoordinatorGateTests` | Swift Testing | the #277 `holdsForApproval`/`releaseApproval` gate seam: default-off, held-until-release, cancel-while-held + per-invocation reset, release-before-begin (4) |
| `ProtoWireCompatTests` | XCTest | golden protobuf wire bytes (12) |
| `WebAuthnResponseJSONTests` | XCTest | registration/assertion response JSON (7) |
| `HeadlessLoginWireTests` | XCTest | `HeadlessLogin.post` (URL/200-only/error mapping) + coordinator failure paths (16) |
| `TeleportLoginWireTests` | XCTest | `LoginFinishReq` v16/v17 field compat (1) |
| `SEPSignerAlgorithmTests` | XCTest | signer algorithm/label contract + nested SEP key attributes + the token-scoped load query (SEP-1) and the load-always-queries source pin (SEP-2) (4) |
| `TeleportFrozenTextTests` | XCTest | frozen error texts + listener defaults wiring + OSStatus signer classification (16) |
| `TeleportRedactionTests` | XCTest | log redaction (source-level privacy pin + runtime + listener rejection reasons) (18) |
| `TeleportLoginClientErrorShapeTests` | XCTest | real-client structured login errors over loopback (incl. the decode boundary), coordinator `.server`/`.unknown` mapping, and the packing tripwire (9) |
| `TeleportBootstrapCoordinatorTimeoutTests` | XCTest | timeout classification + wrapped-cancel asymmetry (10) |
| `TeleportBootstrapCoordinatorGenerationTests` | XCTest | stale-continuation request-generation guards; the dismissal latch (drops a parked POST success, terminal for retry/begin, clear/pair-write re-takes); the atomic pair write (supersession cannot tear, one pair/zero singles, the post-throw D4 states, the snapshot-read re-take) (16) |
| `TeleportSynchronousReleaseTests` | XCTest | isolated-deinit synchronous release (1) |

## New package-local suites

| Suite | Framework | Subject |
| --- | --- | --- |
| `TeleportKeyRingTests` | Swift Testing | keyring persistence through an injected `UserDefaults`; readiness; additions-only Host CA refresh; certExpiry parse; the atomic pair write's round-trip/policy semantics and failure direction (hermetic via the injected keychain-writer seam) + the real-writer seeded-item round trip (14) |
| `TeleportKeyRingReuseTests` | Swift Testing | the real keyring's reuse helpers (completeness, seeding) + the mock's key/cert non-copy (5) |
| `TeleportKeyRingInvalidationConformanceTests` | Swift Testing | `TeleportCredentialInvalidating` on the real keyring (2) |
| `TeleportCredentialPairPinsTests` | Swift Testing | source pins for the atomic pair write: one pair call per coordinator, the keyring pair body (non-async, key-first, suspend-free), the adapter's one-hop `MainActor.run`, and the real writer's update-first/non-destructive body (4) |
| `TeleportNIOCoreLinkPinsTests` | Swift Testing | the swift-teleport#66 link pin: `Sources/` names neither `readableBytesView` nor `ContiguousBytes` (comments stripped; the `GRPCClient.swift` coverage guard keeps the scan honest), and `GRPCClient` copies the readable bytes through NIOCore's `getBytes(at:length:)` (1) |
| `TeleportLoginCoordinatorGenerationTests` | XCTest | the login request-generation guards (stale success/failure/cancel cannot land, the #298 per-site re-takes, the dismissal latch) and the atomic pair write: a superseded pair write cannot tear, one pair/zero singles, and the post-throw D4 states (20) |
| `TeleportBootstrapCoordinatorRetryTests` | Swift Testing | the #267 retry contract: `retry()` re-runs `begin` (fresh POST + Safari), can reach `.success`, and no-ops without a prior `begin` (3) |
| `SSHTLSTransportReadyWaiterTests` | Swift Testing | the #237 `ReadyWaiter` pre-`start` arm (host has no such suite): fast-`.ready`/failure buffering, first-terminal-wins, the second-concurrent-wait guard, and the arm-before-`start` source pin (6) |
| `MockWebAuthenticationSessionPresenterHelperTests` | Swift Testing | the #267 mock Safari helpers: `liveSessionCount` (no cancel-before-replace) and the bounded `waitUntilOpenStarted` (2) |
| `TeleportDismissalTests` | XCTest | the exhaustive `dismissalRequiresTeardown` maps for both coordinator states + the login latch-while-the-pair-write-is-parked pair-lands-complete test (3) |
| `TeleportCoordinatorSmokeTests` | Swift Testing | the three real coordinators against `TeleportTesting` mocks (3) |
| `PublicSeamSmokeTests` | Swift Testing | the non-`@testable` v0.1.0 seam (8) |

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
suites. The #262 additions stay host-side for the same reason:
`ServerManagerTeleportHostLoginTests`, the host's `TeleportHostLoginTests`
(minus the resolver matrix, which moved here), `TeleportCredentialReuseTests`
(the `Server` half), `TeleportCredentialInvalidationTests` (the
`ServerManager` wiring half), `TeleportBootstrapViewWiringTests`, and
`SSHErrorDiagnosticsTests`. The dismissal view wiring stays host-side too:
`TeleportLoginDismissalWiringTests`'s `UIHostingController` tests and the two
view source pins (the package has no UI target); the coordinator-level latch
semantics and both state maps are ported in `TeleportDismissalTests`.

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
