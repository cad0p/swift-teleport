// SPDX-License-Identifier: MIT
//
//  TeleportFixtureSupport.swift
//  TeleportPackageTests
//
//  Shared test seams for the Teleport coordinators:
//    - fixed SSH/TLS keypair generators bound to the committed fixtures, so
//      the issued-certificate binding checks are exercisable with a static
//      certificate;
//    - the pinned fixture clock (just before the fixture certs expire), so
//      the TTL check passes with the production 1h request;
//    - the fixture-bound HTTP response factories the host's
//      `MockTeleportHTTPClient` used to carry (the package mock is
//      fixture-free; the payloads live with the tests).
//
//  Fixture root: this target hosts Core- and Auth-subject suites, so the
//  OpenSSH / loopback-TLS material it shares with the Core suites is read from
//  the single canonical tree at `Tests/TeleportCoreTests/Fixtures/` — there is
//  exactly one copy, so the two targets cannot drift. The SEPWebAuthn Go
//  fixtures are Auth-only and stay in this target under `Fixtures/SEPWebAuthn/`.
//

import Foundation
import Security
import TeleportCore
import TeleportAuth
import TeleportTesting

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

    /// Resolves a fixture under the canonical Core test tree
    /// (`Tests/TeleportCoreTests/Fixtures/`).
    static func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportPackageTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("TeleportCoreTests/Fixtures/\(relativePath)")
    }

    static func fixtureString(_ relativePath: String) -> String {
        (try? String(contentsOf: fixtureURL(relativePath), encoding: .utf8)) ?? ""
    }

    /// The fixture TLS certificate + key (`loopback-tls/server.pem|p12`).
    static func fixedTLSKeyPair() -> TLSKeyPair? {
        guard let data = try? Data(contentsOf: fixtureURL("loopback-tls/server.p12")) else {
            return nil
        }
        var options: [String: Any] = [kSecImportExportPassphrase as String: "vvterm-test"]
        if #available(macOS 15.0, iOS 18.0, *) {
            options[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]],
              let identity = entries.first?[kSecImportItemIdentity as String] else {
            return nil
        }
        let secIdentity = identity as! SecIdentity
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(secIdentity, &privateKey) == errSecSuccess,
              let privateKey,
              let pem = try? String(contentsOf: fixtureURL("loopback-tls/server.pem"), encoding: .utf8) else {
            return nil
        }
        return TLSKeyPair(privateKey: privateKey, publicKeyPEM: pem)
    }

    /// A success response whose `cert` / `tls_cert` are bound to the fixture
    /// keypair + TLS keypair — i.e. it passes `TeleportIssuedCertValidator`
    /// when the coordinator is driven with `fixedSSHPublicKey` /
    /// `fixedTLSKeyPair()` and `fixtureClock`.
    static func makeFixtureSuccessResponse(clusterName: String = "teleport.pcad.it") -> HeadlessLoginResponse {
        let certPEM = fixedIssuedUserCert
        let tlsPEM = (try? String(contentsOf: fixtureURL("loopback-tls/server.pem"), encoding: .utf8)) ?? ""
        let hostSigner = HeadlessLoginResponse.TrustedCerts(
            clusterName: clusterName,
            checkingKeys: [],
            tlsCerts: [Data(tlsPEM.utf8).base64EncodedString()]
        )
        return HeadlessLoginResponse(
            cert: Data(certPEM.utf8).base64EncodedString(),
            tlsCert: Data(tlsPEM.utf8).base64EncodedString(),
            hostSigners: [hostSigner]
        )
    }

    /// A `login/finish` response carrying the fixture user certificate.
    static func makeFixtureLoginFinishResponse() -> LoginFinishResponse {
        LoginFinishResponse(
            cert: Data(fixedIssuedUserCert.utf8).base64EncodedString(),
            hostSigners: nil
        )
    }

    static func makeFixedSSHGenerator(publicKey: String = TeleportFixtureSupport.fixedSSHPublicKey) -> FixedTeleportSSHKeyPairGenerator {
        FixedTeleportSSHKeyPairGenerator(publicKey: publicKey)
    }

    static func makeFixedTLSGenerator() throws -> FixedTeleportTLSKeyPairGenerator {
        guard let keyPair = fixedTLSKeyPair() else {
            throw TeleportFixtureSupportError.tlsKeyPairUnavailable
        }
        return FixedTeleportTLSKeyPairGenerator(keyPair: keyPair)
    }
}

enum TeleportFixtureSupportError: Error {
    case tlsKeyPairUnavailable
    /// A fixture the suite depends on is absent or unreadable. Failing loud
    /// matters because `fixtureString` returns `""` on a read error, and an
    /// empty expected value can make a "same value" assertion vacuous.
    case missingFixture(String)
}

/// Returns a fixed ed25519 public key (the fixture cert's subject key).
final class FixedTeleportSSHKeyPairGenerator: TeleportSSHKeyPairGenerating {
    nonisolated deinit {}
    let publicKey: String
    let privateKeyPEM: String

    init(publicKey: String, privateKeyPEM: String = "fixed-test-ed25519-private-key") {
        self.publicKey = publicKey
        self.privateKeyPEM = privateKeyPEM
    }

    func generateKeyPair(comment: String) -> (publicKey: String, privateKeyPEM: String) {
        (publicKey, privateKeyPEM)
    }
}

/// Returns a fixed TLS keypair (the fixture loopback identity).
final class FixedTeleportTLSKeyPairGenerator: TeleportTLSKeyPairGenerating {
    nonisolated deinit {}
    let keyPair: TLSKeyPair

    init(keyPair: TLSKeyPair) {
        self.keyPair = keyPair
    }

    func generate() throws -> TLSKeyPair {
        keyPair
    }
}
