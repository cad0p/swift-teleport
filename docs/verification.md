# Verification

The `/impl` verification checklist for `swift-teleport`. Run the narrowest
gate that exercises the change; report the exact commands and results.

## 1. CI gates and what "green" means

| Check | Job | Green means |
| --- | --- | --- |
| `headers` | ubuntu | No tracked file carries the AGPL SPDX marker; no `Sources/` file (every target) references a host symbol (`SSHError`, `KeychainError`, `Logger.forCategory`, `UserDefaults.standard`, `AuthMethod`, `TeleportKeyRing.shared`, `app.vivy.vvterm`, `SessionMutex`, `TeleportKeyRingStoring`) |
| `macos` | macos-26 | `swift build` + `swift test` pass on macOS arm64 in Swift 6 language mode; the iOS-simulator `xcodebuild build` succeeds |
| `validate-package-version` | ubuntu | the `package.json` version bump matches the change class (semver-calver) |
| `validate-release-pr` | ubuntu | a `release/from-v*` PR bumps the version from the last released base; non-release branches skip |

All four jobs must be green on the PR head and are required on the `main`
ruleset.

## 2. Offline gates (run before pushing)

```bash
swift build
swift build -c release          # proves TeleportTesting builds without #if DEBUG
swift test
python3 -B scripts/ci/check-package-boundaries.py
python3 -B scripts/ci/check-package-boundaries.py --selftest
xcodebuild build -scheme swift-teleport \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: build clean (no warnings), **319 tests** pass (168 XCTest + 151
Swift Testing across `TeleportCoreTests` + `TeleportCoreConsumerTests` +
`TeleportAuthTests`), boundary check OK, selftest OK, iOS build succeeds.

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
- If a public signature changed: the non-`@testable`
  `TeleportCoreConsumerTests` target still compiles (it fails closed on an
  access-level regression, including the mirrored host surface).

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
