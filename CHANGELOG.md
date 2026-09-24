# Changelog

All notable changes to this project will be documented in this file.

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
