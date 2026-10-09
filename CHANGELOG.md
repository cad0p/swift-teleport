# Changelog

All notable changes to this project will be documented in this file.

## [0.4.0] - 2026-10-09

<!-- USER-EDITABLE SECTION START -->
**Source-breaking for out-of-package `TeleportCredentialStore` conformers**: the protocol gains
the `storeCredentialPair` requirement. Under the D13 `0.x` policy (minors may break the API;
patches never) this is a minor release, not a patch.

Atomic credential pair (#41), matching the host issue
[`cad0p/vvterm#296`](https://github.com/cad0p/vvterm/issues/296)
(host fix PR [`#304`](https://github.com/cad0p/vvterm/pull/304)):

- `TeleportCredentialStore` gains one atomic pair write — `storeCredentialPair(_:validBefore:privateKeyPEM:policy:for:)`
  with a `.bootstrap` / `.login` policy — implemented by `TeleportKeyRing` as a synchronous
  `throws` witness whose non-suspending `@MainActor` body commits the ed25519 key and the
  credential record together, so a superseded attempt lands a complete pair, the previous complete
  pair, or nothing — never a mixed pair;
- the key write is update-first and non-destructive (`SecItemUpdate`; `errSecItemNotFound` →
  `SecItemAdd`; every other status fails closed without deleting), and the record commit mutates
  the cert fields only, preserving the registered SEP metadata;
- both coordinators call the pair once and, on a pair-write throw, derive the terminal state from
  the store's real contents instead of reporting a false success; the single writes remain on the
  protocol as non-atomic seed/test primitives;
- scope: **interleaving atomicity, not crash durability** — the record lives in `UserDefaults` and
  the key in the Keychain with no shared transaction, so a crash between the two backends can
  still leave a mixed pair that only the server's signature check rejects; atomicity is also per
  keyring instance.

SEP load and browser-MFA fail-fast/drain parity (#42), matching the host issue
[`cad0p/vvterm#242`](https://github.com/cad0p/vvterm/issues/242)
(host fix PR [`#305`](https://github.com/cad0p/vvterm/pull/305)):

- `SecureEnclaveSigner.loadKey` scopes the keychain query to the Secure Enclave again
  (`kSecAttrTokenID: kSecAttrTokenIDSecureEnclave`, pinned as a pure `loadKeyQuery` dictionary) and
  always queries the keychain — the truth for "is this device registered" — with the in-memory
  cache as `sign`'s fast path;
- `BrowserMFAListener.waitForResponse()` fails a second concurrent wait fast instead of orphaning
  the first, and a per-wait token keeps a rejected second waiter's cancellation from resuming the
  first;
- over-cap connections are drained (discarded, never buffered) and then answered 503 — bounded per
  connection (header terminator / max request size / read timeout), unbounded in count, taking no
  admission slot; a complete but unparseable header block is answered 400 immediately instead of
  waiting out the read deadline;
- the accepted-delta record comments (A2, A3, A6, A7, A8/D1/D3/D4/cosmetic) match the host's
  14-row table.

Tests across the release: 428 → 467 (248 XCTest + 219 Swift Testing); #42 alone is 453 → 467. The
host's [`cad0p/vvterm#306`](https://github.com/cad0p/vvterm/issues/306)
`OpenSSHEd25519PrivateKeyTests` flake hunk (host PR #305) is deliberately not ported (no package
equivalent; test-only).
<!-- USER-EDITABLE SECTION END -->

### 🐛 Bug Fixes

- *(teleport)* Write the cert and its private key as one atomic pair (closes #41)
- *(teleport)* Restore the pre-rewrite SEP load and browser-MFA fail-fast/drain behaviours (closes #42)

### 📚 Documentation

- Refresh the README status and the PROVENANCE version labels for v0.3.4 (closes #46)


## [0.3.4] - 2026-10-09

<!-- USER-EDITABLE SECTION START -->
Login HTTP error structure (#40), matching the host issue
[`cad0p/vvterm#236`](https://github.com/cad0p/vvterm/issues/236)
(host fix PR [`#303`](https://github.com/cad0p/vvterm/pull/303)):

- the login HTTP client throws the structured `HeadlessError.http(status:body:)`
  for a non-200 `login/begin` / `login/finish` — no longer packing the status and
  the body into one free-form `GRPCError.http2` string — and a body-free
  `HeadlessError.decode` for the 200-empty-cert decode site, whose previous
  `GRPCError.decode` message embedded a response-body snippet;
- the coordinator maps the structured error to `.server("HTTP <status>: <body>")`
  ("Teleport Server Error" with the server's message verbatim) and the log
  carries `HTTP <status>` only — the status is no longer lost and the raw body
  never reaches a `.public` log payload;
- `TeleportErrorRedaction`'s header now names the gRPC/HTTP-2 layer as
  `.http2`'s producer (an `NWError`/NIO pipeline message, not a packed body);
- a new `TeleportLoginClientErrorShapeTests` suite (9 cases) drives the real
  client over the loopback HTTP server, pins the coordinator mapping, and
  tripwires the literal packing out of `Sources/` and the host-surface fixture.

Patch release: no breaking public API change (no signature change;
`TeleportTesting`'s `MockTeleportLoginCoordinator.Scenario` gains an additive,
source-compatible `serverError(String)` case).
<!-- USER-EDITABLE SECTION END -->

### 🐛 Bug Fixes

- *(teleport)* Throw the structured HTTP error for login failures (closes #40)


## [0.3.3] - 2026-09-28

<!-- USER-EDITABLE SECTION START -->
Pump-fd use-after-release fix (#36), matching the host fix
[`cad0p/vvterm#237`](https://github.com/cad0p/vvterm/issues/237):

- `PumpFDCloser` is now one lock-serialized `open -> shutDown -> closed` state
  machine (mirroring the in-repo `AtomicSocket`). `shutdownOnce(_:)` wakes an
  in-flight `read`/`write` on the socketpair pump end (read -> `0`, write ->
  `EPIPE` under the already-set `SO_NOSIGPIPE`) **without** freeing the
  descriptor number; `closeOnce(_:)` releases it and is terminal for both.
  Both syscalls run inside the state lock, so a preempted call can never reach a
  freed or reused number;
- `runPump` joins both loops before releasing:
  `group.next() -> group.cancelAll() -> shutdownOnce -> connection.cancel() ->
  await group.waitForAll() -> closeOnce`. Previously the pump end was closed as
  soon as **one** loop exited while the sibling was only cancelled, so a
  `read`/`write` could start on the number after `close(2)` freed it — a `read`
  forwarded unrelated bytes to the server, a `write` corrupted an unrelated file;
- the TLS-handshake-failure path releases only from a path that has joined the
  pump; when a concurrent `close()` already took the task, `runPump` owns the
  release after its own join;
- `writeAllToPumpFD` is cancellation-aware, and the pump bodies are
  `nonisolated static` with no `self` capture, so a dying actor cannot strand
  the descriptor;
- the closer's suite grew 3 -> 10 cases, including a brace-matched pin that the
  connect-failure release sits **inside** the joined-pump gate.

Patch release: no public API change. The host half is
[`cad0p/vvterm#285`](https://github.com/cad0p/vvterm/pull/285).
<!-- USER-EDITABLE SECTION END -->

### 🐛 Bug Fixes

- *(teleport)* Pump-fd shutdown/close split so no syscall starts after release (closes #36)


## [0.3.2] - 2026-09-28

<!-- USER-EDITABLE SECTION START -->
FQDN log redaction (#32), matching the host fix
[`cad0p/vvterm#275`](https://github.com/cad0p/vvterm/issues/275):

- every `privacy: .public` interpolation of an environment FQDN in the Teleport
  paths is now `.private(mask: .hash)` — 15 interpolations across 13 lines:
  `cluster.host` x3, `rpID` x2, the TLS dial `self.host` x5, `clusterName` /
  `state.clusterName` x2, `alpnProto` x1, and the two ALPN values on the
  `teleport_tls_verify_failed` line;
- the auth-route ALPN (`teleport-auth@<hex(clusterName)>`) is the cluster FQDN
  hex-encoded, so it is hashed like the server names it sits beside;
- a package-local tripwire (`testFQDNClassIsNeverLoggedPublicly`) pins each
  expression's private-interpolation count and reports any whole-interpolation
  `.public` match, so a reverted annotation fails by name.

Kept `.public` by decision: UUIDs, ports, counts, protocol constants, statuses,
and the documented `error.localizedDescription` / `String(describing:)`
transport-error carve-outs.

Patch release: no public API change. The host half is
[`cad0p/vvterm#282`](https://github.com/cad0p/vvterm/pull/282).
<!-- USER-EDITABLE SECTION END -->

### 🐛 Bug Fixes

- *(teleport)* Hash the cluster FQDN class in log interpolations (closes #32)

### 📚 Documentation

- Refresh the README status and PROVENANCE version labels for v0.3.1 (closes #30)


## [0.3.1] - 2026-09-27

<!-- USER-EDITABLE SECTION START -->
Identity-leak hardening (#22), matching the host-parity fixes:

- the bootstrap log no longer publishes the Teleport username
  (`privacy: .private`);
- `TeleportHostLoginFailure` renders payload-free under reflection
  (`dump`/`Mirror`) via a `CustomReflectable` mirror carrying the case name
  only, with `CustomDebugStringConvertible` alongside.

The host half of the same leaks is [`cad0p/vvterm#273`](https://github.com/cad0p/vvterm/issues/273).
<!-- USER-EDITABLE SECTION END -->

### 🐛 Bug Fixes

- *(teleport)* Log the bootstrap username privately and render the host-login failure payload-free (closes #22)

### 📚 Documentation

- Refresh the README status and PROVENANCE version labels for v0.3.0 (closes #25)


## [0.3.0] - 2026-09-27

<!-- USER-EDITABLE SECTION START -->
Parity with the host's #262 host-login fix
([`cad0p/vvterm#263`](https://github.com/cad0p/vvterm/pull/263), squash
`30ac5388`), so Phase 2 can delete the host's Teleport copies and adopt the
package as the source of truth.

A Teleport SSH connection authenticates as the Teleport *user* (`pier`), but
the username libssh2 sends must be a **certificate principal** — the host login
(`deploy`); Teleport's `CertChecker` rejects a username that is not in the
certificate's `ValidPrincipals`. `TeleportCore` gains the fail-closed
host-login resolver (`TeleportHostLogin`), the credential-invalidation seam,
the generalized credential-reuse matcher, and the certificate's principals on
`TeleportLoginState.success`. `TeleportAuth` gains the keyID binding in both
coordinators, the fail-closed readiness order, the `certExpiry` re-parse, the
one-body `liveCredentialSnapshot` read, and the registration-reuse helpers.

Also in this release:

- the issued-cert validator rejects a certificate with no non-internal
  principal, so a login can never reach `.success(logins: [])`;
- the cross-package host-surface fixture mirrors the new public surface, and
  now consumes `liveCredentialSnapshot` through the protocol so a requirement
  removal fails the gate;
- the boundary gate forbids `String(localized:)` in package sources.

`0.x` minor: this release changes the payload of the public enum case
`TeleportLoginState.success(certValidUntil:logins:)`, which is source-breaking.
Per the package's `0.x` policy (D13), minors may break the API and patches
never. See `docs/API.md` and `docs/INTEGRATION.md`.
<!-- USER-EDITABLE SECTION END -->

### 🐛 Bug Fixes

- *(teleport)* Port the #262 host-login resolution into the package (closes #20)


## [0.2.1] - 2026-09-26

<!-- USER-EDITABLE SECTION START -->
Host parity with the post-`v0.2.0` security fixes in
[`cad0p/vvterm`](https://github.com/cad0p/vvterm) @ `05764aa2`, plus the four
deferred package findings.

`TeleportCore`/`TeleportAuth` now match the host: single-owner pump-fd close
with `SO_NOSIGPIPE`, wire-derived error log redaction, request-generation
stale-continuation guards, `nonisolated` deinit markers, OSStatus signer
classification, the GCM-gated browser-MFA callback, and the nested Secure
Enclave private-key attributes (the `errSecAuthFailed` device-registration
failure).

Also in this release:

- the host-surface fixture's `Package.resolved` is tracked, so the
  cross-package gate resolves reproducibly (#13);
- the gitleaks allowlist pins the 19 known loopback fixtures instead of a
  directory glob (#14);
- the SEP device name is logged with `privacy: .private` (#15);
- the release-visible keychain-sweep bounds are recorded in `docs/API.md` (#16).
<!-- USER-EDITABLE SECTION END -->

### 🐛 Bug Fixes

- *(teleport)* Host parity + deferred package findings (closes #13, closes #14, closes #15, closes #16)


## [0.2.0] - 2026-09-24

<!-- USER-EDITABLE SECTION START -->
The full Teleport client, in three products.

`TeleportCore` grows the gRPC/protobuf transport, the WebAuthn/SEP ceremony,
the Browser-MFA loopback listener, the seam/wire types, and the pure domain
(`HeadlessID`, `TLSKeyPair`, the issued-certificate validator, rpID
resolution). `TeleportAuth` adds the keyring and the bootstrap/login/
registration coordinators. `TeleportTesting` adds the seven scripted mocks
plus `SoftwareSigner`, the software P-256 signer that makes the SEP ceremony
testable without hardware.

All of it is imported from [`cad0p/vvterm`](https://github.com/cad0p/vvterm) @
`291d75fb`, on top of the clean-room rewrite of the Teleport-derived files
(`v0.1.0`'s zero-dependency skeleton is unchanged).

Also in this release:

- a **cross-package host-surface gate** (`Fixtures/HostSurfaceCheck`) that
  compiles the host's adoption surface against `public` only, in debug **and**
  release, so a missing promotion fails in CI instead of in the host;
- the `package.json`/`CHANGELOG.md` **release validators** and the package
  boundary/license gate;
- `PrivacyInfo.xcprivacy` for the one `UserDefaults` use (`CA92.1`).

`0.x` minor: the public surface is the three products above; internal model
types stay `package`-scoped. See `docs/API.md` and `docs/INTEGRATION.md`.
<!-- USER-EDITABLE SECTION END -->

### 🚀 Features

- Import the remaining Teleport client — TeleportCore + TeleportAuth + TeleportTesting (closes #10)

### 📚 Documentation

- Make the independent-review lenses phase-aware (closes #3)
- AGENTS.md — pinned base text (drop Goldmine variant) (closes #7) ([#8](https://github.com/cad0p/swift-teleport/pull/8))

### ⚙️ Miscellaneous Tasks

- Add the package-version and release-PR validators (closes #5)


## [0.1.0] - 2026-09-23

<!-- USER-EDITABLE SECTION START -->
Walking-skeleton bootstrap: the zero-dependency `TeleportCore` package —
the D6 seam protocols, the SSH TLS/ALPN transport, and the OpenSSH
certificate domain — imported from `cad0p/vvterm` @ `a18a77b4` with the
public seam promoted. Zero external dependencies; the gRPC/protobuf
transport, keyring, coordinators, and WebAuthn/SEP machinery arrive in
`v0.2.0`.
<!-- USER-EDITABLE SECTION END -->

### 🚀 Features

- *(TeleportCore)* Bootstrap the package with the dependency-closed Teleport client core (closes #1)
