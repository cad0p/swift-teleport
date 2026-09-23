# swift-teleport

A Teleport client core for Apple platforms — SSH-over-TLS routing, OpenSSH
certificate parsing/verification, and the seam protocols that let a host app
supply its own keychain, logging, credential store, and in-app browser.

> **Not affiliated with Gravitational, Inc.** This is an independent,
> community Swift package. "Teleport" refers to the
> [Gravitational Teleport](https://github.com/gravitational/teleport) server
> this client talks to; this project is not produced, endorsed, or supported
> by Gravitational.

## Status

`v0.1.0` is a **walking skeleton**: the dependency-closed, package-movable
core of a Teleport client (the D6 seam + the SSH TLS/ALPN transport + the
OpenSSH certificate domain). It is intentionally small and has **zero external
dependencies**. The gRPC/protobuf transport, the keyring, the login/registration
coordinators, and the WebAuthn/SEP machinery arrive in `v0.2.0`. See
[`docs/PROVENANCE.md`](docs/PROVENANCE.md) for exactly what is in and out.

Requires **Swift 6.2 / Xcode 26** and targets **iOS 16.1+ / macOS 13.3+**
(arm64). See [`docs/SPEC.md`](docs/SPEC.md).

## Provenance

The sources under `Sources/TeleportCore/` are imported from
[`cad0p/vvterm`](https://github.com/cad0p/vvterm) at commit `a18a77b4`
(the post-hardening Teleport client), with only the access-level changes needed
to export a usable public seam. The full imported/deferred file inventory, the
upstream attribution, and the Phase 1b clean-room rewrite gate are in
[`docs/PROVENANCE.md`](docs/PROVENANCE.md).

## License

This package is **MIT** ([`LICENSE`](LICENSE)).

The host project (`cad0p/vvterm`) is a mixed-license repository: its
Teleport-derived files remain **AGPL-3.0-or-later** and are **carved out
host-side — they are not in this package**. `v0.1.0` ships no AGPL text. The
boundary is enforced in CI and documented in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Development

```bash
swift build
swift test
```

CI runs `swift test` plus an iOS-simulator `xcodebuild build` on `macos-26`,
and a license/boundary check on ubuntu. The verification checklist is
[`docs/verification.md`](docs/verification.md).
