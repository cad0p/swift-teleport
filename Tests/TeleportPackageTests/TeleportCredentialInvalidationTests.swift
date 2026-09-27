// SPDX-License-Identifier: MIT
//
//  TeleportCredentialInvalidationTests.swift
//  TeleportPackageTests
//
//  Coverage for the Teleport credential-invalidation seam, ported from the
//  host's `VVTermTests/Features/Teleport/TeleportCredentialInvalidationTests.swift`
//  at `30ac5388` minus the `ServerManager` wiring half (the row-update /
//  CloudKit-merge / delete triggers are host-only app policy).
//
//  Pinned here: the pure clear rule (host change clears; same-host rename back
//  to the credential's own user keeps; node-name/port never clear; a row with
//  no credential is untouched) and the real keyring's conformance
//  (`hasCredential` is record presence, not cert presence; `certKeyID` parses
//  the stored PEM regardless of validity; `clearCredential` clears).
//

import Foundation
import Testing
import TeleportCore
@testable import TeleportAuth
import TeleportTesting

struct TeleportCredentialInvalidationPolicyTests {

    @Test
    func noCredentialNeverClears() {
        #expect(
            !TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "old.example.com",
                newHost: "new.example.com",
                oldUsername: "pier",
                newUsername: "deploy",
                hasCredential: false,
                certKeyID: "pier"
            )
        )
    }

    @Test
    func hostChangeClears() {
        #expect(
            TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "old.example.com",
                newHost: "new.example.com",
                oldUsername: "pier",
                newUsername: "pier",
                hasCredential: true,
                certKeyID: "pier"
            )
        )
    }

    @Test
    func usernameChangeToADifferentUserClears() {
        #expect(
            TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "teleport.example.com",
                newHost: "teleport.example.com",
                oldUsername: "pier",
                newUsername: "someone-else",
                hasCredential: true,
                certKeyID: "pier"
            )
        )
    }

    @Test
    func usernameChangeWithNoCertClears() {
        // A seeded record has no cert keyID; a username edit must still clear.
        #expect(
            TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "teleport.example.com",
                newHost: "teleport.example.com",
                oldUsername: "pier",
                newUsername: "someone-else",
                hasCredential: true,
                certKeyID: nil
            )
        )
    }

    @Test
    func sameHostRenameBackToTheCredentialsOwnUserKeeps() {
        #expect(
            !TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "teleport.example.com",
                newHost: "teleport.example.com",
                oldUsername: "typo",
                newUsername: "pier",
                hasCredential: true,
                certKeyID: "pier"
            )
        )
    }

    @Test
    func nodeNameOrPortChangesNeverClear() {
        // The policy only sees host/username; a node-name or port edit leaves
        // both unchanged.
        #expect(
            !TeleportCredentialInvalidationPolicy.shouldClearCredential(
                oldHost: "teleport.example.com",
                newHost: "teleport.example.com",
                oldUsername: "pier",
                newUsername: "pier",
                hasCredential: true,
                certKeyID: "pier"
            )
        )
    }
}

@MainActor
struct TeleportKeyRingInvalidationConformanceTests {

    private func makeIsolatedKeyRing() -> (TeleportKeyRing, MockSEPKeySigner) {
        let suiteName = "TeleportKeyRingInvalidationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let signer = MockSEPKeySigner(outcome: .success)
        let keyRing = TeleportKeyRing(
            signer: signer,
            logging: DefaultTeleportLogging(),
            config: TeleportKeychainConfig(
                keychainService: "it.pcad.swift-teleport.tests",
                defaults: defaults
            )
        )
        return (keyRing, signer)
    }

    @Test
    func recordPresenceIsNotCertPresence() throws {
        let (keyRing, signer) = makeIsolatedKeyRing()
        let clusterId = UUID()

        // No record at all.
        #expect(!keyRing.hasCredential(for: clusterId))
        #expect(keyRing.certKeyID(for: clusterId) == nil)

        // A registered record with no cert (the shape a reuse-seeded row has
        // before its Face ID login) still counts as a credential.
        _ = try signer.createKey(credentialID: Data([1, 2, 3]))
        keyRing.storeRegisteredSEPKey(
            credentialID: Data([1, 2, 3]),
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9]),
            deviceName: "dev",
            for: clusterId
        )
        #expect(keyRing.credentials[clusterId]?.sshCertPEM == nil)
        #expect(keyRing.hasCredential(for: clusterId))
        #expect(keyRing.certKeyID(for: clusterId) == nil)

        keyRing.clearCredential(for: clusterId)
        #expect(!keyRing.hasCredential(for: clusterId))
        #expect(keyRing.credentials[clusterId] == nil)
    }

    @Test
    func certKeyIDParsesTheStoredPEMRegardlessOfValidity() {
        let (keyRing, _) = makeIsolatedKeyRing()
        let clusterId = UUID()

        keyRing.storeBootstrapCert(
            TeleportFixtureSupport.fixedIssuedUserCert,
            validBefore: Date().addingTimeInterval(3600),
            for: clusterId
        )
        #expect(keyRing.certKeyID(for: clusterId) == "user-cert-ed25519")

        // An expired certificate still yields its keyID: the policy needs the
        // identity, not validity (readiness is what gates on validity).
        keyRing.storeBootstrapCert(
            TeleportFixtureSupport.expiredHostCertLine,
            validBefore: Date().addingTimeInterval(3600),
            for: clusterId
        )
        #expect(keyRing.certKeyID(for: clusterId) == "host-cert-expired")

        // An unparseable PEM yields nil, never a guess.
        keyRing.storeBootstrapCert(
            "cert-pem",
            validBefore: Date().addingTimeInterval(3600),
            for: clusterId
        )
        #expect(keyRing.certKeyID(for: clusterId) == nil)
        #expect(keyRing.hasCredential(for: clusterId))
    }
}
