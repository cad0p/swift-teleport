# Changelog

All notable changes to this project will be documented in this file.

## [calver-released]

<!-- USER-EDITABLE SECTION START -->
<!-- Add your curated release notes here. -->
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
