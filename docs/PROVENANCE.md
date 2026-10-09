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
- **v0.3.0** carries `30ac5388` — the
  #262 host-login resolution: the SSH username must be a certificate
  principal, not the Teleport user. It ports the
  resolver, the validator's non-internal-principal guard, the
  `success(certValidUntil:logins:)` payload, the coordinator keyID bindings,
  the fail-closed readiness order, the keyring `certExpiry`/
  `liveCredentialSnapshot`/reuse helpers, and the credential-invalidation
  seam. Two host-type couplings are deliberately generalized (below).
- **v0.3.1** carries `96bbf74a` — the #22 identity-leak hardening: the
  bootstrap log no longer publishes the Teleport username
  (`privacy: .private`), and `TeleportHostLoginFailure` renders payload-free
  under reflection (`CustomReflectable` + `CustomDebugStringConvertible`).
- **v0.3.2** carries `0bf4e9d` — the #32 FQDN log redaction: the FQDN-bearing
  log interpolations are `.private(mask: .hash)` instead of `.public`.
- **v0.3.3** carries `1e4fe09` — the #36 pump-fd shutdown/close split: the
  closer is one lock-serialized `open → shutDown → closed` machine, and
  `runPump` joins both loops before releasing the descriptor. The
  `ReadyWaiter` pre-`start` arm half of host `2e533466` (the same host commit
  as the pump split) is carried by v0.5.1 below.
- **v0.3.4** carries `d455474` — the #40 login HTTP error structure: the login
  client throws the structured `HeadlessError.http(status:body:)` (and a
  body-free `HeadlessError.decode` at the 200-empty-cert site), so the log
  carries `HTTP <status>` and the login state reaches `.server(message)`.
- **v0.4.0** carries `9c86cba` (#41) and `22efb09` (#42). `9c86cba` is the
  atomic credential pair: `TeleportCredentialStore` gains the
  `storeCredentialPair` requirement (source-breaking for out-of-package
  conformers), implemented by `TeleportKeyRing` as a synchronous `throws`
  witness whose non-suspending `@MainActor` body commits the ed25519 key and
  the credential record together with an update-first, non-destructive key
  write — scope: interleaving atomicity, not crash durability. `22efb09`
  restores the pre-rewrite SEP `loadKey` semantics (the `kSecAttrTokenID`
  Secure Enclave token scope, keychain-always with the cache as `sign`'s fast
  path) and the browser-MFA fail-fast/drain behaviours (concurrent-wait guards
  with a per-wait token, the discard-only over-cap drain, the immediate 400 on
  a malformed complete header), plus the accepted-delta record comments — host
  parity with `cad0p/vvterm` #242 (`062d25ba`).
- **v0.5.0** carries `56cdbec` (#48) — the login continuation guards and the dismissal latch: the
  login coordinator's monotonic request-generation token with a re-take after every suspension point
  (host `eccec38f`, #240/#279, host fix PR #297), the #298 per-site pin tests (host `dd3ed8bc`, host
  fix PR #307), and the synchronous dismissal latch — `latchDismissal()` on the public coordinating
  protocols with no protocol-extension default (source-breaking for out-of-package conformers), a
  `private(set) isDismissalLatched` flag that makes `begin()` / bootstrap `retry()` terminal, and the
  public exhaustive `dismissalRequiresTeardown` maps (host `4253f48e`, #272, host fix PR #278).
- **v0.5.1** carries the post-v0.5.0 host deltas so the vvterm #371 Phase-2
  cutover cannot regress: `24e27af5` (#267 — `retry()` re-runs `begin`, plus
  the `MockWebAuthenticationSessionPresenter` helpers), `da56b322` +
  `642117ee` (#401/#405 — the `BrowserMFAListening` protocol + the
  `makeListener` seam and its structural pins), `9445393e` (#268/#269 —
  `OpenSSHCertificate.rawBlob` and the public `sshString` builder; the agent
  forwarding itself stays host-side), `2e533466` (#237 — the `ReadyWaiter`
  pre-`start` arm), and `414dda9c` (#277 — the
  `MockTeleportBootstrapCoordinator` `holdsForApproval`/`releaseApproval`
  gate seam).

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
6. **Plain-literal error text** — the ported
   `TeleportHostLoginFailure.errorDescription` drops the host's
   `String(localized:)` wrappers for plain literals: the package ships no
   localization catalog, and its boundary gate forbids `String(localized:)`
   in package sources. The message text and its rendering are unchanged.

Beyond the access-level/module/isolated-deinit/plain-literal adaptations above
and the v0.2.1/v0.3.0 parity ports, the imported file content is unchanged
from the host's post-`30ac5388` shapes, except for the #22 hardening below.

### #22 identity-leak hardening (package-ahead)

Two host-parity identity leaks are fixed in the package while the host still
carries them; the host fix lands in the follow-up `cad0p/vvterm` PR (D2):

- `TeleportBootstrapCoordinator.begin` logs the Teleport username with
  `privacy: .private` (the host line still publishes it; #15 set the device-name
  precedent).
- `TeleportHostLoginFailure` adds `CustomDebugStringConvertible` and
  `CustomReflectable`, so `dump(_:)`/`Mirror(reflecting:)` render the case name
  only (the host enum still synthesizes a mirror carrying the principal list).

### v0.3.0 `Server`-free generalizations (deliberate)

The #262 host code named two host types; the package carries neither:

- **Host-login normalizer** — the host's `Server.normalizedTeleportHostLogin`
  moved in as `TeleportHostLogin.normalized(_:)` +
  `package maxTeleportHostLoginBytes` (byte-identical semantics: trim, reject
  empty / >255 UTF-8 bytes / control characters, allow `@`). The host's
  `Server` delegates to it in Phase 2. The constant stays `package` because
  only the normalizer consumes it host-side.
- **Reuse row** — the host's `TeleportCredentialReuse.match(newServer:
  liveServers:…) -> Server?` became
  `match<Row: TeleportCredentialReuseRow>(newRow:liveRows:…) -> Row?`; the
  host's `Server` conforms to `TeleportCredentialReuseRow` in Phase 2. The
  matching semantics (host + Teleport user, Face-ID-Teleport on both sides,
  credential record, injected completeness gate, cluster-name rule,
  name-sorted first pick) are unchanged.

Host-only #262 files (not imported): `TeleportLoginView` (SwiftUI picker),
`TeleportKeyRing+Reuse` (orchestration over `Server`),
`SSHError+TeleportHostLogin` (the app-only fail-closed route),
`ServerManager` invalidation wiring + `Server`/`Server+CloudKit`, the
`TeleportKeyRingCredentialStore`/`TeleportKeyRingStoring` deltas, and the
`SSHClient` connect-site redaction deltas.

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

### v0.3.0 additions (3 files)

| Path | Origin |
| --- | --- |
| `Domain/TeleportHostLogin.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Domain/TeleportCredentialReuse.swift` | `VVTerm/Features/Teleport/Domain/` |
| `Application/TeleportCredentialInvalidating.swift` | `VVTerm/Core/Teleport/` (host-only path; the record-level invalidation seam) |

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

The host adopts the package by pinning `exactVersion` and restoring its
observation conformance (`extension TeleportKeyRing: TeleportKeyRingStoring`)
+ its live adapters at the composition root. Phase 2 is out of scope here.
