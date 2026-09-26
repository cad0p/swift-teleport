# Provenance

## Import source

All package sources were imported from
[`cad0p/vvterm`](https://github.com/cad0p/vvterm) at commit `291d75fb`
("ci(ui-tests): harden the PR shards — wedge retry, 4-bin rebalance, 300s
hang timeout, debug-test flags, doc sweep (closes #229)"), the post-Stage-A
tree:

- **v0.1.0** imported 18 files at `a18a77b4` (the post-Phase-0c sweep) — the
  dependency-closed core (D6 seam + transports).
- **Stage A** (`ba81877c`, "refactor(teleport): clean-room rewrite") rewrote
  the 9 package-movable Teleport-derived files so they are independent
  implementations of the documented public contract, shrinking the host's
  AGPL allowlist 17 → 7 rows.
- **v0.2.0** imports the remaining **25 deferred files + 7 `TeleportTesting`
  mocks + `iotest_mfa.proto` + the regen script** from `291d75fb` (which
  carries the Stage A rewrite) and splits them into `TeleportCore` +
  `TeleportAuth` + `TeleportTesting`.
- **v0.2.1** ports the post-import host fixes so the package tracks the host:
  `3d78bc58` (single-owner pump-fd close + `SO_NOSIGPIPE`, wire-error log
  redaction), `7b8499e4` (request-generation stale-continuation guards,
  `nonisolated` deinit markers, OSStatus signer classification), and
  `05764aa2` (GCM-gated browser-MFA callback, nested SEP private-key
  attributes). The parity inventory is below.

The import preserves file content except for:

1. **Access-level promotion** — the types and members the host's Phase-2 call
   sites name (and everything reachable across the three package targets) are
   now `public`/`package` (the package's contract). Model internals stay
   `internal`. Types that cross the module boundary also gained explicit
   initialisers where the implicit memberwise/`init()` was not visible outside
   the module — the wire types in `MFALoginWireTypes` and `HeadlessLogin`,
   `BootstrapResult`, `TLSKeyPair`, three protocol-support classes in
   `TeleportInfrastructureProtocols`, and the `TeleportTesting` mocks. Each was
   audited to reproduce the suppressed initialiser exactly — same parameter
   order and types, same defaults.
2. **Module imports** — the `TeleportAuth`/`TeleportTesting` files import
   `TeleportCore` (and `TeleportTesting` imports `TeleportAuth`) at the new
   module boundaries.
3. **Minimal Swift 6 diagnostics** — the host app builds these files in Swift
   **5** language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; this
   package builds them in Swift **6** language mode with
   `.defaultIsolation(MainActor.self)`. The declarations the default isolation
   does not cover are marked `nonisolated`/`@Sendable`, and the XCTest suites
   follow the `nonisolated final class` + `@MainActor` test-method pattern
   (see below).
4. **`TeleportTesting` composition** — the 7 mocks drop their `#if DEBUG`
   gates, `MockTeleportKeyRing` ships **without** the host-only
   `TeleportKeyRingStoring` conformance (the host restores it by extension in
   Phase 2), and `MockTeleportHTTPClient`'s `#filePath` fixture coupling is
   replaced by plain scripted scenarios (the fixture-bound payload factories
   live in the test targets). `SoftwareSigner` moves from `TeleportCore` to
   `TeleportTesting` (and `package` → `public`) because its only consumers are
   test targets.
5. **Pump-fd single ownership** — v0.2.0's `SSHTLSTransport` carried the
   old-shape pump end that the host then had too: six racing close paths and a
   repeated `close(2)` treated as harmless. It is not — if the fd number has
   been reused for another file, the close lands on the wrong file and the next
   read there fails with `EBADF`. Found via a spurious fixture-read failure
   under the package's parallel `swift test`
   ([`cad0p/vvterm#234`](https://github.com/cad0p/vvterm/issues/234)). v0.2.1
   **ports the host's fix** (`3d78bc58`): every close routes through a
   fd-less `PumpFDCloser.closeOnce(_:)`, and `makeSocketPair()` sets
   `SO_NOSIGPIPE` on both ends (the `shutdown`+`close` shape makes a racing
   write return `EPIPE`, which would otherwise raise `SIGPIPE`). The guard and
   the sockopt are now **parity with the host**, not a package-only divergence.
   Three XCTest cases pin the guard (fd-reuse via `dup2`, a source-level pin
   that no raw `Darwin.close(...pumpFD...)` reappears, and a SIGPIPE
   counterfactual).

Beyond the access-level/module/isolated-deinit adaptations above and the
v0.2.1 parity ports, the imported file content is unchanged from the host's
post-`05764aa2` shapes.

## Imported set (v0.2.0 additions: 32 files + proto + script)

### `TeleportCore` additions (20 files + the IDL; 19 at v0.2.0 + `TeleportErrorRedaction.swift` at v0.2.1)

| Path | Origin |
| --- | --- |
| `Infrastructure/iotest_mfa.pb.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/iotest_mfa.proto` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/GRPCClient.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/GRPCTransport.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/HeadlessID.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/HeadlessLogin.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/MFALoginWireTypes.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/TeleportTrustSession.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/TeleportErrorRedaction.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/TLSKeyPair.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/BrowserMFAListener.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/BrowserMFACeremony.swift` | `VVTerm/Features/Teleport/Infrastructure/` |
| `Infrastructure/SEPWebAuthn/CBOR.swift` | `VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/` |
| `Infrastructure/SEPWebAuthn/SSHPubKey.swift` | `VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/` |
| `Infrastructure/SEPWebAuthn/Signer.swift` | `VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/` |
| `Infrastructure/SEPWebAuthn/Attestation.swift` | `VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/` |
| `Infrastructure/SEPWebAuthn/WebAuthn.swift` | `VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/` |
| `Infrastructure/SEPWebAuthn/SecureEnclaveSigner.swift` | `VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/` |
| `Application/TeleportInfrastructureProtocols.swift` | `VVTerm/Features/Teleport/Application/` |
| `Domain/TeleportIssuedCertValidator.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportWebAuthnRPID.swift` | `VVTerm/Features/Teleport/Domain/` |

### `TeleportAuth` (5 files)

| Path | Origin |
| --- | --- |
| `Application/TeleportBootstrapCoordinator.swift` | `VVTerm/Features/Teleport/Application/` |
| `Application/TeleportLoginCoordinator.swift` | `VVTerm/Features/Teleport/Application/` |
| `Application/TeleportRegistrationCoordinator.swift` | `VVTerm/Features/Teleport/Application/` |
| `Application/TeleportKeyRing.swift` | `VVTerm/Features/Teleport/Application/` |
| `Infrastructure/TeleportHTTPClient.swift` | `VVTerm/Features/Teleport/Infrastructure/` |

### `TeleportTesting` (8 files)

`MockSEPKeySigner`, `MockTeleportBootstrapCoordinator`,
`MockTeleportHTTPClient`, `MockTeleportKeyRing`,
`MockTeleportLoginCoordinator`, `MockTeleportRegistrationCoordinator`,
`MockWebAuthenticationSessionPresenter` — all from
`VVTerm/Features/Teleport/UITesting/`.

| Path | Origin |
| --- | --- |
| `SoftwareSigner.swift` | `VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/SoftwareSigner.swift` |

The 8th entry is a deliberate **product move** (not a content change):
`SoftwareSigner` is a software test double whose only consumers are test
targets, so it ships in the test-support product as `public` instead of
`package` inside `TeleportCore`. That is what makes the kept host-side
`TeleportServerIntegrationTests` (a different package in Phase 2) able to
construct it. See `docs/API.md` § `TeleportTesting`.

### Regeneration script

`scripts/regen-iotest-mfa.sh` — adapted from `cad0p/vvterm`'s
`scripts/regen-iotest-mfa.sh` to the package path
(`Sources/TeleportCore/Infrastructure`). Pins `protoc 36.2` +
`protoc-gen-swift 1.38.1`, passes `Visibility=Public`, reapplies the
`nonisolated` patch by pattern, and asserts the generated shape. Verified
byte-reproducible against the committed `.pb.swift`.

### Host-side by design (not part of the package)

- `SSHProxySubsystemTransport` + `SessionMutex` — the libssh2 channel bridge
  (14 libssh2 calls); exposed to the package only through
  `TeleportChannelTransportFactory` (D6).
- `Core/Teleport/*` host adapters (`TeleportComposition`,
  `TeleportKeyRingHost`, `TeleportKeyRingCredentialStore`,
  `TeleportKeyRingStoring`, `TeleportErrorMapping`,
  `TeleportKeychainConfig+App`).
- `UI/*` (the SwiftUI surfaces + `TeleportLiveCoordinators`), the iOS UI-test
  harnesses, and the remaining host-side AGPL files
  (`TeleportLiveCoordinators.swift`, `scripts/ci/teleport-webauthn.py`, the 4
  spike copies, the Go fixture generator).

## Swift 6 changes (minimal, behavior-preserving)

| Declaration | Change | Why |
| --- | --- | --- |
| `TeleportTLSTrust` (enum) | `nonisolated` | pure-function enum; called from `SSHTLSTransport`'s nonisolated statics |
| `TeleportLogging.logger(category:)` | `nonisolated` | `os.Logger` construction is thread-safe; requested from the transport actor |
| `DefaultTeleportLogging.logger(category:)` | `nonisolated` | protocol witness |
| `iotest_mfa.pb.swift` | 26 structs + 3 enums + `_protobuf_package` `nonisolated` | generated types must compile under `.defaultIsolation(MainActor.self)` (B3.1) |
| `GRPCClient.withTimeout<T>` | `T: Sendable` | `withThrowingTaskGroup` under Swift 6 (B3.2) |
| `TLSKeyPair` | `nonisolated struct` + explicit init | constructed from nonisolated contexts (B3.5) |
| `CBOR`'s `Data` base64url helpers | `nonisolated extension` | called from the mocks' nonisolated statics (B3.6) |
| `BrowserMFAListener` | `nonisolated` + lock-boxed state + `@Sendable` locals | Swift 6 concurrency, rewritten in Stage A |
| `GRPCTransport`'s captured multiplexer | captured `var` → `NIOLockedValueBox` | the host form was an **unsynchronized** capture across the channel-initializer closure; Swift 6 rejects it, and the lock is strictly safer. Single-writer overwrite semantics are preserved (the direction of the change is safer, not merely diagnostic) |
| `TeleportTesting` mocks | `@MainActor` class + `@MainActor` isolated conformance | protocol conformances crossing module boundaries |
| `SoftwareSigner` | `@MainActor` class + `@MainActor` on each conformance | same rule, after the move into `TeleportTesting` (`WebAuthnSigner`/`SEPKeySigning`/`TeleportSEPSigning` are declared in `TeleportCore`) |
| XCTest suites | `nonisolated final class` + `@MainActor` methods | `XCTestCase`'s inherited initializers are nonisolated |

## Fixtures

`Tests/TeleportCoreTests/Fixtures/` (v0.1.0) and
`Tests/TeleportPackageTests/Fixtures/` (v0.2.0) carry test-only, generated,
public material. The Core tree is the single canonical fixture root for the
OpenSSH CA/host/user certs + keys, the generated loopback TLS identities
(PKCS#12 + PEM) with the well-known test password, and the captured public
certificate chains; the `TeleportPackageTests` suites (which host Core- and
Auth-subject tests) read that same tree, so there is exactly one copy. The
`TeleportPackageTests/Fixtures/SEPWebAuthn/` subtree holds the **8 Go-generated
SEP/WebAuthn fixtures** (`client_data_{create,get}.json`,
`auth_data_{create,get}.bin`, `cose_pubkey.cbor`, `pub_key_raw.bin`,
`signature_create.der`, `attestation_object_create.cbor`), which no Core suite
uses.

The 8 SEP fixtures are copied from `cad0p/vvterm`'s
`spikes/sep-webauthn/fixtures/expected/` at `291d75fb` (committed in the
Stage A prep PR `#212`). They are the byte-exact oracle for the clean-room
SEP rewrite; the package copies them so the `macos` CI job runs the
comparison without a Go toolchain. No production secret is present.
Fixtures are read at runtime via `#filePath`-relative paths and are declared
`exclude` in `Package.swift` so SwiftPM does not treat them as target
sources.

## Host-side Teleport notice (for reference)

The host's remaining AGPL carve-out is enumerated in `cad0p/vvterm`'s
`docs/teleport-derived-files.txt` (7 rows) and covered by its
`LICENSES/AGPL-3.0-or-later.txt`. Aggregate host licensing: the `cad0p/vvterm`
repository as distributed stays GPL-3.0; AGPL-3.0 and GPL-3.0 combination is
permitted by GPLv3 section 13.

## Phase 2 gate

The host adopts `v0.2.0` by pinning `exactVersion` and restoring its
observation conformance (`extension TeleportKeyRing: TeleportKeyRingStoring`)
+ its live adapters at the composition root. Phase 2 is out of scope here.
