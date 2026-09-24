// SPDX-License-Identifier: MIT
//
//  TeleportCertBindingCoordinatorTests.swift
//  TeleportPackageTests
//
//  Coordinator-level coverage for the issued-certificate binding checks: the
//  login (Phase 3) and bootstrap (Phase 1) coordinators must store nothing
//  when the issued cert does not match the generated keypair.
//
//  Ported from the host's `VVTermTests/Features/Teleport/
//  TeleportCertBindingCoordinatorTests.swift` at `291d75fb`. The subject (the
//  coordinators + the keyring) lives in this package now, so the coverage has
//  to live here too: the host copies are deleted in Phase 2, and the
//  validator-level suites (`TeleportIssuedCertValidatorTests`) alone do not
//  pin the *coordinator* contract of storing nothing on a mismatch.
//
//  Adaptations for this target: `@testable import VVTerm` becomes the three
//  package modules, the `#if DEBUG` gate is dropped (this is a test target),
//  and the fixture helpers come from `TeleportFixtureSupport` (the single
//  canonical fixture tree). The test bodies are otherwise unchanged.
//

import Foundation
import Security
import Testing
import TeleportCore
@testable import TeleportAuth
import TeleportTesting

@MainActor
struct TeleportCertBindingCoordinatorTests {

    /// Fail loud when a fixture this suite reads is missing: `fixtureString`
    /// returns `""` on a read error, which would make the "same key set"
    /// assertions pass vacuously.
    init() throws {
        for name in [
            "OpenSSH/ca_ed25519.pub",
            "OpenSSH/ca_foreign.pub",
            "OpenSSH/user-cert-ed25519.pub",
            "OpenSSH/hostkey_ed25519.pub",
            "OpenSSH/host-cert-ed25519.pub",
            "loopback-tls/server.pem",
            "loopback-tls/server-wrongname.pem",
        ] where TeleportFixtureSupport.fixtureString(name).isEmpty {
            throw TeleportFixtureSupportError.missingFixture(name)
        }
    }

    private func makeCluster() -> TeleportCluster {
        TeleportCluster(host: "teleport.pcad.it", username: "pier")
    }

    private func makeRegisteredKeyRing(clusterId: UUID, credentialID: Data = Data([1, 2, 3, 4])) -> MockTeleportKeyRing {
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: credentialID,
                userHandle: Data("user-handle".utf8),
                deviceName: "test-device"
            )
        )
        return keyRing
    }

    private func makeLoginCoordinator(
        http: MockTeleportHTTPClient,
        keyRing: MockTeleportKeyRing,
        credentialID: Data,
        publicKey: String,
        now: @escaping () -> Date
    ) throws -> TeleportLoginCoordinator {
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        return TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            keyPairGenerator: FixedTeleportSSHKeyPairGenerator(publicKey: publicKey),
            now: now
        )
    }

    // MARK: - Host CA refresh from the login response

    private static let pinnedHostCA = TeleportFixtureSupport
        .fixtureString("OpenSSH/ca_ed25519.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let rotatedHostCA = TeleportFixtureSupport
        .fixtureString("OpenSSH/ca_foreign.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    private func makeLoginFinishResponse(
        domainName: String,
        checkingKeys: [String]
    ) -> LoginFinishResponse {
        LoginFinishResponse(
            cert: Data(TeleportFixtureSupport.fixedIssuedUserCert.utf8).base64EncodedString(),
            hostSigners: [
                LoginFinishResponse.HostSigner(domainName: domainName, checkingKeys: checkingKeys)
            ]
        )
    }

    /// A matching `domain_name` lets the additions-only refresh grow the
    /// pinned checking-key set; the outer TLS anchors stay byte-identical.
    @Test
    func loginRefreshAppliesAdditionsForThePinnedCluster() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: "teleport.pcad.it",
                clusterCAPEMs: ["pinned-pem"],
                hostCACheckingKeys: [Self.pinnedHostCA]
            ),
            for: cluster.id
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = makeLoginFinishResponse(
            domainName: "teleport.pcad.it",
            checkingKeys: [Self.pinnedHostCA, Self.rotatedHostCA]
        )

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey,
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        #expect(keyRing.clusterTLSState(for: cluster.id)?.hostCACheckingKeys == [Self.pinnedHostCA, Self.rotatedHostCA])
        #expect(keyRing.clusterTLSState(for: cluster.id)?.clusterCAPEMs == ["pinned-pem"])
    }

    /// A login response whose `domain_name` does not name the pinned cluster
    /// must skip the refresh entirely: the pinned keys and the outer TLS
    /// anchors stay as captured at bootstrap.
    @Test
    func loginRefreshSkipsAMismatchedDomainName() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: "teleport.pcad.it",
                clusterCAPEMs: ["pinned-pem"],
                hostCACheckingKeys: [Self.pinnedHostCA]
            ),
            for: cluster.id
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = makeLoginFinishResponse(
            domainName: "other.example.com",
            checkingKeys: [Self.pinnedHostCA, Self.rotatedHostCA]
        )

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey,
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        #expect(keyRing.clusterTLSState(for: cluster.id)?.hostCACheckingKeys == [Self.pinnedHostCA])
        #expect(keyRing.clusterTLSState(for: cluster.id)?.clusterCAPEMs == ["pinned-pem"])
    }

    // MARK: - Phase 3 login

    @Test
    func loginStoresCertBoundToTheKeypair() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey,
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        #expect(coordinator.state == .success(certValidUntil: Date(timeIntervalSince1970: 2_082_758_400)))
        #expect(keyRing.liveCertPEM(for: cluster.id) == TeleportFixtureSupport.fixedIssuedUserCert)
        #expect(keyRing.liveEd25519PrivateKey(for: cluster.id) != nil)
    }

    @Test
    func loginRejectsCertWithMismatchedKeyAndStoresNothing() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.otherSSHPublicKey,
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
        #expect(keyRing.liveEd25519PrivateKey(for: cluster.id) == nil)
    }

    @Test
    func loginRejectsCertWithExcessiveTTLAndStoresNothing() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey,
            // 2027-01-01 — far more than 1h before the fixture cert expires.
            now: { Date(timeIntervalSince1970: 1_798_761_600) }
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
    }

    @Test
    func loginRejectsHostCertificateAndStoresNothing() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = LoginFinishResponse(
            cert: Data(TeleportFixtureSupport.hostCertLine.utf8).base64EncodedString(),
            hostSigners: nil
        )

        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: keyRing,
            credentialID: credentialID,
            publicKey: TeleportFixtureSupport.otherSSHPublicKey,
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
    }

    // MARK: - Phase 1 bootstrap

    private func makeBootstrapCoordinator(
        http: MockTeleportHTTPClient,
        keyRing: MockTeleportKeyRing,
        publicKey: String
    ) throws -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: keyRing,
            safariPresenter: nil,
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: FixedTeleportSSHKeyPairGenerator(publicKey: publicKey),
            tlsKeyPairGenerator: try TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    @Test
    func bootstrapStoresCertAndClusterStateWhenEverythingMatches() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()

        let coordinator = try makeBootstrapCoordinator(
            http: http,
            keyRing: keyRing,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey
        )
        await coordinator.begin(cluster: cluster)

        #expect(coordinator.state == .success)
        #expect(keyRing.liveCertPEM(for: cluster.id) == TeleportFixtureSupport.fixedIssuedUserCert)
        #expect(keyRing.clusterTLSState(for: cluster.id) != nil)
    }

    @Test
    func bootstrapKeychainFailureStillPersistsCertAndTLSStateAndSucceeds() async throws {
        // A failing `storeEd25519PrivateKey` (keychain) must be non-fatal:
        // the cert + cluster TLS state still persist and the coordinator
        // still reaches `.success`. The SSH connect will fail with
        // teleportCertMissing and surface the re-bootstrap UX.
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()

        let coordinator = try makeBootstrapCoordinator(
            http: http,
            keyRing: keyRing,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey
        )
        await coordinator.begin(cluster: cluster)

        #expect(coordinator.state == .success)
        #expect(keyRing.liveCertPEM(for: cluster.id) == TeleportFixtureSupport.fixedIssuedUserCert)
        #expect(keyRing.clusterTLSState(for: cluster.id) != nil)
        #expect(keyRing.liveEd25519PrivateKey(for: cluster.id) == nil)
    }

    @Test
    func bootstrapAbortsWhenIssuedSSHCertMismatchesTheKey() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()

        let coordinator = try makeBootstrapCoordinator(
            http: http,
            keyRing: keyRing,
            publicKey: TeleportFixtureSupport.otherSSHPublicKey
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
        #expect(keyRing.clusterTLSState(for: cluster.id) == nil)
        #expect(coordinator.lastBootstrapResult == nil)
    }

    @Test
    func bootstrapAbortsWhenIssuedTLSCertMismatchesTheKeypair() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let http = MockTeleportHTTPClient()
        // Same SSH cert/key binding, but the TLS cert is the wrongname
        // fixture (not signed for the fixed TLS keypair).
        let matching = TeleportFixtureSupport.makeFixtureSuccessResponse()
        let wrongTLS = TeleportFixtureSupport.fixtureString("loopback-tls/server-wrongname.pem")
        http.scriptedHeadlessResponse = HeadlessLoginResponse(
            cert: matching.cert,
            tlsCert: Data(wrongTLS.utf8).base64EncodedString(),
            hostSigners: matching.hostSigners
        )

        let coordinator = try makeBootstrapCoordinator(
            http: http,
            keyRing: keyRing,
            publicKey: TeleportFixtureSupport.fixedSSHPublicKey
        )
        await coordinator.begin(cluster: cluster)

        if case .failed = coordinator.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(coordinator.state)")
        }
        #expect(keyRing.liveCertPEM(for: cluster.id) == nil)
        #expect(coordinator.lastBootstrapResult == nil)
    }
}
