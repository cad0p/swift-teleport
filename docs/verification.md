# Verification

The `/impl` verification checklist for `swift-teleport`. Run the narrowest
gate that exercises the change; report the exact commands and results.

## 1. CI gates and what "green" means

| Check | Job | Green means |
| --- | --- | --- |
| `headers` | ubuntu | No tracked file carries the AGPL SPDX marker; no `Sources/` file (every target) references a host symbol (`SSHError`, `KeychainError`, `Logger.forCategory`, `UserDefaults.standard`, `AuthMethod`, `TeleportKeyRing.shared`, `app.vivy.vvterm`, `SessionMutex`, `TeleportKeyRingStoring`) |
| `macos` | macos-26 | `swift test` (which builds the package) passes on macOS arm64 in Swift 6 language mode; the iOS-simulator `xcodebuild build` succeeds; the cross-package host-surface fixture (`Fixtures/HostSurfaceCheck`) builds |
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
python3 -B scripts/ci/check-package-boundaries.py
python3 -B scripts/ci/check-package-boundaries.py --selftest
xcodebuild build -scheme swift-teleport-Package \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: build clean (no warnings), **332 tests** pass (172 XCTest + 160
Swift Testing across `TeleportCoreTests` + `TeleportCoreConsumerTests` +
`TeleportPackageTests`), fixture package builds, boundary check OK, selftest OK,
iOS build succeeds.

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
  still compiles. That fixture is a **separate package** that path-depends on
  this one, so it sees only `public` — exactly what the Phase 2 host (also a
  different package) sees. The in-package `TeleportCoreConsumerTests`
  (`PublicSeamSmokeTests`) is a non-`@testable` smoke test of the public seam,
  but it cannot fail on a `public` → `package` demotion: `package` access is
  visible to every target inside this package. The fixture package is the
  fail-closed gate.

### Transport / TLS change
- `TeleportTLSTrustTests` (47) + `SSHTLSTransportTests` (13) green, including
  the loopback handshake and the fail-closed DER matrix.
- Re-check the `nonisolated` markers on `TeleportTLSTrust` and
  `TeleportLogging` if isolation changed.

### gRPC / protobuf change
- `ProtoWireCompatTests` green (the golden bytes are the wire contract).
- Regenerate with `scripts/regen-iotest-mfa.sh` (pinned `protoc 36.2` +
  `protoc-gen-swift 1.38.1`) and commit the `.pb.swift` with the IDL.

### WebAuthn / SEP change
- `FixtureTests` (8) green — the byte-exact Go oracle; an absent fixture is a
  hard failure, never a skip.
- `SEPSignerAlgorithmTests` + `WebAuthnResponseJSONTests` green.

### Coordinator / keyring change
- `TeleportKeyRingTests` + `TeleportCoordinatorSmokeTests` green; the
  redaction pins (`TeleportRedactionTests`) green when a log site changes.

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
