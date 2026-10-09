# Verification

The `/impl` verification checklist for `swift-teleport`. Run the narrowest
gate that exercises the change; report the exact commands and results.

## 1. CI gates and what "green" means

| Check | Job | Green means |
| --- | --- | --- |
| `headers` | ubuntu | No tracked file carries the AGPL SPDX marker; no `Sources/` file (every target) references a host symbol (`SSHError`, `KeychainError`, `Logger.forCategory`, `UserDefaults.standard`, `AuthMethod`, `TeleportKeyRing.shared`, `app.vivy.vvterm`, `SessionMutex`, `TeleportKeyRingStoring`) |
| `macos` | macos-26 | `swift test` (which builds the package) passes on macOS arm64 in Swift 6 language mode; the iOS-simulator `xcodebuild build` succeeds; the cross-package host-surface fixture (`Fixtures/HostSurfaceCheck`) builds in **debug and release** |
| `validate-package-version` | ubuntu | the `package.json` version bump matches the change class (semver-calver) |
| `validate-release-pr` | ubuntu | a `release/from-v*` PR bumps the version from the last released base; non-release branches skip |

All four jobs must be green on the PR head and are required on the `main`
ruleset.

## 2. Offline gates (run before pushing)

```bash
swift build
swift build -c release          # proves TeleportTesting builds without #if DEBUG
swift test
swift build --package-path Fixtures/HostSurfaceCheck   # cross-package public-surface gate
swift build -c release --package-path Fixtures/HostSurfaceCheck  # release surface (the host ships release)
python3 -B scripts/ci/check-package-boundaries.py
python3 -B scripts/ci/check-package-boundaries.py --selftest
xcodebuild build -scheme swift-teleport-Package \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: build clean (no warnings), **486 tests** pass (267 XCTest + 219
Swift Testing across `TeleportCoreTests` + `TeleportCoreConsumerTests` +
`TeleportPackageTests`), fixture package builds, boundary check OK, selftest OK,
iOS build succeeds. The split is read from `swift test`'s output: the XCTest
count from the `Executed <n> tests` line and the Swift Testing count from the
`Test run with <n> tests in <m> suites` line.

## 3. Independent-review protocol

Every non-trivial change gets at least one review lens before merge. The lens
set is phase-aware:

- **Migration phase** (code still being ported/imported from the host):
  **architecture** (ownership boundaries, public-seam surface, Swift 6
  isolation), **behavior/parity** (does the change preserve the ported
  behavior against the host implementation?), and **packaging** (provenance,
  licensing, boundary gates).
- **Post-migration** (the package is the source of truth): the
  behavior/parity lens retires — there is no host implementation left to
  compare against, and the ported suites and fixtures are the behavior
  oracle. Its security-relevant half becomes the first-class **security
  lens**: trust chain (TLS anchors/ALPN/hostname), host-certificate
  verification, the WebAuthn/SEP ceremony, key custody, fail-closed paths,
  and log redaction — reviewed against the fixtures that pin them. The lens
  set is **architecture + security + packaging**.

This file is living: a change that alters a gate (a new suite, a new
fail-closed path, a new job) updates the corresponding section in the same PR,
and the reviewer checks the PR's evidence against it. Findings are fixed in
follow-up commits on the same branch; the PR description records the rounds.

## 4. Live-proof checklist per change type

### Package source change
- `swift test` green; the boundary check green.
- If a public signature changed: `swift build --package-path Fixtures/HostSurfaceCheck`
  still compiles — in **both** configurations (`-c release` too, because the
  host app ships the package in release and a symbol that is `public` only
  under `#if DEBUG` would pass the debug build). That fixture is a **separate package** that path-depends on
  this one, so it sees only `public` — exactly what the Phase 2 host (also a
  different package) sees. The in-package `TeleportCoreConsumerTests`
  (`PublicSeamSmokeTests`) is a non-`@testable` smoke test of the public seam,
  but it cannot fail on a `public` → `package` demotion: `package` access is
  visible to every target inside this package. The fixture package is the
  fail-closed gate.

### Transport / TLS change
- `TeleportTLSTrustTests` + `SSHTLSTransportTests` (including the pump-fd
  single-ownership guard) + `SSHTLSTransportPumpFDCloserTests` green.
  `SSHTLSTransportPumpFDCloserTests` covers the #234 fd-reuse `dup2` guard, the
  source tripwire, and the `SO_NOSIGPIPE` SIGPIPE counterfactual, plus the
  #237 shutdown/release split: `shutdownOnce` wakes without freeing the number
  (read EOF / write EPIPE, still open), `closeOnce` after shutdown releases
  exactly once, a stale `shutdownOnce` after `closeOnce` leaves a `dup2`-reused
  descriptor fully writable, a cancelled `writeAllToPumpFD` escapes a full
  socketpair buffer within a bounded deadline, `close()` releases the pump fd
  with a large outstanding send (hang regression for the parked-send case) and
  after the actor is released, a
  full-buffer write is unblocked by `shutdownOnce`, and the lexical pins hold
  `runPump`'s wake-before-join/release-after-join ordering, the two-argument
  `closeOnce` call-site allowlist, and the in-lock syscalls. Also green: the
  loopback handshake and the fail-closed DER matrix.
- Re-check the `nonisolated` markers on `TeleportTLSTrust` and
  `TeleportLogging` if isolation changed, and — when `SSHTLSTransport`,
  `PumpFDCloser`, or any coordinator/generator/keyring class is touched — that
  `PumpFDCloser` stays `nonisolated final class` and the touched class keeps
  its `nonisolated deinit {}`. `TeleportSynchronousReleaseTests` traps at exit
  without the deinit markers.

### gRPC / protobuf change
- `ProtoWireCompatTests` green (the golden bytes are the wire contract).
- Regenerate with `scripts/regen-iotest-mfa.sh` (pinned `protoc 36.2` +
  `protoc-gen-swift 1.38.1`) and commit the `.pb.swift` with the IDL.

### WebAuthn / SEP change
- `FixtureTests` (8) green — the byte-exact Go oracle; an absent fixture is a
  hard failure, never a skip.
- `SEPSignerAlgorithmTests` + `WebAuthnResponseJSONTests` green. The SEP rows
  now also pin the restored load semantics: the whole token-scoped
  `loadKeyQuery` dictionary (SEP-1) and the source pin that `loadKey` always
  queries while only `sign` reads the cache (SEP-2). SEP-3's behavioural
  software-key test was dropped after its positive control measured
  `errSecItemNotFound` for the supplied 32-byte label (the macOS keychain
  stores a 20-byte label hash), so the dictionary pin is the honest ceiling;
  the device smoke stays owner-gated (residual, never a claim).

### Listener / browser-MFA change
- `BrowserMFAListenerLoopbackTests` green — the loopback HTTP contract plus the
  restored shapes: the A4 double-wait guards and per-wait cancellation token,
  the A5 over-cap discard-only drain (wait-for-header, split-terminator,
  no-slot, size-bound, and the never-buffers source pin), the A3 decode
  boundary (a missing required field is terminal; unparseable base64 still
  degrades), and the D2 complete-header 400. The drain's source pin is a
  formatting tripwire: re-verify the discard-only property when
  restructuring.
- The redaction and frozen-text pins stay in force for this surface:
  `TeleportRedactionTests` (`TeleportRedactionTests.swift:508-598`: the
  listener rejection-reason hygiene and the source-level privacy pin) and
  `TeleportFrozenTextTests` (`TeleportFrozenTextTests.swift:137-172`: the
  listener defaults wiring) — a listener log or error-text change must keep
  both green.

### Coordinator / keyring change
- `TeleportKeyRingTests` + `TeleportCoordinatorSmokeTests` +
  `TeleportBootstrapCoordinatorGenerationTests` (stale-continuation guards +
  the dismissal latch) + `TeleportBootstrapCoordinatorTimeoutTests` green; the
  redaction pins (`TeleportRedactionTests`) + the structured-login-error
  shape/mapping suite (`TeleportLoginClientErrorShapeTests`, including the
  `GRPCError.http2` packing tripwire) + `TeleportFrozenTextTests` green when a
  log site or an error text changes.
- The atomic credential pair (#41) additionally runs
  `TeleportLoginCoordinatorGenerationTests` (the login generation guards and
  the login half: supersession cannot tear, one pair/zero singles, the
  post-throw D4 states) + `TeleportDismissalTests` (both state maps and the
  latch-while-parked pair-lands-complete contract) and the source pins
  `TeleportCredentialPairPinsTests` (one pair call per
  coordinator; the keyring pair body non-async, key-first and suspend-free;
  the adapter's one-hop `MainActor.run`; the real writer's
  update-first/non-destructive `SecItem*` body). The keyring's new stored
  property + designated init must keep its `nonisolated deinit {}`
  (`TeleportSynchronousReleaseTests` traps at exit without it).
- Host-login / credential-identity changes additionally run
  `TeleportHostLoginTests`, `TeleportCertBindingCoordinatorTests`,
  `TeleportIssuedCertValidatorTests`, `TeleportCredentialReuseMatcherTests`,
  `TeleportKeyRingReuseTests`, `TeleportCredentialInvalidationPolicyTests`,
  `TeleportKeyRingInvalidationConformanceTests`, and the
  `TeleportDeviceReadinessTests` matrix (the fail-closed readiness order).

### Test change
- The package-owned suites may use the `TeleportTesting` mocks; they must not
  reference a host type.
- Fixtures stay hermetic (no secrets, no real server).

### Release / version change
- `package.json` version is the release source of truth (semver-calver shim).
- The release action only fires on `main`; do not hand-edit tags.

## 5. PR report

The PR description records: what changed, the exact commands run with their
results, and any residual risk (e.g. a gate that could not run locally).
