// SPDX-License-Identifier: MIT
//
//  TeleportBootstrapCoordinatorRetryTests.swift
//  TeleportPackageTests
//
//  The #267 retry contract: the bootstrap sheet's "Reopen Safari" button calls
//  `retry()` only, so `retry()` itself must re-run the whole bootstrap — a
//  fresh POST and a fresh Safari session — with the cluster of the last
//  `begin` call. Ported from the host's `TeleportBootstrapViewWiringTests`
//  (#267, host `24e27af5`).
//

import Foundation
import Testing
@testable import TeleportCore
@testable import TeleportAuth
import TeleportTesting

@MainActor
struct TeleportBootstrapCoordinatorRetryTests {

    private func makeCluster() -> TeleportCluster {
        // The fixture user cert's keyID is `user-cert-ed25519`; the bootstrap
        // coordinator binds `cert.keyID` to the cluster's Teleport user, so
        // the test cluster must name that user (see #262).
        TeleportCluster(host: "teleport.pcad.it", username: "user-cert-ed25519")
    }

    private func makeCoordinator(
        http: MockTeleportHTTPClient,
        safari: MockWebAuthenticationSessionPresenter
    ) -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: MockTeleportKeyRing(),
            safariPresenter: safari,
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
    }

    /// The discriminator (CF-A1): the first attempt fails, so `retry()` must
    /// start a second POST and reopen Safari, landing back on `.failed`
    /// instead of leaving the sheet on `.idle` with no POST and no Safari.
    /// With the old `.idle`-only `retry()`, the call count stays 1.
    @Test
    func retryStartsAFreshPostAndReopensSafari() async {
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessError = URLError(.notConnectedToInternet)
        let safari = MockWebAuthenticationSessionPresenter()
        let coordinator = makeCoordinator(http: http, safari: safari)

        await coordinator.begin(cluster: makeCluster())
        #expect(coordinator.state == .failed(.networkLost))
        #expect(http.headlessLoginCallCount == 1)
        #expect(safari.openedURLs.count == 1)

        await coordinator.retry()

        #expect(http.headlessLoginCallCount == 2, "retry() must start a fresh POST (#267)")
        #expect(safari.openedURLs.count == 2, "retry() must reopen Safari (#267)")
        #expect(coordinator.state == .failed(.networkLost))
    }

    /// The success half: the retry's fresh POST can succeed, so the sheet
    /// advances out of the failure state instead of waiting forever.
    @Test
    func retryReachesSuccessOnASecondSuccessfulPost() async {
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessError = URLError(.notConnectedToInternet)
        let safari = MockWebAuthenticationSessionPresenter()
        let coordinator = makeCoordinator(http: http, safari: safari)

        await coordinator.begin(cluster: makeCluster())
        #expect(coordinator.state == .failed(.networkLost))

        http.scriptedHeadlessError = nil
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()

        await coordinator.retry()

        #expect(http.headlessLoginCallCount == 2)
        #expect(coordinator.state == .success)
        #expect(coordinator.lastBootstrapResult != nil)
    }

    /// Defensive: a `retry()` before any `begin` has nothing to re-run and
    /// must not start a POST (the `guard let lastCluster` half).
    @Test
    func retryWithoutAPriorBeginIsANoOp() async {
        let http = MockTeleportHTTPClient()
        let safari = MockWebAuthenticationSessionPresenter()
        let coordinator = makeCoordinator(http: http, safari: safari)

        await coordinator.retry()

        #expect(http.headlessLoginCallCount == 0)
        #expect(safari.openedURLs.isEmpty)
        #expect(coordinator.state == .idle)
    }
}
