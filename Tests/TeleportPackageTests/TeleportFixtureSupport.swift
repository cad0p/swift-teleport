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
@testable import TeleportCore
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

    /// The expired fixture host certificate (valid 2020-01-01 → 2021-01-01):
    /// pins that a parseable but out-of-window PEM is rejected even when the
    /// stored `certValidBefore` is in the future.
    static var expiredHostCertLine: String {
        fixtureString("OpenSSH/host-cert-expired.pub")
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

    // MARK: - Attempt-tagged credential fixtures (the pair-atomicity tests)

    /// 2036-01-01T00:05:00Z — later than the real `Date()` (the live-cert gate
    /// in `TeleportCredential.isCertValid` compares to `Date()`, not to the
    /// injected clock) and inside the requested 1h TTL window from
    /// `fixtureClock`.
    static let attemptCertValidBefore = fixtureClock.addingTimeInterval(600)

    /// The authorized_keys line for a raw 32-byte ed25519 key whose decoded
    /// `.blob` is `sshString("ssh-ed25519") + sshString(rawKey)` — the exact
    /// blob `TeleportIssuedCertValidator` compares the issued cert against.
    static func authorizedKeysLine(rawKey: Data, comment: String = "vvterm-attempt") -> String {
        var blob = Data()
        blob.append(OpenSSHCertificate.sshString(Data("ssh-ed25519".utf8)))
        blob.append(OpenSSHCertificate.sshString(rawKey))
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    /// Build a synthetic OpenSSH user certificate bound to `rawKey`, accepted
    /// by `TeleportIssuedCertValidator` for the matching generated keypair.
    /// Returns the bare-base64 blob form that
    /// `OpenSSHCertificate.parse(authorizedKeysOrPEM:)` accepts; the signature
    /// fields are placeholders (nothing verifies the CA signature locally).
    ///
    /// Lifted from `TeleportIssuedCertValidatorTests`' inline builder (which
    /// keeps its own copy for its rejection shapes) so each attempt can be
    /// minted its own cert.
    static func makeSynthUserCert(
        rawKey: Data,
        keyID: String,
        principals: [String] = ["alice"],
        validAfter: Date = fixtureClock.addingTimeInterval(-60),
        validBefore: Date = attemptCertValidBefore
    ) -> String {
        var blob = Data()
        blob.append(OpenSSHCertificate.sshString(Data("ssh-ed25519-cert-v01@openssh.com".utf8)))
        blob.append(OpenSSHCertificate.sshString(Data(repeating: 0x11, count: 32)))
        blob.append(OpenSSHCertificate.sshString(rawKey))
        blob.append(uint64(0))                                  // serial
        blob.append(uint32(1))                                  // user
        blob.append(OpenSSHCertificate.sshString(Data(keyID.utf8)))
        var principalsBlob = Data()
        for principal in principals {
            principalsBlob.append(OpenSSHCertificate.sshString(Data(principal.utf8)))
        }
        blob.append(OpenSSHCertificate.sshString(principalsBlob))
        blob.append(uint64(UInt64(validAfter.timeIntervalSince1970)))
        blob.append(uint64(UInt64(validBefore.timeIntervalSince1970)))
        blob.append(OpenSSHCertificate.sshString(Data()))       // critical options
        blob.append(OpenSSHCertificate.sshString(Data()))       // extensions
        blob.append(OpenSSHCertificate.sshString(Data()))       // reserved
        blob.append(OpenSSHCertificate.sshString(Data(repeating: 0x33, count: 51)))
        blob.append(OpenSSHCertificate.sshString(Data(repeating: 0x44, count: 64)))
        return blob.base64EncodedString()
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    private static func uint64(_ value: UInt64) -> Data {
        var data = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
        return data
    }
}

/// A `TeleportSSHKeyPairGenerating` that returns a distinct, pre-built keypair
/// per `generateKeyPair` call, in call order, so each coordinator attempt can
/// be tagged with its own key/cert pair. The coordinators call it once per
/// attempt (login/boot `begin`).
final class AttemptTaggedSSHKeyPairGenerator: TeleportSSHKeyPairGenerating {
    nonisolated deinit {}

    struct AttemptKeyPair {
        let rawKey: Data
        let publicKeyLine: String
        let privateKeyPEM: String
    }

    let attempts: [AttemptKeyPair]
    private var callIndex = 0

    init(attemptCount: Int) {
        precondition(attemptCount > 0, "at least one attempt is needed")
        attempts = (0..<attemptCount).map { index in
            let rawKey = Data(repeating: 0x40 + UInt8(index), count: 32)
            return AttemptKeyPair(
                rawKey: rawKey,
                publicKeyLine: TeleportFixtureSupport.authorizedKeysLine(rawKey: rawKey),
                privateKeyPEM: "attempt-\(index + 1)-ed25519-private-key"
            )
        }
    }

    func generateKeyPair(comment: String) -> (publicKey: String, privateKeyPEM: String) {
        let pair = attempts[min(callIndex, attempts.count - 1)]
        callIndex += 1
        return (pair.publicKeyLine, pair.privateKeyPEM)
    }
}

/// A per-attempt `HeadlessLoginResponse` whose cert is bound to the attempt's
/// generated keypair and whose TLS cert matches the committed fixture TLS
/// keypair, so the bootstrap coordinator's binding checks pass for each
/// attempt. `validBefore`/`principals` default to the shared attempt fixture;
/// the T1 tests pass a distinct `validBefore` per attempt so a stale attempt's
/// terminal `.success`/`lastBootstrapResult` is distinguishable from the newer
/// attempt's.
extension TeleportFixtureSupport {
    static func makeAttemptHeadlessResponse(
        attempt: Int,
        generator: AttemptTaggedSSHKeyPairGenerator,
        cluster: TeleportCluster,
        clusterName: String = "teleport.pcad.it",
        validBefore: Date = attemptCertValidBefore,
        principals: [String] = ["alice"]
    ) -> HeadlessLoginResponse {
        let certLine = makeSynthUserCert(
            rawKey: generator.attempts[attempt].rawKey,
            keyID: cluster.username,
            principals: principals,
            validBefore: validBefore
        )
        let tlsPEM = fixtureString("loopback-tls/server.pem")
        let hostSigner = HeadlessLoginResponse.TrustedCerts(
            clusterName: clusterName,
            checkingKeys: [],
            tlsCerts: [Data(tlsPEM.utf8).base64EncodedString()]
        )
        return HeadlessLoginResponse(
            cert: Data(certLine.utf8).base64EncodedString(),
            tlsCert: Data(tlsPEM.utf8).base64EncodedString(),
            hostSigners: [hostSigner]
        )
    }

    static func makeAttemptLoginFinishResponse(
        attempt: Int,
        generator: AttemptTaggedSSHKeyPairGenerator,
        cluster: TeleportCluster,
        validBefore: Date = attemptCertValidBefore,
        principals: [String] = ["alice"]
    ) -> LoginFinishResponse {
        let certLine = makeSynthUserCert(
            rawKey: generator.attempts[attempt].rawKey,
            keyID: cluster.username,
            principals: principals,
            validBefore: validBefore
        )
        return LoginFinishResponse(cert: Data(certLine.utf8).base64EncodedString(), hostSigners: nil)
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
