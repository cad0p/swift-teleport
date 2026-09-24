# swift-teleport

A Teleport client core for Apple platforms — SSH-over-TLS routing, OpenSSH
certificate parsing/verification, the gRPC/protobuf auth transport, the
WebAuthn/SEP ceremony machinery, the bootstrap/login/registration
coordinators, the per-cluster keyring, and the seam protocols that let a host
app supply its own keychain, logging, credential store, and in-app browser.

> **Not affiliated with Gravitational, Inc.** This is an independent,
> community Swift package. "Teleport" refers to the
> [Gravitational Teleport](https://github.com/gravitational/teleport) server
> this client talks to; this project is not produced, endorsed, or supported
> by Gravitational.

## Status

`v0.2.0` is the **full client product set** (D5): `TeleportCore`,
`TeleportAuth`, and `TeleportTesting`. It ships the gRPC/protobuf transport
(SwiftNIO + SwiftProtobuf), the WebAuthn/SEP machinery with the byte-exact
Go-generated fixture oracle, the three coordinators, the keyring, and the
UI-free mocks. See [`docs/PROVENANCE.md`](docs/PROVENANCE.md) for exactly what
is in and out, and [`docs/INTEGRATION.md`](docs/INTEGRATION.md) for the
Phase-2 adoption path.

Requires **Swift 6.2 / Xcode 26** and targets **iOS 16.1+ / macOS 13.3+**
(arm64). See [`docs/SPEC.md`](docs/SPEC.md).

## Provenance

The sources under `Sources/` are imported from
[`cad0p/vvterm`](https://github.com/cad0p/vvterm) at commit `291d75fb` (the
post-Stage-A tree). The 9 package-movable Teleport-derived files were
clean-room rewritten in Stage A (`ba81877c`) — authored from the public specs
and pinned by the committed Go fixtures — before entering this MIT package.
The full imported/deferred inventory, the upstream attribution, and the
host-side carve-out are in [`docs/PROVENANCE.md`](docs/PROVENANCE.md).

## License

This package is **MIT** ([`LICENSE`](LICENSE)).

The host project (`cad0p/vvterm`) is a mixed-license repository: its
remaining Teleport-derived files stay **AGPL-3.0-or-later** and are
**carved out host-side — they are not in this package**. `v0.2.0` ships no
AGPL text. The boundary is enforced in CI and documented in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Development

```bash
swift build
swift build -c release
swift test
python3 -B scripts/ci/check-package-boundaries.py
./scripts/regen-iotest-mfa.sh    # requires protoc 36.2 + protoc-gen-swift 1.38.1
```

CI runs `swift test` plus an iOS-simulator `xcodebuild build` on `macos-26`,
and a license/boundary check on ubuntu. The verification checklist is
[`docs/verification.md`](docs/verification.md).
