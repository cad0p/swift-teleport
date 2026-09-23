# Third-Party Notices

## Teleport (ported portions)

Source: https://github.com/gravitational/teleport
Pinned version: v18.9.1
Copyright: Gravitational, Inc. and contributors
License: GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later)

Parts of the Teleport client in this package are Swift ports or adaptations of
Teleport source. In the host repository (`cad0p/vvterm`) those derivative works
carry `AGPL-3.0-or-later` headers and are carved out of the MIT sweep.

**In this package (`swift-teleport`) v0.1.0 there are no AGPL files.** The
Teleport-derived files that require the AGPL carve-out stay host-side in
`cad0p/vvterm` behind the D6 seam and are replaced here by a clean-room rewrite
in `v0.2.0` (see [`docs/PROVENANCE.md`](docs/PROVENANCE.md)). The files imported
in `v0.1.0` are the dependency-closed, MIT-licensed client core; the CI
`headers` job fails if an AGPL SPDX marker ever appears anywhere in this
package.

The host-side carve-out (for reference, not shipped here) is enumerated in
`cad0p/vvterm`'s `docs/teleport-derived-files.txt` and covered by its
`LICENSES/AGPL-3.0-or-later.txt`. Aggregate host licensing: the `cad0p/vvterm`
repository as distributed stays GPL-3.0; AGPL-3.0 and GPL-3.0 combination is
permitted by GPLv3 section 13.
