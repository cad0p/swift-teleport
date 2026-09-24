// SPDX-License-Identifier: MIT
//
//  HostSurfaceCompileTests.swift
//  TeleportCoreConsumerTests
//
//  A NON-`@testable` compile-time contract for the Phase 2 host adoption.
//  It mirrors the host files that consume the package —
//  `Core/Teleport/TeleportComposition.swift`,
//  `Features/Teleport/UI/TeleportLiveCoordinators.swift`,
//  `Core/Teleport/TeleportKeyRingStoring.swift`,
//  `Core/Teleport/TeleportKeyRingCredentialStore.swift`,
//  `Core/SSH/SSHClient.swift`'s host-key verification, and one iOS
//  harness — so a missing public promotion or an access-level regression
//  fails here instead of at Phase 2 integration time.
//
//  The mirrors are deliberately shaped like the host code (same parameter
//  lists, same call sequences); the bodies are compiled, not executed.
//

import Foundation
import Testing
import TeleportCore
import TeleportAuth
import TeleportTesting
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
import CryptoKit
import os.log
import Security
import SwiftProtobuf

// MARK: - Mirror: host `TeleportKeyRingStoring` + its extension

/// The host's `@MainActor` observation protocol over the package keyring.
/// The host declares this and restores the conformance by extension in
/// Phase 2; this mirror proves every requirement is publicly reachable.
@MainActor
protocol HostTeleportKeyRingStoring: AnyObject, ObservableObject {
    var credentials: [UUID: TeleportCredential] { get }
    func readiness(for clusterId: UUID) -> TeleportDeviceReadiness
    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID)
    func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    )
    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID)
    func liveCertPEM(for clusterId: UUID) -> String?
    func registeredCredentialID(for clusterId: UUID) -> Data?
    func registeredUserHandle(for clusterId: UUID) -> Data?
    func clusterTLSState(for clusterId: UUID) -> TeleportClusterTLSState?
    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID)
    func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) -> TeleportHostKeyUpdateResult
    func liveEd25519PrivateKey(for clusterId: UUID) -> Data?
    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) throws
    func clear(for clusterId: UUID)
}

extension TeleportKeyRing: HostTeleportKeyRingStoring {}

// MARK: - Mirror: host `TeleportKeyRingCredentialStore` adapter

/// The host's `nonisolated` adapter from the actor-side
/// `TeleportCredentialStore` seam to the MainActor keyring.
final class HostCredentialStoreAdapter: TeleportCredentialStore, @unchecked Sendable {
    private let keyRingProvider: @MainActor @Sendable () -> TeleportKeyRing

    init(keyRingProvider: @escaping @MainActor @Sendable () -> TeleportKeyRing) {
        self.keyRingProvider = keyRingProvider
    }

    @MainActor
    var resolvedKeyRing: TeleportKeyRing { keyRingProvider() }

    func clusterTLSState(for clusterId: UUID) async -> TeleportClusterTLSState? {
        await MainActor.run { keyRingProvider().clusterTLSState(for: clusterId) }
    }

    func liveCertPEM(for clusterId: UUID) async -> String? {
        await MainActor.run { keyRingProvider().liveCertPEM(for: clusterId) }
    }

    func liveEd25519PrivateKey(for clusterId: UUID) async -> Data? {
        await MainActor.run { keyRingProvider().liveEd25519PrivateKey(for: clusterId) }
    }

    func registeredCredentialID(for clusterId: UUID) async -> Data? {
        await MainActor.run { keyRingProvider().registeredCredentialID(for: clusterId) }
    }

    func registeredUserHandle(for clusterId: UUID) async -> Data? {
        await MainActor.run { keyRingProvider().registeredUserHandle(for: clusterId) }
    }

    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async {
        await MainActor.run {
            keyRingProvider().storeBootstrapCert(certPEM, validBefore: validBefore, for: clusterId)
        }
    }

    func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    ) async {
        await MainActor.run {
            keyRingProvider().storeRegisteredSEPKey(
                credentialID: credentialID,
                userHandle: userHandle,
                publicKeyRaw: publicKeyRaw,
                deviceName: deviceName,
                for: clusterId
            )
        }
    }

    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async {
        await MainActor.run {
            keyRingProvider().storeLoginCert(certPEM, validBefore: validBefore, for: clusterId)
        }
    }

    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) async throws {
        try await MainActor.run {
            try keyRingProvider().storeEd25519PrivateKey(pemData, for: clusterId)
        }
    }

    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID) async {
        await MainActor.run {
            keyRingProvider().storeClusterTLSState(state, for: clusterId)
        }
    }

    func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) async -> TeleportHostKeyUpdateResult {
        await MainActor.run {
            keyRingProvider().updateClusterHostKeys(checkingKeys, for: clusterId)
        }
    }

    func clear(for clusterId: UUID) async {
        await MainActor.run {
            keyRingProvider().clear(for: clusterId)
        }
    }
}

// MARK: - Mirror: host `LiveTeleportHTTPClient`

final class HostLiveTeleportHTTPClient: TeleportHTTPClienting {
    func headlessLogin(
        baseURL: URL,
        user: String,
        headlessAuthenticationID: String,
        sshPubKeyB64: String,
        tlsPubKeyB64: String?,
        ttl: Int64
    ) async throws -> HeadlessLoginResponse {
        let req = HeadlessLoginReq(
            user: user,
            headlessAuthenticationID: headlessAuthenticationID,
            sshPubKey: sshPubKeyB64,
            tlsPubKey: tlsPubKeyB64,
            ttl: ttl,
            compatibility: ""
        )
        return try await HeadlessLogin.post(baseURL: baseURL, req: req)
    }

    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        let body = try JSONSerialization.data(withJSONObject: ["passwordless": true])
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("webapi/mfa/login/begin"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = body
        let (data, response) = try await TeleportTrustSession.session.data(for: urlReq)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"
            throw GRPCError.http2("login/begin HTTP \(status): \(responseBody)")
        }
        do {
            return try JSONDecoder().decode(LoginBeginResponse.self, from: data)
        } catch {
            throw GRPCError.decode("login/begin response: \(error.localizedDescription)")
        }
    }

    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
        let sshPubKeyString = String(data: sshPubKey, encoding: .utf8) ?? ""
        let finishReq = LoginFinishReq(
            webauthnChallengeResponse: assertion,
            sshPubKey: Data(sshPubKeyString.utf8),
            pubKey: Data(sshPubKeyString.utf8),
            ttl: ttl
        )
        let finishBody = try JSONEncoder().encode(finishReq)
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("webapi/mfa/login/finish"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = finishBody
        let (data, response) = try await TeleportTrustSession.session.data(for: urlReq)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"
            throw GRPCError.http2("login/finish HTTP \(status): \(responseBody)")
        }
        do {
            return try JSONDecoder().decode(LoginFinishResponse.self, from: data)
        } catch {
            throw GRPCError.decode("login/finish response: \(error.localizedDescription)")
        }
    }
}

// MARK: - Mirror: host `LiveTeleportGRPCClient`

final class HostLiveTeleportGRPCClient: TeleportGRPCClienting {
    private var connection: TeleportGRPCConnection?
    private let logger: Logger
    private let transportLogger: Logger

    init(logging: any TeleportLogging) {
        self.logger = logging.logger(category: "teleport-grpc")
        self.transportLogger = logging.logger(category: "TeleportGRPC")
        GRPCClientIdentity.deleteStaleIdentities(logger: transportLogger)
    }

    func connect(
        host: String,
        clientCertPEM: String,
        privateKey: SecKey,
        clusterName: String,
        clusterCAPEMs: [String]
    ) async throws {
        connection = try await TeleportGRPCConnection.connect(
            host: host,
            port: 443,
            clientCertPEM: clientCertPEM,
            privateKey: privateKey,
            clusterName: clusterName,
            clusterCAPEMs: clusterCAPEMs,
            logger: transportLogger
        )
        logger.info("gRPC connected to \(host, privacy: .public)")
    }

    func createAuthenticateChallenge(
        browserMFATSHRedirectURL: String
    ) async throws -> Proto_MFAAuthenticateChallenge {
        guard let conn = connection else {
            throw GRPCError.transport("not connected")
        }
        var req = Proto_CreateAuthenticateChallengeRequest()
        req.contextUser = Proto_ContextUser()
        req.challengeExtensions = Proto_ChallengeExtensions()
        req.challengeExtensions.scope = .manageDevices
        req.browserMfaTshRedirectURL = browserMFATSHRedirectURL
        return try await conn.unary(
            path: "/proto.AuthService/CreateAuthenticateChallenge",
            request: req,
            responseType: Proto_MFAAuthenticateChallenge.self
        )
    }

    func createRegisterChallenge(
        existingMFAResponse: Proto_MFAAuthenticateResponse?
    ) async throws -> Proto_MFARegisterChallenge {
        guard let conn = connection else {
            throw GRPCError.transport("not connected")
        }
        var req = Proto_CreateRegisterChallengeRequest()
        req.deviceType = .webauthn
        req.deviceUsage = .passwordless
        if let existing = existingMFAResponse {
            req.existingMfaResponse = existing
        }
        return try await conn.unary(
            path: "/proto.AuthService/CreateRegisterChallenge",
            request: req,
            responseType: Proto_MFARegisterChallenge.self
        )
    }

    func addMFADeviceSync(
        deviceName: String,
        newMFAResponse: Proto_MFARegisterResponse
    ) async throws {
        guard let conn = connection else {
            throw GRPCError.transport("not connected")
        }
        var req = Proto_AddMFADeviceSyncRequest()
        req.contextUser = Proto_ContextUser()
        req.newDeviceName = deviceName
        req.newMfaResponse = newMFAResponse
        req.deviceUsage = .passwordless
        _ = try await conn.unary(
            path: "/proto.AuthService/AddMFADeviceSync",
            request: req,
            responseType: Proto_AddMFADeviceSyncResponse.self
        )
    }

    func disconnect() async {
        if let conn = connection {
            try? await conn.close()
            // The deinit-time leak bound (`connection?.deleteKeychainIdentity()`)
            // is nonisolated-unreachable under Swift 6; the async path is the
            // supported one.
            conn.deleteKeychainIdentity()
            connection = nil
        }
    }
}

// MARK: - Mirror: host `LiveBrowserMFACeremony` + Safari presenter

@MainActor
final class HostLiveBrowserMFACeremony: BrowserMFACeremonyRunning {
    private let logging: any TeleportLogging
    private let presenter: any BrowserMFAPresenting

    init(logging: any TeleportLogging, presenter: any BrowserMFAPresenting) {
        self.logging = logging
        self.presenter = presenter
    }

    func run(
        grpcClient: any TeleportGRPCClienting,
        host: String
    ) async throws -> Proto_BrowserMFAResponse {
        let ceremony = BrowserMFACeremony(logging: logging, presenter: presenter)
        return try await ceremony.run(grpcClient: grpcClient, host: host)
    }
}

#if canImport(AuthenticationServices)
@MainActor
final class HostWebAuthenticationSessionPresenter: NSObject, WebAuthenticationSessionPresenting {
    private var session: ASWebAuthenticationSession?

    func open(url: URL) async -> Bool {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "vvterm") { _, _ in }
        session.presentationContextProvider = nil
        session.prefersEphemeralWebBrowserSession = true
        self.session = session
        return session.start()
    }

    func cancel() {
        session?.cancel()
        session = nil
    }
}
#endif

// MARK: - Mirror: host `TeleportComposition` factories

@MainActor
enum HostCompositionMirror {
    static func makeBootstrapCoordinator(
        keyRing: any TeleportCredentialStore,
        logging: any TeleportLogging,
        signer: any TeleportSEPSigning
    ) -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: HostLiveTeleportHTTPClient(),
            keyRing: keyRing,
            safariPresenter: nil,
            logging: logging,
            signer: signer
        )
    }

    static func makeRegistrationCoordinator(
        keyRing: any TeleportCredentialStore,
        logging: any TeleportLogging,
        signer: any TeleportSEPSigning,
        presenter: any BrowserMFAPresenting
    ) -> TeleportRegistrationCoordinator {
        TeleportRegistrationCoordinator(
            grpcClient: HostLiveTeleportGRPCClient(logging: logging),
            browserMFACeremony: HostLiveBrowserMFACeremony(logging: logging, presenter: presenter),
            keyRing: keyRing,
            logging: logging,
            signer: signer,
            webAuthnBuilder: TeleportWebAuthnBuilder()
        )
    }

    static func makeLoginCoordinator(
        keyRing: any TeleportCredentialStore,
        logging: any TeleportLogging,
        signer: any TeleportSEPSigning
    ) -> TeleportLoginCoordinator {
        TeleportLoginCoordinator(
            httpClient: HostLiveTeleportHTTPClient(),
            keyRing: keyRing,
            logging: logging,
            signer: signer,
            webAuthnBuilder: TeleportWebAuthnBuilder(),
            keyPairGenerator: LiveTeleportSSHKeyPairGenerator()
        )
    }

    static func makeKeyRing(logging: any TeleportLogging) -> TeleportKeyRing {
        TeleportKeyRing(
            logging: logging,
            config: TeleportKeychainConfig(
                keychainService: "com.example.host",
                defaults: UserDefaults(suiteName: "com.example.host.tests") ?? .standard
            )
        )
    }

    static func makeBrowserMFACeremony(
        logging: any TeleportLogging,
        presenter: any BrowserMFAPresenting
    ) -> BrowserMFACeremony {
        BrowserMFACeremony(logging: logging, presenter: presenter)
    }
}

// MARK: - Mirror: host `SSHClient` host-key verification + model surface

enum HostSSHClientMirror {
    static func hostKeyDecision(
        blob: Data,
        expectedPrincipals: [String],
        checkingKeys: [String]
    ) -> HostKeyTrustPolicy.Decision {
        HostKeyTrustPolicy.decide(
            isTeleport: true,
            fingerprint: "SHA256:test",
            keyType: 1,
            knownFingerprint: nil,
            hostKeyBlob: blob,
            expectedPrincipals: expectedPrincipals,
            teleportHostCACheckingKeys: checkingKeys,
            now: Date()
        )
    }

    static func logRejectedCertificate(blob: Data, expectedPrincipals: [String]) {
        if let cert = OpenSSHCertificate.parse(blob: blob) {
            _ = cert.keyID
            _ = cert.validPrincipals.joined(separator: ",")
            _ = cert.certType
            _ = cert.validBeforeDate
            _ = cert.isValid(at: Date())
        }
        _ = OpenSSHHostCertVerifier.verify(
            hostKeyBlob: blob,
            expectedPrincipals: expectedPrincipals,
            checkingKeys: [],
            now: Date()
        )
        _ = OpenSSHHostCertVerification.verified
    }

    static func validateIssuedCert(
        certPEM: String,
        publicKeyBlob: Data,
        tlsCertPEM: String,
        privateKey: SecKey
    ) {
        _ = TeleportIssuedCertValidator.validateIssuedUserCert(
            certPEM,
            expectedPublicKeyBlob: publicKeyBlob,
            requestedTTL: 3600,
            now: Date()
        )
        _ = TeleportIssuedCertValidator.validateTLSCertBinding(tlsCertPEM, expectedPrivateKey: privateKey)
        _ = TeleportWebAuthnRPID.resolve(
            serverProvided: "teleport.example.com",
            cluster: TeleportCluster(host: "teleport.example.com", username: "pier")
        )
    }

    static func clusterAndDeviceModels() {
        let cluster = TeleportCluster(
            id: UUID(),
            host: "teleport.example.com",
            port: 443,
            username: "pier",
            rpID: nil,
            clusterName: nil
        )
        _ = cluster.sepKeyLabel
        _ = TeleportDeviceName.default(rawDeviceName: "Pier's iPhone")
        _ = TeleportDeviceName.sanitize("Pier's iPhone")
        _ = TeleportDeviceName.validate("vvterm-pier")
        _ = TeleportDeviceName.prefix
        _ = TeleportDeviceName.maxSanitizedLength
        let credential = TeleportCredential(
            clusterId: cluster.id,
            credentialID: "id",
            userHandle: "handle",
            publicKeyRaw: "raw",
            deviceName: "vvterm-pier"
        )
        _ = credential.isCertValid
        _ = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in true },
            hasSEPKey: { _ in true },
            certExpiry: { _ in Date().addingTimeInterval(3600) },
            hasHostCAKeys: { _ in true }
        ).resolve(clusterId: cluster.id)
        _ = TeleportHostKeyUpdatePolicy.apply(checkingKeys: [], to: TeleportClusterTLSState(clusterName: "c", clusterCAPEMs: []))
        _ = TeleportHostCACheckingKeysDecoder.decode("")
    }

    static func webAuthnAndKeys() throws {
        _ = HeadlessID.compute(sshAuthorizedKey: "ssh-ed25519 AAAA")
        let pair = try TLSKeyPairGen.generate()
        _ = pair.tlsPubKeyB64
        _ = TLSKeyPair(privateKey: pair.privateKey, publicKeyPEM: pair.publicKeyPEM)
        let sshPair = SSHPubKey.generateEd25519KeyPair(comment: "host-surface")
        _ = sshPair.publicKey
        _ = sshPair.privateKeyPEM
        let signer = SoftwareSigner()
        let created = try signer.createKey()
        _ = try signer.createKey(credentialID: created.credentialID)
        _ = try signer.loadKey(credentialID: created.credentialID)
        _ = try signer.sign(message: Data([1, 2, 3]), credentialID: created.credentialID)
        _ = SecureEnclaveSigner()
        _ = try WebAuthn.register(
            origin: "https://teleport.example.com",
            rpID: "teleport.example.com",
            challenge: Data([1, 2, 3]),
            credentialID: created.credentialID,
            publicKeyRaw: created.publicKeyRaw,
            signer: signer
        )
        _ = try WebAuthn.login(
            origin: "https://teleport.example.com",
            rpID: "teleport.example.com",
            challenge: Data([1, 2, 3]),
            credentialID: created.credentialID,
            userHandle: nil,
            signer: signer
        )
    }

    static func gRPCErrorShapes() {
        let errors: [GRPCError] = [
            .transport("t"), .tls("tls"), .http2("h2"), .grpc(status: 7, message: "m"),
            .decode("d"), .timeout,
        ]
        for error in errors {
            _ = error.description
            _ = error.errorDescription
            _ = error.failureReason
        }
        _ = GRPCClientIdentity.labelPrefix
        _ = GRPCClientIdentity.makeLabel()
        _ = GRPCClientIdentity.timestamp(inLabel: "vvterm-grpc-0-x")
        _ = GRPCClientIdentity.isLiveLabel("x")
        GRPCClientIdentity.registerLiveLabel("x")
        GRPCClientIdentity.unregisterLiveLabel("x")
        GRPCClientIdentity.resetSweepGateForTesting()
    }
}

// MARK: - Mirror: one iOS UI-test harness

@MainActor
enum HostHarnessMirror {
    static func harnessKeyRing() -> MockTeleportKeyRing {
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: UUID(),
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: true,
                hasSEPKey: true,
                certValidBefore: Date().addingTimeInterval(3600),
                credentialID: Data([1, 2, 3]),
                userHandle: Data([4, 5, 6]),
                deviceName: "vvterm-pier"
            )
        )
        _ = keyRing.readiness(for: UUID())
        _ = keyRing.credentials
        return keyRing
    }

    static func harnessMocks() {
        _ = MockSEPKeySigner(outcome: .success)
        _ = MockSEPKeySigner(outcome: .cancelled)
        _ = MockSEPKeySigner(outcome: .lockout)
        _ = MockSEPKeySigner(outcome: .notEnrolled)
        _ = MockWebAuthenticationSessionPresenter()
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = MockTeleportHTTPClient.makeSuccessResponse(clusterName: "c")
        http.scriptedHeadlessError = HeadlessError.noCert
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        _ = http.headlessLoginCallCount
        _ = http.loginFinishCallCount
        let bootstrap = MockTeleportBootstrapCoordinator(scenario: .happyPath)
        _ = bootstrap.state
        _ = bootstrap.lastBootstrapResult
        let login = MockTeleportLoginCoordinator(scenario: .happyPath(certTTL: 3600))
        _ = login.state
        _ = login.lastCertValidUntil
        let registration = MockTeleportRegistrationCoordinator(scenario: .happyPath)
        _ = registration.state
        _ = registration.lastDeviceName
    }
}

// MARK: - Compile-only assertion

@Suite("Host surface compile contract")
struct HostSurfaceCompileTests {
    @Test
    func hostSurfaceMirrorsCompile() {
        // The mirrors above are the assertion; this keeps the file a real
        // test so it runs (and compiles) with `swift test`.
        #expect(GRPCClientIdentity.labelPrefix == "vvterm-grpc-")
    }
}
