// SPDX-License-Identifier: MIT
//
//  TeleportLoginCoordinatorGenerationTests.swift
//  TeleportPackageTests
//
//  The login half of the atomic-pair coverage: a supersession landing while
//  the login's atomic pair write is parked cannot tear the stored credential,
//  and the post-throw states derive from the store's real state (the host's
//  D4 adaptation). The login coordinator has no request-generation token (the
//  host's #240/#279 login continuation guards were never ported — follow-up
//  issue), so the login half's supersession guarantee is the pair write's
//  interleaving atomicity only: the behavioral test asserts the stored
//  credential, never the terminal state.
//
//  The HTTP stub scripts one `login/finish` response per call, so a
//  two-attempt supersession can give each attempt its own cert bound to its
//  own generated keypair.
//

import Foundation
import XCTest
@testable import TeleportCore
@testable import TeleportAuth
import TeleportTesting

/// A `TeleportHTTPClienting` stub for the login coordinator: `loginBegin`
/// returns the fixture challenge, and every `loginFinish` call pops the next
/// scripted response. `headlessLogin` is not exercised here.
@MainActor
private final class LoginScriptedHTTPClient: TeleportHTTPClienting {
    var loginFinishResponses: [LoginFinishResponse] = []
    private(set) var loginFinishCallCount = 0

    func headlessLogin(
        baseURL: URL,
        user: String,
        headlessAuthenticationID: String,
        sshPubKeyB64: String,
        tlsPubKeyB64: String?,
        ttl: Int64
    ) async throws -> HeadlessLoginResponse {
        throw HeadlessError.transport("headlessLogin not scripted", code: nil)
    }

    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
    }

    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
        loginFinishCallCount += 1
        guard !loginFinishResponses.isEmpty else {
            throw HeadlessError.transport("loginFinish not scripted", code: nil)
        }
        return loginFinishResponses.removeFirst()
    }
}

nonisolated final class TeleportLoginCoordinatorGenerationTests: XCTestCase {

    @MainActor
    private func makeCluster() -> TeleportCluster {
        // The attempt certs are minted with `keyID: cluster.username`; the
        // coordinator binds `cert.keyID` to the configured Teleport user.
        TeleportCluster(host: "teleport.pcad.it", username: "user-cert-ed25519")
    }

    @MainActor
    private func makeRegisteredKeyRing(
        clusterId: UUID,
        credentialID: Data = Data([1, 2, 3, 4])
    ) -> MockTeleportKeyRing {
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: credentialID,
                userHandle: Data("handle".utf8),
                deviceName: "test-device"
            )
        )
        return keyRing
    }

    @MainActor
    private func makeLoginCoordinator(
        http: any TeleportHTTPClienting,
        keyRing: any TeleportCredentialStore,
        credentialID: Data = Data([1, 2, 3, 4]),
        keyPairGenerator: (any TeleportSSHKeyPairGenerating)? = nil,
        privateKeyDataEncoder: ((String) -> Data?)? = nil
    ) throws -> TeleportLoginCoordinator {
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        return TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            keyPairGenerator: keyPairGenerator ?? TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock },
            privateKeyDataEncoder: privateKeyDataEncoder ?? { $0.data(using: .utf8) }
        )
    }

    // MARK: - A superseded atomic pair write cannot tear the credential

    /// A supersession landing while attempt 1's atomic pair write is parked
    /// cannot tear the credential. Attempt 2 completes while attempt 1 is
    /// parked; releasing attempt 1 then lands **pair 1 complete** over pair 2.
    /// Only the stored credential is asserted: attempt 1's continuation
    /// legitimately writes its own terminal `.success` over attempt 2's (the
    /// stale-clobber half is the unported #240/#279 follow-up).
    @MainActor
    func testSupersededPairWriteCannotTearTheLoginCredential() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheLoginCertStore: true
        )
        let http = LoginScriptedHTTPClient()
        let generator = AttemptTaggedSSHKeyPairGenerator(attemptCount: 2)
        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: store,
            credentialID: credentialID,
            keyPairGenerator: generator
        )

        // Distinct per-attempt payloads so a torn final pair is
        // distinguishable from a complete one.
        let attempt1ValidBefore = TeleportFixtureSupport.attemptCertValidBefore.addingTimeInterval(60)
        let attempt1Principals = ["alice-attempt-1"]
        let attempt2ValidBefore = TeleportFixtureSupport.attemptCertValidBefore.addingTimeInterval(120)
        let attempt2Principals = ["alice-attempt-2"]

        let attempt1Cert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: generator.attempts[0].rawKey,
            keyID: cluster.username,
            principals: attempt1Principals,
            validBefore: attempt1ValidBefore
        )
        let attempt2Cert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: generator.attempts[1].rawKey,
            keyID: cluster.username,
            principals: attempt2Principals,
            validBefore: attempt2ValidBefore
        )
        http.loginFinishResponses = [
            TeleportFixtureSupport.makeAttemptLoginFinishResponse(
                attempt: 0,
                generator: generator,
                cluster: cluster,
                validBefore: attempt1ValidBefore,
                principals: attempt1Principals
            ),
            TeleportFixtureSupport.makeAttemptLoginFinishResponse(
                attempt: 1,
                generator: generator,
                cluster: cluster,
                validBefore: attempt2ValidBefore,
                principals: attempt2Principals
            ),
        ]

        // Attempt 1: run to the parked pair write.
        let first = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilFirstCredentialWriteStarted()
        XCTAssertEqual(store.storedPairCount, 0, "attempt 1's pair write is parked, not committed")

        // Attempt 2: supersedes attempt 1 and completes while attempt 1 is
        // still parked.
        let second = Task { await coordinator.begin(cluster: cluster) }
        await second.value

        XCTAssertEqual(
            coordinator.state,
            .success(certValidUntil: attempt2ValidBefore, logins: attempt2Principals),
            "attempt 2's terminal state names its own payload"
        )
        let afterSecond = keyRing.liveCredentialSnapshot(for: cluster.id)
        XCTAssertEqual(afterSecond?.certPEM, attempt2Cert)
        XCTAssertEqual(afterSecond?.privateKeyPEM, Data(generator.attempts[1].privateKeyPEM.utf8))

        // Release attempt 1's parked pair write: it must land attempt 1's
        // complete pair (cert_1 + key_1), never mixing halves.
        await store.releaseFirstCredentialWrite()
        await first.value

        XCTAssertEqual(store.storedPairCount, 2)
        let final = keyRing.liveCredentialSnapshot(for: cluster.id)
        XCTAssertEqual(final?.certPEM, attempt1Cert, "the released pair write lands attempt 1's cert last")
        let finalKeyText = (final?.privateKeyPEM).flatMap { String(data: $0, encoding: .utf8) } ?? "<no key committed>"
        XCTAssertEqual(
            finalKeyText,
            generator.attempts[0].privateKeyPEM,
            "the final key must be attempt 1's — a mismatch means the pair tore (cert_1 + key_2); actual=\(finalKeyText)"
        )
        XCTAssertEqual(
            store.committedCertWriteOrdinal, store.committedKeyWriteOrdinal,
            "the final cert and key halves must come from the same (atomic pair) write invocation"
        )
    }

    // MARK: - Exactly one pair write, zero single writes

    /// T2 (login): exactly one atomic pair write and zero single writes, with
    /// the terminal `.success` as the positive control.
    @MainActor
    func testLoginStoresTheCredentialAsExactlyOnePairWrite() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store, credentialID: credentialID)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(
            coordinator.state,
            .success(
                certValidUntil: Date(timeIntervalSince1970: 2_082_758_400),
                logins: ["alice"]
            )
        )
        XCTAssertEqual(store.storedPairCount, 1)
        XCTAssertEqual(store.singleStoreLoginCertCount, 0)
        XCTAssertEqual(store.singleStoreEd25519PrivateKeyCount, 0)
    }

    // MARK: - The post-throw states

    /// A pair-write throw without a supersession and with no prior usable pair
    /// routes through the D4 nil branch: the flow fails and the user can
    /// retry, and neither half is committed.
    @MainActor
    func testLoginPairStoreFailureWithoutAPriorCredentialFailsTheFlow() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store, credentialID: credentialID)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.unknown("credentials could not be stored")))
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }

    /// D4 (login) non-nil branch: a failed pair write with a usable prior
    /// stored pair reports `.success` with the STORED cert's validity and
    /// principals, not the response's.
    @MainActor
    func testLoginPairStoreFailureWithAPriorPairSucceedsWithTheStoredCert() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let priorCert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: Data(repeating: 0x66, count: 32),
            keyID: cluster.username
        )
        let priorKey = Data("prior-login-ed25519-key".utf8)
        keyRing.storeLoginCert(priorCert, validBefore: TeleportFixtureSupport.attemptCertValidBefore, for: cluster.id)
        try keyRing.storeEd25519PrivateKey(priorKey, for: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)

        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store, credentialID: credentialID)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(
            coordinator.state,
            .success(certValidUntil: TeleportFixtureSupport.attemptCertValidBefore, logins: ["alice"])
        )
        XCTAssertEqual(keyRing.liveCredentialSnapshot(for: cluster.id)?.certPEM, priorCert)
        XCTAssertEqual(keyRing.liveCredentialSnapshot(for: cluster.id)?.privateKeyPEM, priorKey)
    }

    /// F1 (login): the D4 helper must re-apply the stored cert's user-binding
    /// gate. A prior stored pair whose cert belongs to a foreign Teleport user
    /// must not be handed off as a false `.success` when this attempt's pair
    /// write throws: the helper clears the credential and fails closed.
    @MainActor
    func testLoginPairStoreFailureWithAForeignStoredCertClearsAndFails() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let priorCert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: Data(repeating: 0x99, count: 32),
            keyID: "someone-else"  // not cluster.username — the stored cert is foreign
        )
        let priorKey = Data("foreign-prior-login-key".utf8)
        keyRing.storeLoginCert(priorCert, validBefore: TeleportFixtureSupport.attemptCertValidBefore, for: cluster.id)
        try keyRing.storeEd25519PrivateKey(priorKey, for: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)

        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store, credentialID: credentialID)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(
            coordinator.state,
            .failed(.server("Certificate user binding check failed: the certificate does not belong to this Teleport user")),
            "the stored foreign cert must not be handed off as .success"
        )
        XCTAssertNil(keyRing.credentials[cluster.id], "the foreign stored credential was cleared")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }

    /// D3 (login): a `clear(for:)` landing while the login's pair write is
    /// parked makes the write throw `noRegisteredCredential`; the terminal
    /// state must be the dedicated no-record failure, never a silent success
    /// or the generic store-failure text.
    @MainActor
    func testConcurrentClearDuringThePairWriteFailsWithTheNoRecordState() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheLoginCertStore: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(http: http, keyRing: store, credentialID: credentialID)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilFirstCredentialWriteStarted()
        XCTAssertEqual(store.storedPairCount, 0, "the pair write is parked, not committed")

        // The connect-path clear lands while the login is parked.
        await store.clear(for: cluster.id)

        await store.releaseFirstCredentialWrite()
        await beginTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed(.unknown("the registered credential was cleared while the flow was in progress")),
            "the typed no-record error maps to the dedicated message"
        )
        XCTAssertEqual(store.storedPairCount, 0, "the thrown write committed nothing")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }

    /// G5 (login): the `privKeyData == nil` branch is unreachable in production
    /// (a Swift `String` always UTF-8-encodes), so it is driven through the
    /// injected encoder. It must fail closed through the D4 outcome instead of
    /// committing half a credential.
    @MainActor
    func testLoginNilPrivateKeyDataFailsClosedWithoutAWrite() async throws {
        let cluster = makeCluster()
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginResponse = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
        http.scriptedLoginFinishResponse = TeleportFixtureSupport.makeFixtureLoginFinishResponse()
        let coordinator = try makeLoginCoordinator(
            http: http,
            keyRing: store,
            credentialID: credentialID,
            privateKeyDataEncoder: { _ in nil }
        )

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.unknown("credentials could not be stored")))
        XCTAssertEqual(store.storedPairCount, 0, "the nil branch must not attempt a pair write")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
    }
}
