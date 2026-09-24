// SPDX-License-Identifier: MIT
//
//  TeleportKeyRingAndCoordinatorTests.swift
//  TeleportAuthTests
//
//  Package-local coverage for the `TeleportAuth` surface against the
//  `TeleportTesting` mocks:
//    - `TeleportKeyRing` persistence through an injected (suite-scoped)
//      `UserDefaults`, never `.standard`;
//    - the additions-only Host CA key refresh through the keyring;
//    - real coordinator state machines driven by the infrastructure mocks
//      (replacing the host-side coverage that stays host-side in Phase 2).
//

import Foundation
import Security
import Testing
import TeleportCore
@testable import TeleportAuth
import TeleportTesting

// MARK: - Key ring

@MainActor
struct TeleportKeyRingTests {

    private func makeIsolatedKeyRing() -> (TeleportKeyRing, UserDefaults, MockSEPKeySigner) {
        let suiteName = "TeleportKeyRingTests-\(UUID().uuidString)"
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
        return (keyRing, defaults, signer)
    }

    @Test
    func bootstrapCertRoundTripsAndDrivesReadiness() {
        let (keyRing, _, _) = makeIsolatedKeyRing()
        let clusterId = UUID()

        #expect(keyRing.readiness(for: clusterId) == .needsBootstrap)

        keyRing.storeBootstrapCert(
            "test-bootstrap-pem",
            validBefore: Date().addingTimeInterval(3600),
            for: clusterId
        )
        #expect(keyRing.liveCertPEM(for: clusterId) == "test-bootstrap-pem")
        // Cert present, no SEP key → registration is next.
        #expect(keyRing.readiness(for: clusterId) == .needsRegistration)
    }

    @Test
    func sepKeyMetadataRoundTrips() throws {
        let (keyRing, _, signer) = makeIsolatedKeyRing()
        let clusterId = UUID()
        keyRing.storeBootstrapCert(
            "cert-pem",
            validBefore: Date().addingTimeInterval(3600),
            for: clusterId
        )
        _ = try signer.createKey(credentialID: Data([1, 2, 3]))

        keyRing.storeRegisteredSEPKey(
            credentialID: Data([1, 2, 3]),
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9]),
            deviceName: "dev",
            for: clusterId
        )
        #expect(keyRing.registeredCredentialID(for: clusterId) == Data([1, 2, 3]))
        #expect(keyRing.registeredUserHandle(for: clusterId) == Data("handle".utf8))
        #expect(keyRing.credentials[clusterId]?.deviceName == "dev")
        // SEP key present but no Host CA keys → the legacy path routes to login.
        #expect(keyRing.readiness(for: clusterId) == .needsLogin)

        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: "cluster",
                clusterCAPEMs: ["ca"],
                hostCACheckingKeys: [TeleportFixtureSupport.fixedSSHPublicKey]
            ),
            for: clusterId
        )
        #expect(keyRing.readiness(for: clusterId) == .ready)
    }

    @Test
    func loginCertOverwriteAndClear() throws {
        let (keyRing, _, signer) = makeIsolatedKeyRing()
        let clusterId = UUID()
        keyRing.storeBootstrapCert("cert-pem", validBefore: Date().addingTimeInterval(3600), for: clusterId)
        _ = try signer.createKey(credentialID: Data([1]))
        keyRing.storeRegisteredSEPKey(
            credentialID: Data([1]),
            userHandle: Data([2]),
            publicKeyRaw: Data([3]),
            deviceName: "dev",
            for: clusterId
        )

        keyRing.storeLoginCert("login-pem", validBefore: Date().addingTimeInterval(3600), for: clusterId)
        #expect(keyRing.liveCertPEM(for: clusterId) == "login-pem")

        keyRing.clear(for: clusterId)
        #expect(keyRing.liveCertPEM(for: clusterId) == nil)
        #expect(keyRing.clusterTLSState(for: clusterId) == nil)
        #expect(keyRing.readiness(for: clusterId) == .needsBootstrap)
    }

    @Test
    func hostKeyRefreshIsAdditionsOnly() {
        let (keyRing, _, _) = makeIsolatedKeyRing()
        let clusterId = UUID()
        let pinned = TeleportFixtureSupport.fixedSSHPublicKey
        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: "cluster",
                clusterCAPEMs: ["ca"],
                hostCACheckingKeys: [pinned]
            ),
            for: clusterId
        )

        // A refresh that would drop the pinned key is rejected; the state is kept.
        let dropped = keyRing.updateClusterHostKeys([TeleportFixtureSupport.otherSSHPublicKey], for: clusterId)
        #expect(dropped == .rejectedWouldDropPinnedKeys)
        #expect(keyRing.clusterTLSState(for: clusterId)?.hostCACheckingKeys == [pinned])

        // An additions-only refresh is accepted.
        let added = keyRing.updateClusterHostKeys([pinned, TeleportFixtureSupport.otherSSHPublicKey], for: clusterId)
        #expect(added == .updated)
        #expect(keyRing.clusterTLSState(for: clusterId)?.hostCACheckingKeys.count == 2)
    }

    @Test
    func credentialsPersistAcrossKeyRingInstances() {
        let suiteName = "TeleportKeyRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let config = TeleportKeychainConfig(keychainService: "it.pcad.swift-teleport.tests", defaults: defaults)
        let clusterId = UUID()

        let first = TeleportKeyRing(signer: MockSEPKeySigner(outcome: .success), logging: DefaultTeleportLogging(), config: config)
        first.storeBootstrapCert("cert-pem", validBefore: Date().addingTimeInterval(3600), for: clusterId)

        let second = TeleportKeyRing(signer: MockSEPKeySigner(outcome: .success), logging: DefaultTeleportLogging(), config: config)
        #expect(second.liveCertPEM(for: clusterId) == "cert-pem")
    }
}

// MARK: - Coordinators against the infrastructure mocks

@MainActor
struct TeleportCoordinatorSmokeTests {

    @Test
    func bootstrapCoordinatorStoresTheIssuedCert() async {
        let keyRing = MockTeleportKeyRing()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()
        let coordinator = TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: keyRing,
            safariPresenter: MockWebAuthenticationSessionPresenter(),
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")

        await coordinator.begin(cluster: cluster)

        #expect(coordinator.state == .success)
        #expect(http.headlessLoginCallCount == 1)
        #expect(coordinator.lastBootstrapResult?.clusterName == "teleport.pcad.it")
        #expect(keyRing.liveCertPEM(for: cluster.id) != nil)
    }

    @Test
    func loginCoordinatorIssuesAndStoresACert() async {
        let keyRing = MockTeleportKeyRing()
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        keyRing.seed(
            clusterId: cluster.id,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: true,
                hasSEPKey: true,
                certValidBefore: Date().addingTimeInterval(-60),
                credentialID: Data([1, 2, 3]),
                userHandle: Data("handle".utf8),
                deviceName: "dev"
            )
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try? signer.createKey(credentialID: Data([1, 2, 3]))
        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            webAuthnBuilder: TeleportWebAuthnBuilder(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )

        await coordinator.begin(cluster: cluster)

        guard case .success(let validUntil) = coordinator.state else {
            Issue.record("expected .success, got \(coordinator.state)")
            return
        }
        #expect(validUntil > TeleportFixtureSupport.fixtureClock)
        #expect(http.loginFinishCallCount == 1)
        #expect(keyRing.liveCertPEM(for: cluster.id) != nil)
    }

    @Test
    func registrationCoordinatorRegistersTheSEPKey() async {
        let keyRing = MockTeleportKeyRing()
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let grpc = RegistrationGRPCStub()
        let ceremony = RegistrationCeremonyStub()
        let coordinator = TeleportRegistrationCoordinator(
            grpcClient: grpc,
            browserMFACeremony: ceremony,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            webAuthnBuilder: TeleportWebAuthnBuilder()
        )
        let bootstrapResult = TeleportBootstrapCoordinator.BootstrapResult(
            sshCertPEM: "cert",
            tlsCertPEM: "tls-cert",
            tlsKeyPairPrivateKey: TeleportFixtureSupport.fixedTLSKeyPair()!.privateKey,
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: [],
            certValidBefore: TeleportFixtureSupport.fixtureClock.addingTimeInterval(3600)
        )

        await coordinator.begin(
            cluster: cluster,
            deviceName: "vvterm-pier",
            bootstrapResult: bootstrapResult
        )

        #expect(coordinator.state == .success)
        #expect(grpc.didConnect)
        #expect(grpc.addedDeviceName == "vvterm-pier")
        #expect(keyRing.registeredCredentialID(for: cluster.id) != nil)
    }
}

// MARK: - Registration stubs

@MainActor
private final class RegistrationGRPCStub: TeleportGRPCClienting {
    nonisolated deinit {}
    private(set) var didConnect = false
    private(set) var addedDeviceName: String?

    func connect(
        host: String,
        clientCertPEM: String,
        privateKey: SecKey,
        clusterName: String,
        clusterCAPEMs: [String]
    ) async throws {
        didConnect = true
    }

    func createAuthenticateChallenge(
        browserMFATSHRedirectURL: String
    ) async throws -> Proto_MFAAuthenticateChallenge {
        // No BrowserMFAChallenge → the coordinator takes the first-device path.
        Proto_MFAAuthenticateChallenge()
    }

    func createRegisterChallenge(
        existingMFAResponse: Proto_MFAAuthenticateResponse?
    ) async throws -> Proto_MFARegisterChallenge {
        var challenge = Proto_MFARegisterChallenge()
        var webauthn = Proto_CredentialCreation()
        var publicKey = Proto_PublicKeyCredentialCreationOptions()
        publicKey.challenge = Data([1, 2, 3])
        publicKey.rp = Proto_RelyingPartyEntity()
        publicKey.rp.id = "teleport.pcad.it"
        publicKey.user = Proto_UserEntity()
        publicKey.user.id = "user-handle"
        webauthn.publicKey = publicKey
        challenge.webauthn = webauthn
        return challenge
    }

    func addMFADeviceSync(
        deviceName: String,
        newMFAResponse: Proto_MFARegisterResponse
    ) async throws {
        addedDeviceName = deviceName
    }

    func disconnect() async {}
}

@MainActor
private final class RegistrationCeremonyStub: BrowserMFACeremonyRunning {
    nonisolated deinit {}
    func run(
        grpcClient: any TeleportGRPCClienting,
        host: String
    ) async throws -> Proto_BrowserMFAResponse {
        throw BrowserMFACeremonyError.noBrowserMFAChallenge
    }
}
