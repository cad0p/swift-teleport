// SPDX-License-Identifier: MIT
//
//  TeleportDismissalTests.swift
//  TeleportPackageTests
//
//  The dismissal contract shared by the two coordinators: the exhaustive
//  `dismissalRequiresTeardown` state maps that gate the view's scheduled
//  teardown, and the coordinator-level latch semantics for a dismissal that
//  lands while the login's atomic pair write is parked (the in-flight pair
//  lands complete; the terminal state is withheld). The host view call sites
//  are pinned host-side; these are the package contract.
//

import Foundation
import XCTest
@testable import TeleportCore
@testable import TeleportAuth
import TeleportTesting

nonisolated final class TeleportDismissalTests: XCTestCase {

    /// The login `.onDisappear` gate is an exhaustive switch (no `default`), so
    /// a future state case is a compile error rather than a silent mis-map.
    @MainActor
    func testLoginDismissalRequiresTeardownIsExhaustive() {
        XCTAssertTrue(TeleportLoginState.idle.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportLoginState.awaitingFaceID.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportLoginState.fetchingCert.dismissalRequiresTeardown)
        XCTAssertFalse(
            TeleportLoginState.success(certValidUntil: Date(), logins: ["alice"]).dismissalRequiresTeardown,
            ".success is the host-login hand-off and must survive a dismissal"
        )
        XCTAssertFalse(TeleportLoginState.failed(.faceIDCancelled).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.faceIDUnavailable("locked")).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.server("HTTP 500: boom")).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.networkLost).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.noRegisteredKey).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportLoginState.failed(.unknown("boom")).dismissalRequiresTeardown)
    }

    /// `.onDisappear` teardown is state-guarded for the bootstrap sheet too. The
    /// exhaustive switch makes a future `TeleportBootstrapState` case a compile
    /// error; this test pins the decisions the guard makes, including the two
    /// non-obvious ones.
    @MainActor
    func testBootstrapDismissalRequiresTeardownIsExhaustive() {
        XCTAssertTrue(TeleportBootstrapState.idle.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportBootstrapState.preparing.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportBootstrapState.openingSafari.dismissalRequiresTeardown)
        XCTAssertTrue(TeleportBootstrapState.awaitingApproval.dismissalRequiresTeardown)
        XCTAssertFalse(TeleportBootstrapState.success.dismissalRequiresTeardown)
        XCTAssertTrue(
            TeleportBootstrapState.failed(.safariUnavailable).dismissalRequiresTeardown,
            ".failed(.safariUnavailable) keeps the POST running in begin(), so a late success must still be torn down"
        )
        XCTAssertFalse(TeleportBootstrapState.failed(.userCancelled).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportBootstrapState.failed(.timeout).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportBootstrapState.failed(.networkLost).dismissalRequiresTeardown)
        XCTAssertFalse(
            TeleportBootstrapState.failed(.suspended).dismissalRequiresTeardown,
            ".failed(.suspended) is mock-only; the real coordinator never sets it"
        )
        XCTAssertFalse(TeleportBootstrapState.failed(.server("HTTP 500: boom")).dismissalRequiresTeardown)
        XCTAssertFalse(TeleportBootstrapState.failed(.unknown("boom")).dismissalRequiresTeardown)
    }

    /// The dismissal latch while the login pair write is parked has the same
    /// in-flight-lands rule as `cancel()`: the released pair lands complete
    /// (both halves from one write invocation) and the terminal `.success` is
    /// withheld (the latch itself writes nothing; the view's scheduled teardown
    /// owns the terminal write).
    ///
    /// This mirrors the bootstrap `testLatchDuringParkedPairWriteLandsACompletePair`
    /// and is the login-side acceptance evidence for §4 row 2.
    @MainActor
    func testLatchDuringParkedLoginPairWriteLandsACompletePair() async throws {
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "user-cert-ed25519")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: cluster.id,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: credentialID,
                userHandle: Data("handle".utf8),
                deviceName: "test-device"
            )
        )
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheLoginCertStore: true
        )
        let http = GatedTeleportHTTPClient()
        let generator = AttemptTaggedSSHKeyPairGenerator(attemptCount: 1)

        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: store,
            logging: DefaultTeleportLogging(),
            signer: signer,
            keyPairGenerator: generator,
            now: { TeleportFixtureSupport.fixtureClock }
        )

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilLoginBeginStarted(1)
        await http.releaseLoginBegin(index: 0)
        await http.waitUntilLoginFinishStarted(1)
        await http.releaseLoginFinish(
            index: 0,
            with: .success(TeleportFixtureSupport.makeAttemptLoginFinishResponse(
                attempt: 0,
                generator: generator,
                cluster: cluster
            ))
        )
        await store.waitUntilFirstCredentialWriteStarted()
        XCTAssertEqual(store.storedPairCount, 0, "attempt 1's pair write is parked, not committed")

        coordinator.latchDismissal()
        XCTAssertTrue(coordinator.isDismissalLatched)
        coordinator.latchDismissal()  // idempotent

        await store.releaseFirstCredentialWrite()
        await beginTask.value

        XCTAssertEqual(store.storedPairCount, 1, "the in-flight pair write is allowed to land complete")
        let final = keyRing.liveCredentialSnapshot(for: cluster.id)
        XCTAssertEqual(
            final?.certPEM,
            TeleportFixtureSupport.makeSynthUserCert(
                rawKey: generator.attempts[0].rawKey,
                keyID: cluster.username
            )
        )
        XCTAssertEqual(final?.privateKeyPEM, Data(generator.attempts[0].privateKeyPEM.utf8))
        XCTAssertEqual(
            store.committedCertWriteOrdinal, store.committedKeyWriteOrdinal,
            "both halves must come from the same (atomic pair) write invocation"
        )
        XCTAssertEqual(
            coordinator.state,
            .fetchingCert,
            "the latch withholds the terminal state; cancel() (the call site's second half) owns it"
        )
    }
}
