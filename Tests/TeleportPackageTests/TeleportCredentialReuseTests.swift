// SPDX-License-Identifier: MIT
//
//  TeleportCredentialReuseTests.swift
//  TeleportPackageTests
//
//  Coverage for duplicate-server credential reuse, ported from the host's
//  `VVTermTests/Features/Teleport/TeleportCredentialReuseTests.swift` at
//  `30ac5388`:
//    - the pure matcher's `(host, username)` + cluster-name key and the
//      completeness gate (a deleted row's credential is never offered);
//    - the keyring's `isReusableRegistrationSource` precondition;
//    - `seedRegistration` copying the metadata + cluster TLS state but NOT the
//      cert (so the readiness resolver routes to `.needsLogin` and the picker
//      still shows).
//
//  Package adaptations: the matcher half runs against a local
//  `TeleportCredentialReuseRow` conformer instead of the host's `Server` (the
//  host conforms `Server` to the protocol in Phase 2), and the real-keyring
//  half never writes the ed25519 key to the keychain — the "key is not
//  copied" half is pinned on the in-memory mock instead, so the suite stays
//  hermetic.
//

import Foundation
import Testing
import TeleportCore
@testable import TeleportAuth
import TeleportTesting

/// A `TeleportCredentialReuseRow` stand-in for the host's `Server` (which
/// conforms to the protocol in Phase 2).
private struct TestReuseRow: TeleportCredentialReuseRow {
    var id: UUID = UUID()
    var displayName: String = "node"
    var host: String = "teleport.example.com"
    var username: String = "pier"
    var isFaceIDTeleport: Bool = true
}

struct TeleportCredentialReuseMatcherTests {

    private func makeCredential(clusterId: UUID, credentialID: String = "cred") -> TeleportCredential {
        TeleportCredential(
            clusterId: clusterId,
            credentialID: credentialID,
            userHandle: "handle",
            publicKeyRaw: "key",
            deviceName: "device"
        )
    }

    private func match(
        new: TestReuseRow,
        live: [TestReuseRow],
        credentials: [UUID: TeleportCredential],
        clusterNames: [UUID: String] = [:],
        isReusable: @escaping (UUID) -> Bool = { _ in true }
    ) -> TestReuseRow? {
        TeleportCredentialReuse.match(
            newRow: new,
            liveRows: live,
            credentials: credentials,
            clusterName: { clusterNames[$0] },
            isReusable: isReusable
        )
    }

    @Test
    func matchesAHostAndUserDuplicate() {
        let source = TestReuseRow(displayName: "source")
        let new = TestReuseRow(displayName: "duplicate")
        let result = match(
            new: new,
            live: [source],
            credentials: [source.id: makeCredential(clusterId: source.id)]
        )
        #expect(result?.id == source.id)
    }

    @Test
    func doesNotMatchItselfOrNonTeleportRows() {
        let new = TestReuseRow()
        let passwordRow = TestReuseRow(
            displayName: "password-row",
            host: new.host,
            username: new.username,
            isFaceIDTeleport: false
        )
        let result = match(
            new: new,
            live: [new, passwordRow],
            credentials: [
                new.id: makeCredential(clusterId: new.id),
                passwordRow.id: makeCredential(clusterId: passwordRow.id)
            ]
        )
        #expect(result == nil)
    }

    @Test
    func doesNotMatchADifferentHostOrUser() {
        let otherHost = TestReuseRow(host: "other.example.com")
        let otherUser = TestReuseRow(username: "someone-else")
        let new = TestReuseRow()
        let credentials: [UUID: TeleportCredential] = [
            otherHost.id: makeCredential(clusterId: otherHost.id),
            otherUser.id: makeCredential(clusterId: otherUser.id)
        ]
        #expect(match(new: new, live: [otherHost], credentials: credentials) == nil)
        #expect(match(new: new, live: [otherUser], credentials: credentials) == nil)
    }

    @Test
    func doesNotOfferADeletedRowsCredential() {
        // The source must be a LIVE server row: a credential left behind for a
        // deleted row (the record is cleared on delete, but a stale store
        // could persist one) is never offered.
        let deleted = TestReuseRow()
        let new = TestReuseRow()
        let result = match(
            new: new,
            live: [],  // the row is gone from the live list
            credentials: [deleted.id: makeCredential(clusterId: deleted.id)]
        )
        #expect(result == nil)
    }

    @Test
    func doesNotMatchWithoutACredentialRecord() {
        let source = TestReuseRow()
        let new = TestReuseRow()
        #expect(match(new: new, live: [source], credentials: [:]) == nil)
    }

    @Test
    func completenessGateIsHonored() {
        let source = TestReuseRow()
        let new = TestReuseRow()
        let result = match(
            new: new,
            live: [source],
            credentials: [source.id: makeCredential(clusterId: source.id)],
            isReusable: { _ in false }
        )
        #expect(result == nil)
    }

    @Test
    func clusterNameMustMatchWhenTheNewRowKnowsIt() {
        let source = TestReuseRow()
        let new = TestReuseRow()
        let credentials = [source.id: makeCredential(clusterId: source.id)]

        // The new row has a cluster identity (a re-setup): the candidate must
        // belong to the same cluster.
        #expect(
            match(
                new: new,
                live: [source],
                credentials: credentials,
                clusterNames: [new.id: "cluster-b", source.id: "cluster-a"]
            ) == nil
        )
        #expect(
            match(
                new: new,
                live: [source],
                credentials: credentials,
                clusterNames: [new.id: "cluster-a", source.id: "cluster-a"]
            )?.id == source.id
        )
    }

    @Test
    func brandNewRowWithoutAClusterNameMatchesOnHostAndUser() {
        let source = TestReuseRow()
        let new = TestReuseRow()
        let result = match(
            new: new,
            live: [source],
            credentials: [source.id: makeCredential(clusterId: source.id)],
            clusterNames: [source.id: "cluster-a"]
        )
        #expect(result?.id == source.id)
    }

    @Test
    func firstSourceIsChosenDeterministically() {
        let beta = TestReuseRow(displayName: "beta")
        let alpha = TestReuseRow(displayName: "alpha")
        let new = TestReuseRow()
        let result = match(
            new: new,
            live: [beta, alpha],
            credentials: [
                beta.id: makeCredential(clusterId: beta.id),
                alpha.id: makeCredential(clusterId: alpha.id)
            ]
        )
        #expect(result?.id == alpha.id, "sources are ordered by display name")
    }
}

@MainActor
struct TeleportKeyRingReuseTests {

    private func makeIsolatedKeyRing() -> (TeleportKeyRing, MockSEPKeySigner) {
        let suiteName = "TeleportKeyRingReuseTests-\(UUID().uuidString)"
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

    private func seedCompleteSetup(
        keyRing: TeleportKeyRing,
        signer: MockSEPKeySigner,
        clusterId: UUID,
        credentialID: Data = Data([1, 2, 3, 4]),
        clusterName: String = "ci-cluster",
        checkingKeys: [String] = ["ssh-ed25519 AAAA host-ca"]
    ) throws {
        keyRing.storeRegisteredSEPKey(
            credentialID: credentialID,
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9]),
            deviceName: "device",
            for: clusterId
        )
        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: clusterName,
                clusterCAPEMs: ["ca-pem"],
                hostCACheckingKeys: checkingKeys
            ),
            for: clusterId
        )
        _ = try signer.createKey(credentialID: credentialID)
    }

    @Test
    func reusableOnlyForACompleteLiveRegistration() throws {
        let (keyRing, signer) = makeIsolatedKeyRing()
        let id = UUID()

        // No record at all.
        #expect(!keyRing.isReusableRegistrationSource(for: id, clusterName: nil))

        // Record but no SEP key.
        let (noKeyRing, _) = makeIsolatedKeyRing()
        noKeyRing.storeRegisteredSEPKey(
            credentialID: Data([1, 2, 3, 4]),
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9]),
            deviceName: "device",
            for: id
        )
        noKeyRing.storeClusterTLSState(
            TeleportClusterTLSState(clusterName: "ci-cluster", clusterCAPEMs: ["ca"], hostCACheckingKeys: ["k"]),
            for: id
        )
        #expect(!noKeyRing.isReusableRegistrationSource(for: id, clusterName: nil))

        // Complete setup.
        try seedCompleteSetup(keyRing: keyRing, signer: signer, clusterId: id)
        #expect(keyRing.isReusableRegistrationSource(for: id, clusterName: nil))
        #expect(keyRing.isReusableRegistrationSource(for: id, clusterName: "ci-cluster"))
        #expect(!keyRing.isReusableRegistrationSource(for: id, clusterName: "other-cluster"))
    }

    @Test
    func legacySetupWithNoCheckingKeysIsNotReusable() throws {
        let (keyRing, signer) = makeIsolatedKeyRing()
        let id = UUID()
        try seedCompleteSetup(keyRing: keyRing, signer: signer, clusterId: id, checkingKeys: [])
        #expect(!keyRing.isReusableRegistrationSource(for: id, clusterName: nil))
    }

    @Test
    func seedingCopiesMetadataAndTLSStateButNotTheCert() throws {
        let (keyRing, signer) = makeIsolatedKeyRing()
        let sourceId = UUID()
        let targetId = UUID()
        let credentialID = Data([7, 7, 7, 7])
        try seedCompleteSetup(keyRing: keyRing, signer: signer, clusterId: sourceId, credentialID: credentialID)
        let validBefore = Date().addingTimeInterval(3600)
        keyRing.storeLoginCert(TeleportFixtureSupport.fixedIssuedUserCert, validBefore: validBefore, for: sourceId)

        #expect(keyRing.seedRegistration(from: sourceId, to: targetId))

        let seeded = try #require(keyRing.credentials[targetId])
        #expect(seeded.credentialID == keyRing.credentials[sourceId]?.credentialID)
        #expect(seeded.userHandle == keyRing.credentials[sourceId]?.userHandle)
        #expect(seeded.publicKeyRaw == keyRing.credentials[sourceId]?.publicKeyRaw)
        #expect(seeded.deviceName == keyRing.credentials[sourceId]?.deviceName)
        #expect(seeded.sshCertPEM == nil, "the certificate must not be copied")
        #expect(seeded.hasLiveCert == false)
        #expect(keyRing.clusterTLSState(for: targetId)?.clusterName == "ci-cluster")
        #expect(keyRing.liveEd25519PrivateKey(for: targetId) == nil, "the ed25519 key must not be copied")

        // The whole point: the seeded row needs the Face ID login (and shows
        // the picker), not a connect.
        #expect(keyRing.readiness(for: targetId) == .needsLogin)
    }

    @Test
    func seedingRefusesIncompleteSources() {
        let (keyRing, _) = makeIsolatedKeyRing()
        let sourceId = UUID()
        let targetId = UUID()
        #expect(!keyRing.seedRegistration(from: sourceId, to: targetId))
        #expect(!keyRing.seedRegistration(from: targetId, to: targetId))
    }

    /// The mock's counterpart of the seeding test: the mock holds the ed25519
    /// key in memory, so the "the key is not copied" half is pinned here
    /// (the real-keyring suite never writes to the test process's keychain).
    @Test
    func mockSeedingCopiesMetadataAndTLSStateButNotTheCertOrKey() throws {
        let mock = MockTeleportKeyRing()
        let sourceId = UUID()
        let targetId = UUID()
        let credentialID = Data([7, 7, 7, 7])
        mock.seed(
            clusterId: sourceId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: true,
                hasSEPKey: true,
                certValidBefore: Date().addingTimeInterval(3600),
                credentialID: credentialID,
                userHandle: Data("handle".utf8),
                deviceName: "device"
            )
        )
        mock.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: "ci-cluster",
                clusterCAPEMs: ["ca-pem"],
                hostCACheckingKeys: ["ssh-ed25519 AAAA host-ca"]
            ),
            for: sourceId
        )
        mock.storeLoginCert(
            TeleportFixtureSupport.fixedIssuedUserCert,
            validBefore: Date().addingTimeInterval(3600),
            for: sourceId
        )
        try mock.storeEd25519PrivateKey(Data("source-key".utf8), for: sourceId)

        #expect(mock.isReusableRegistrationSource(for: sourceId, clusterName: "ci-cluster"))
        #expect(mock.seedRegistration(from: sourceId, to: targetId))

        let seeded = try #require(mock.credentials[targetId])
        #expect(seeded.credentialID == mock.credentials[sourceId]?.credentialID)
        #expect(seeded.sshCertPEM == nil, "the certificate must not be copied")
        #expect(mock.liveEd25519PrivateKey(for: sourceId) != nil)
        #expect(mock.liveEd25519PrivateKey(for: targetId) == nil, "the ed25519 key must not be copied")
        #expect(mock.clusterTLSState(for: targetId)?.clusterName == "ci-cluster")
        #expect(mock.readiness(for: targetId) == .needsLogin)
    }
}
