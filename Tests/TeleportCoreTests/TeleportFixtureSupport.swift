// SPDX-License-Identifier: MIT
//
//  TeleportFixtureSupport.swift
//  TeleportCoreTests
//
//  Shared test seams for the Teleport core:
//    - the committed fixture material under `Fixtures/` (OpenSSH certs/keys,
//      loopback TLS identities), resolved relative to this file;
//    - the pinned fixture clock (just before the fixture certs expire), so
//      the TTL check passes with the production 1h request.
//
//  Package port note (Phase 1 bootstrap): the host version re-exported three
//  constants from `MockTeleportHTTPClient` (an excluded UI-testing mock) and
//  provided fixed keypair generators conforming to the excluded
//  `TeleportSSHKeyPairGenerating` / `TeleportTLSKeyPairGenerating` protocols.
//  The constants are inlined here; the generators — and their only consumers,
//  the deferred `TeleportIssuedCertValidatorTests` and the host-side
//  `TeleportBootstrapViewWiringTests` — arrive in v0.2.0. See
//  docs/PROVENANCE.md.
//

#if DEBUG
import Foundation
@testable import TeleportCore

enum TeleportFixtureSupport {

    /// 2035-12-31T23:55:00Z — the fixture certs expire 2036-01-01T00:00:00Z.
    static let fixtureClock = Date(timeIntervalSince1970: 2_082_758_100)

    /// The fixture SSH public key the fixture user cert is bound to.
    static var fixedSSHPublicKey: String {
        fixtureString("OpenSSH/userkey_ed25519.pub")
    }

    /// The fixture user certificate (authorized_keys line).
    static var fixedIssuedUserCert: String {
        fixtureString("OpenSSH/user-cert-ed25519.pub")
    }

    /// A different fixture SSH public key (used for mismatch tests).
    static var otherSSHPublicKey: String {
        fixtureString("OpenSSH/hostkey_ed25519.pub")
    }

    /// The fixture ed25519 host certificate (used for wrong-type tests).
    static var hostCertLine: String {
        fixtureString("OpenSSH/host-cert-ed25519.pub")
    }

    static func fixtureString(_ relativePath: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relativePath)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

enum TeleportFixtureSupportError: Error {
    case tlsKeyPairUnavailable
}

#endif
