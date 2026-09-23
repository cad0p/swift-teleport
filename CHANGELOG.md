# Changelog

All notable changes to `swift-teleport` are documented in this file.

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
