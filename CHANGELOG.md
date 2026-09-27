# Changelog

All notable changes to this project will be documented in this file.

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
