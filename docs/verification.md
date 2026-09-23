# Verification

The `/impl` verification checklist for `swift-teleport`. Run the narrowest
gate that exercises the change; report the exact commands and results.

## 1. CI gates and what "green" means

| Check | Job | Green means |
| --- | --- | --- |
| `headers` | ubuntu | No tracked file carries the AGPL SPDX marker; no `Sources/TeleportCore` file references a host symbol (`SSHError`, `KeychainError`, `Logger.forCategory`, `UserDefaults.standard`, `AuthMethod`, `TeleportKeyRing.shared`, `app.vivy.vvterm`, `SessionMutex`) |
| `macos` | macos-26 | `swift build` + `swift test` pass on macOS arm64 in Swift 6 language mode; the iOS-simulator `xcodebuild build` succeeds |
| `validate-package-version` | ubuntu | the `package.json` version bump matches the change class (semver-calver) |
| `validate-release-pr` | ubuntu | a `release/from-v*` PR bumps the version from the last released base; non-release branches skip |

All four jobs must be green on the PR head and are required on the `main`
ruleset.

## 2. Offline gates (run before pushing)

```bash
swift build
swift test
python3 -B scripts/ci/check-package-boundaries.py
python3 -B scripts/ci/check-package-boundaries.py --selftest
xcodebuild build -scheme swift-teleport \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: build clean (no warnings), 191 tests pass (68 XCTest + 123 Swift
Testing across `TeleportCoreTests` + `TeleportCoreConsumerTests`), boundary
check OK, selftest OK, iOS build succeeds.

## 3. Independent-review protocol

Every non-trivial change gets at least one review lens before merge:

- **Architecture lens** — ownership boundaries (`Domain` / `Application` /
  `Infrastructure`), the public-seam surface, the Swift 6 isolation story.
- **Behavior lens** — does the change preserve the ported behavior? For
  security-relevant paths (TLS verification, host-cert verification, cert
  expiry), check the fail-closed paths and the fixtures that pin them.

Findings are fixed in follow-up commits on the same branch; the PR description
records the rounds.

## 4. Live-proof checklist per change type

### Package source change
- `swift test` green; the boundary check green.
- If a public signature changed: the non-`@testable`
  `TeleportCoreConsumerTests` target still compiles (it fails closed on an
  access-level regression).

### Transport / TLS change
- `TeleportTLSTrustTests` (47) + `SSHTLSTransportTests` (13) green, including
  the loopback handshake and the fail-closed DER matrix.
- Re-check the `nonisolated` markers on `TeleportTLSTrust` and
  `TeleportLogging` if isolation changed.

### Test change
- No ported suite may reference `MockTeleportHTTPClient` /
  `MockTeleportKeyRing` (excluded mocks) or a host type.
- Fixtures stay hermetic (no secrets, no real server).

### Release / version change
- `package.json` version is the release source of truth (semver-calver shim).
- The release action only fires on `main`; do not hand-edit tags.

## 5. PR report

The PR description records: what changed, the exact commands run with their
results, and any residual risk (e.g. a gate that could not run locally).
