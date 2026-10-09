// SPDX-License-Identifier: MIT
//
//  TeleportKeyRingAndCoordinatorTests.swift
//  TeleportPackageTests
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

    private func makeIsolatedKeyRing(
        keychainService: String = "it.pcad.swift-teleport.tests",
        keychainWriter: TeleportKeyRing.Ed25519KeychainWriter? = nil
    ) -> (TeleportKeyRing, UserDefaults, MockSEPKeySigner) {
        let suiteName = "TeleportKeyRingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let signer = MockSEPKeySigner(outcome: .success)
        let keyRing = TeleportKeyRing(
            signer: signer,
            logging: DefaultTeleportLogging(),
            config: TeleportKeychainConfig(
                keychainService: keychainService,
                defaults: defaults
            ),
            keychainWriter: keychainWriter
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
            TeleportFixtureSupport.fixedIssuedUserCert,
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

    /// The `certExpiry` readiness probe parses the stored PEM and requires the
    /// certificate to be inside its validity window: a stored
    /// `certValidBefore` alone is not enough, and a PEM that cannot be read
    /// must never resolve `.ready` (parity with the host's #262 change).
    @Test
    func certExpiryParsesTheLivePEMAndRequiresValidity() throws {
        let (keyRing, _, signer) = makeIsolatedKeyRing()
        let clusterId = UUID()
        _ = try signer.createKey(credentialID: Data([1, 2, 3]))
        keyRing.storeRegisteredSEPKey(
            credentialID: Data([1, 2, 3]),
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9]),
            deviceName: "dev",
            for: clusterId
        )
        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: "cluster",
                clusterCAPEMs: ["ca"],
                hostCACheckingKeys: [TeleportFixtureSupport.fixedSSHPublicKey]
            ),
            for: clusterId
        )

        // A cert that parses and is currently valid → `.ready`.
        keyRing.storeBootstrapCert(
            TeleportFixtureSupport.fixedIssuedUserCert,
            validBefore: Date(timeIntervalSince1970: 2_082_758_400),
            for: clusterId
        )
        #expect(keyRing.readiness(for: clusterId) == .ready)

        // A parseable but expired PEM with a still-future stored expiry: the
        // parse wins, so readiness must not stay `.ready`.
        keyRing.storeBootstrapCert(
            TeleportFixtureSupport.expiredHostCertLine,
            validBefore: Date().addingTimeInterval(3600),
            for: clusterId
        )
        #expect(keyRing.readiness(for: clusterId) == .needsLogin)

        // An unparseable PEM with a future stored expiry → nil expiry → login.
        keyRing.storeBootstrapCert(
            "cert-pem",
            validBefore: Date().addingTimeInterval(3600),
            for: clusterId
        )
        #expect(keyRing.readiness(for: clusterId) == .needsLogin)
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

    // MARK: - The atomic pair write: round trip and policy semantics

    /// `.bootstrap` creates the record when absent, and the key half reaches
    /// the injected writer seam. The writer is scripted (hermetic): the read
    /// path would otherwise hit the runner's real Keychain, so the committed
    /// key is asserted through the writer model.
    @Test
    func bootstrapPairWriteCreatesTheRecord() throws {
        let writer = ScriptedEd25519KeychainWriter()
        let (keyRing, _, _) = makeIsolatedKeyRing(keychainWriter: { try writer.write($0, clusterId: $1) })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)
        let key = Data("pair-round-trip-key".utf8)

        try keyRing.storeCredentialPair(
            "pair-round-trip-cert",
            validBefore: validBefore,
            privateKeyPEM: key,
            policy: .bootstrap,
            for: clusterId
        )

        #expect(writer.item == key, "the pair write reached the keychain seam")
        #expect(keyRing.credentials[clusterId] != nil, "the bootstrap policy created the record")
        #expect(keyRing.credentials[clusterId]?.sshCertPEM == "pair-round-trip-cert")
        #expect(keyRing.credentials[clusterId]?.certValidBefore == validBefore)
        #expect(keyRing.credentials[clusterId]?.hasLiveCert == true)
    }

    /// `.login` with no record and a seeded prior key throws
    /// `noRegisteredCredential` before any write — the prior key survives and
    /// no record is created (the no-orphan-key guarantee).
    @Test
    func loginPairWithoutARecordWritesNeitherHalf() throws {
        let writer = ScriptedEd25519KeychainWriter()
        writer.item = Data("seeded-prior-key".utf8)
        let (keyRing, _, _) = makeIsolatedKeyRing(keychainWriter: { try writer.write($0, clusterId: $1) })
        let clusterId = UUID()

        #expect(throws: TeleportCredentialStoreError.noRegisteredCredential(clusterId: clusterId)) {
            try keyRing.storeCredentialPair(
                "orphan-cert-pem",
                validBefore: Date().addingTimeInterval(3600),
                privateKeyPEM: Data("orphan-key".utf8),
                policy: .login,
                for: clusterId
            )
        }

        #expect(writer.item == Data("seeded-prior-key".utf8), "the no-record .login pair must not write the orphan key")
        #expect(keyRing.credentials[clusterId] == nil, "no record was created")
        #expect(keyRing.liveCertPEM(for: clusterId) == nil)
    }

    /// A second `.bootstrap` pair write preserves the registered SEP metadata
    /// (credentialID / userHandle / publicKeyRaw / deviceName) — the commit
    /// mutates the cert fields only.
    @Test
    func secondBootstrapPairWritePreservesTheSEPMetadata() throws {
        let writer = ScriptedEd25519KeychainWriter()
        let (keyRing, _, _) = makeIsolatedKeyRing(keychainWriter: { try writer.write($0, clusterId: $1) })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)

        keyRing.storeRegisteredSEPKey(
            credentialID: Data([1, 2, 3, 4]),
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9, 9]),
            deviceName: "device-A",
            for: clusterId
        )
        try keyRing.storeCredentialPair(
            "first-cert",
            validBefore: validBefore,
            privateKeyPEM: Data("first-key".utf8),
            policy: .bootstrap,
            for: clusterId
        )
        try keyRing.storeCredentialPair(
            "second-cert",
            validBefore: validBefore,
            privateKeyPEM: Data("second-key".utf8),
            policy: .bootstrap,
            for: clusterId
        )

        #expect(keyRing.registeredCredentialID(for: clusterId) == Data([1, 2, 3, 4]))
        #expect(keyRing.registeredUserHandle(for: clusterId) == Data("handle".utf8))
        #expect(keyRing.credentials[clusterId]?.publicKeyRaw == Data([9, 9]).base64URLEncodedString())
        #expect(keyRing.credentials[clusterId]?.deviceName == "device-A")
        #expect(keyRing.credentials[clusterId]?.sshCertPEM == "second-cert")
        #expect(keyRing.credentials[clusterId]?.certValidBefore == validBefore, "the record commit writes the cert's validBefore")
        #expect(writer.item == Data("second-key".utf8))
    }

    /// The `.login` success path: a record is present, so the pair commits the
    /// cert fields and the key, and the SEP metadata is preserved.
    @Test
    func loginPairWriteUpdatesTheRecordAndPreservesSEPMetadata() throws {
        let writer = ScriptedEd25519KeychainWriter()
        let (keyRing, _, _) = makeIsolatedKeyRing(keychainWriter: { try writer.write($0, clusterId: $1) })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)
        let key = Data("login-pair-key".utf8)

        keyRing.storeRegisteredSEPKey(
            credentialID: Data([4, 5, 6]),
            userHandle: Data("login-handle".utf8),
            publicKeyRaw: Data([7]),
            deviceName: "login-device",
            for: clusterId
        )
        try keyRing.storeCredentialPair(
            "login-pair-cert",
            validBefore: validBefore,
            privateKeyPEM: key,
            policy: .login,
            for: clusterId
        )

        #expect(writer.item == key)
        #expect(keyRing.registeredCredentialID(for: clusterId) == Data([4, 5, 6]))
        #expect(keyRing.registeredUserHandle(for: clusterId) == Data("login-handle".utf8))
        #expect(keyRing.credentials[clusterId]?.deviceName == "login-device")
        #expect(keyRing.credentials[clusterId]?.certValidBefore == validBefore)
        #expect(keyRing.credentials[clusterId]?.sshCertPEM == "login-pair-cert")
    }

    /// The UI-test mock's readiness flips after a pair write (its fixture is
    /// kept coherent, same as the single writes).
    @Test
    func mockReadinessFlipsAfterAPairWrite() throws {
        let mock = MockTeleportKeyRing()
        let clusterId = UUID()
        mock.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: Data([1, 2, 3]),
                userHandle: Data("handle".utf8),
                deviceName: "test-device"
            )
        )
        #expect(mock.readiness(for: clusterId) == .needsLogin)

        try mock.storeCredentialPair(
            "mock-pair-cert",
            validBefore: TeleportFixtureSupport.attemptCertValidBefore,
            privateKeyPEM: Data("mock-pair-key".utf8),
            policy: .bootstrap,
            for: clusterId
        )

        #expect(mock.readiness(for: clusterId) == .ready)
        #expect(mock.liveCredentialSnapshot(for: clusterId)?.certPEM == "mock-pair-cert")
    }

    // MARK: - The failure direction (the keychain-write seam)

    /// A scripted keychain *update* failure throws the pair write and commits
    /// neither half; the prior record and the prior key survive (nothing was
    /// deleted). The prior record makes "unchanged" discriminating.
    @Test
    func pairWriteUpdateFailureLeavesThePriorRecordAndKeyIntact() throws {
        let writer = ScriptedEd25519KeychainWriter()
        writer.item = Data("prior-key".utf8)
        let (keyRing, _, _) = makeIsolatedKeyRing(keychainWriter: { try writer.write($0, clusterId: $1) })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)
        keyRing.storeBootstrapCert("prior-cert-pem", validBefore: validBefore, for: clusterId)
        writer.script = .updateFails(errSecAuthFailed)

        #expect(throws: TeleportPackageError.keychain(errSecAuthFailed)) {
            try keyRing.storeCredentialPair(
                "new-cert-pem",
                validBefore: validBefore,
                privateKeyPEM: Data("new-key".utf8),
                policy: .bootstrap,
                for: clusterId
            )
        }

        #expect(writer.updateCount == 1, "the pair write reached the keychain seam")
        #expect(writer.addCount == 0)
        #expect(writer.item == Data("prior-key".utf8), "the failed update must not destroy the prior key")
        #expect(keyRing.credentials[clusterId]?.sshCertPEM == "prior-cert-pem", "the record was not committed")
    }

    /// A scripted `errSecItemNotFound` update followed by a failing add throws
    /// the pair write; the prior record is unchanged and no key is committed
    /// (the failed add never deletes).
    @Test
    func pairWriteAddFailureLeavesThePriorRecordIntactAndCommitsNoKey() throws {
        let writer = ScriptedEd25519KeychainWriter()
        let (keyRing, _, _) = makeIsolatedKeyRing(keychainWriter: { try writer.write($0, clusterId: $1) })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)
        keyRing.storeBootstrapCert("prior-cert-pem", validBefore: validBefore, for: clusterId)
        writer.script = .addFails(errSecAuthFailed)

        #expect(throws: TeleportPackageError.keychain(errSecAuthFailed)) {
            try keyRing.storeCredentialPair(
                "new-cert-pem",
                validBefore: validBefore,
                privateKeyPEM: Data("new-key".utf8),
                policy: .bootstrap,
                for: clusterId
            )
        }

        #expect(writer.updateCount == 1)
        #expect(writer.addCount == 1)
        #expect(writer.item == nil, "the failed add must not commit a key")
        #expect(keyRing.credentials[clusterId]?.sshCertPEM == "prior-cert-pem", "the record was not committed")
    }

    /// The real-writer behavioral twin: the *real* keychain write (the default
    /// closure — no injected writer) must update the existing item in place.
    /// Seed the item directly with a distinct `kSecAttrLabel`, run a pair
    /// write, and assert the read-back value is the new key AND the seeded
    /// label survived: a delete-then-add regression resets the item's
    /// attributes to the writer's defaults, and the label observation is used
    /// because `kSecAttrAccessible` does not round-trip under plain macOS
    /// `swift test` (measured by the plan's lens 1 probe).
    @Test
    func realPairWriteUpdatesTheSeededKeychainItemInPlace() throws {
        let service = "it.pcad.swift-teleport.tests.\(UUID().uuidString)"
        let (keyRing, _, _) = makeIsolatedKeyRing(keychainService: service)
        let clusterId = UUID()
        let account = "vvterm.teleport.sshkey.\(clusterId.uuidString)"
        let priorKey = Data("seeded-prior-key".utf8)
        let newKey = Data("pair-written-key".utf8)
        let seededLabel = "vvterm-seeded-pair-label"

        let seedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: priorKey,
            kSecAttrLabel as String: seededLabel
        ]
        let seedStatus = SecItemAdd(seedQuery as CFDictionary, nil)
        try #require(seedStatus == errSecSuccess, "the isolated keychain item must seed (OSStatus \(seedStatus))")
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
        }

        try keyRing.storeCredentialPair(
            "real-writer-cert",
            validBefore: Date().addingTimeInterval(3600),
            privateKeyPEM: newKey,
            policy: .bootstrap,
            for: clusterId
        )

        let readBack = try #require(
            Self.readKeychainItem(service: service, account: account),
            "the pair write must leave the item readable"
        )
        #expect(readBack.data == newKey, "the pair write must replace the key value")
        #expect(
            readBack.label == seededLabel,
            "the update-only writer must preserve the seeded label; a delete-then-add regression resets the item"
        )
        #expect(keyRing.liveEd25519PrivateKey(for: clusterId) == newKey)
    }

    /// Reads a generic-password item's data + label, or nil when it is absent.
    /// Used by the real-writer round-trip.
    private static func readKeychainItem(service: String, account: String) -> (data: Data, label: String?)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data else {
            return nil
        }
        return (data, attributes[kSecAttrLabel as String] as? String)
    }
}

// MARK: - The scripted keychain-write model

/// An in-memory keychain-write model for the injectable `TeleportKeyRing`
/// seam. It mirrors the production update-first, non-destructive direction: a
/// scripted update failure throws without touching the item; a scripted add
/// failure throws without deleting.
@MainActor
private final class ScriptedEd25519KeychainWriter {
    enum Script {
        case real
        case updateFails(OSStatus)
        case addFails(OSStatus)
    }

    var item: Data?
    var script: Script = .real
    private(set) var updateCount = 0
    private(set) var addCount = 0

    func write(_ pemData: Data, clusterId: UUID) throws {
        switch script {
        case .real:
            updateCount += 1
            if item == nil {
                addCount += 1
            }
            item = pemData
        case .updateFails(let status):
            updateCount += 1
            throw TeleportPackageError.keychain(status)
        case .addFails(let status):
            updateCount += 1
            addCount += 1
            throw TeleportPackageError.keychain(status)
        }
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
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "user-cert-ed25519")

        await coordinator.begin(cluster: cluster)

        #expect(coordinator.state == .success)
        #expect(http.headlessLoginCallCount == 1)
        #expect(coordinator.lastBootstrapResult?.clusterName == "teleport.pcad.it")
        #expect(keyRing.liveCertPEM(for: cluster.id) != nil)
    }

    @Test
    func loginCoordinatorIssuesAndStoresACert() async {
        let keyRing = MockTeleportKeyRing()
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "user-cert-ed25519")
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

        guard case .success(let validUntil, let logins) = coordinator.state else {
            Issue.record("expected .success, got \(coordinator.state)")
            return
        }
        #expect(validUntil > TeleportFixtureSupport.fixtureClock)
        // The fixture user cert's single non-internal principal travels to the
        // setup picker.
        #expect(logins == ["alice"])
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
