# Third-Party Notices

## Teleport (ported portions)

Source: https://github.com/gravitational/teleport
Pinned version: v18.9.1
Copyright: Gravitational, Inc. and contributors
License: GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later)

Parts of the Teleport client in the **host repository** (`cad0p/vvterm`) are
Swift ports or adaptations of Teleport source; those derivative works carry
`AGPL-3.0-or-later` headers there and are carved out of the MIT sweep.

**In this package (`swift-teleport`) there are no AGPL files.** The 9
package-movable Teleport-derived files were clean-room rewritten in Phase 1b
Stage A — authored from the public specs (W3C WebAuthn L2, CTAP2 canonical
CBOR, RFC 9562, the OpenSSH authorized_keys format, the public Teleport
client API contract) and pinned by the committed Go-generated fixtures — so
they are independent implementations of the documented contract rather than
derivative works. The files imported in `v0.2.0` are the MIT-licensed client
core; the CI `headers` job fails if an AGPL SPDX marker ever appears anywhere
in this package.

The host-side carve-out (for reference, not shipped here) is enumerated in
`cad0p/vvterm`'s `docs/teleport-derived-files.txt` (7 remaining rows:
`TeleportLiveCoordinators`, `scripts/ci/teleport-webauthn.py`, the 4 spike
SEP sources, and the Go fixture generator) and covered by its
`LICENSES/AGPL-3.0-or-later.txt`. Aggregate host licensing: the `cad0p/vvterm`
repository as distributed stays GPL-3.0; AGPL-3.0 and GPL-3.0 combination is
permitted by GPLv3 section 13.

## SwiftNIO and friends (Apache-2.0)

| Package | License | Used by |
| --- | --- | --- |
| [swift-nio](https://github.com/apple/swift-nio) | Apache-2.0 | `TeleportCore` (`NIOCore`, `NIOHTTP1`) |
| [swift-nio-http2](https://github.com/apple/swift-nio-http2) | Apache-2.0 | `TeleportCore` (`NIOHTTP2`) |
| [swift-nio-transport-services](https://github.com/apple/swift-nio-transport-services) | Apache-2.0 | `TeleportCore` (`NIOTransportServices`) |
| [swift-protobuf](https://github.com/apple/swift-protobuf) | Apache-2.0 | `TeleportCore` (generated `iotest_mfa.pb.swift`) |

Resolved transitive graph: `swift-atomics`, `swift-collections`,
`swift-system` (all Apache-2.0). Each dependency's `LICENSE.txt` is included
in its source distribution; the library does not commit `Package.resolved`.
