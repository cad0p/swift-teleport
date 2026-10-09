// SPDX-License-Identifier: MIT
//
//  TeleportBootstrapCoordinatorGenerationTests.swift
//  TeleportPackageTests
//
//  Pins `TeleportBootstrapCoordinator`'s request-generation guard (issue
//  #222): a stale POST continuation (the request was cancelled, or superseded
//  by a newer `begin()`) must not overwrite the state a newer attempt owns.
//
//  The HTTP gate is a continuation-gated `TeleportHTTPClienting` stub, so the
//  tests are deterministic and use no sleeps: the POST is held at the gate,
//  the coordinator state is changed out from under it, and the gate is then
//  released.
//
//  Further tests gate the *keyring writes* instead, so `cancel()` can
//  interleave between the POST release and the terminal state write — the
//  window the post-`await` re-take guards exist for (B1/S2). Without that
//  interleaving the re-take guards would be unreachable: a generation bump
//  before the handler is entered is caught by the entry guard. They gate the
//  first credential write (the atomic pair write), the last store (cluster
//  TLS state), and the D4 helper's `liveCredentialSnapshot` read. The D4
//  section covers the helper's stored-cert user-binding gate, the
//  `privKeyData == nil` branch (unreachable in production; driven through the
//  injected encoder), and the helper's post-read supersession re-take.
//

import Combine
import Foundation
import XCTest
@testable import TeleportCore
@testable import TeleportAuth
import TeleportTesting

/// A `TeleportHTTPClienting` stub whose `headlessLogin` blocks on a per-call
/// gate until the test releases it with a scripted result.
@MainActor
private final class GatedTeleportHTTPClient: TeleportHTTPClienting {
    /// The number of `headlessLogin` calls that have started.
    private(set) var startedCount = 0
    private var gates: [BootstrapGate] = []
    private var scriptedResults: [Int: Result<HeadlessLoginResponse, Error>] = [:]
    private var startWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Suspends until at least `count` `headlessLogin` calls have started.
    /// Signalled from `headlessLogin` entry — no polling, no deadline. A test
    /// that awaits a count that never arrives is killed by the suite's
    /// execution allowance rather than trapping.
    func waitUntilStarted(_ count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append((count, continuation))
        }
    }

    /// Release the gate for the `index`-th `headlessLogin` call with `result`.
    func release(index: Int, with result: Result<HeadlessLoginResponse, Error>) async {
        guard gates.indices.contains(index) else {
            XCTFail("release(index: \(index)) but only \(gates.count) headlessLogin call(s) started")
            return
        }
        scriptedResults[index] = result
        await gates[index].release()
    }

    func headlessLogin(
        baseURL: URL,
        user: String,
        headlessAuthenticationID: String,
        sshPubKeyB64: String,
        tlsPubKeyB64: String?,
        ttl: Int64
    ) async throws -> HeadlessLoginResponse {
        let index = startedCount
        let gate = BootstrapGate()
        gates.append(gate)
        startedCount += 1
        resumeStartWaiters()

        await gate.wait()
        guard let result = scriptedResults.removeValue(forKey: index) else {
            throw HeadlessError.transport("headlessLogin not scripted", code: nil)
        }
        return try result.get()
    }

    private func resumeStartWaiters() {
        guard !startWaiters.isEmpty else { return }
        let ready = startWaiters.filter { $0.target <= startedCount }
        startWaiters.removeAll { $0.target <= startedCount }
        for waiter in ready { waiter.continuation.resume() }
    }

    // Not exercised by the bootstrap coordinator.

    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        throw HeadlessError.transport("loginBegin not scripted", code: nil)
    }

    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
        throw HeadlessError.transport("loginFinish not scripted", code: nil)
    }
}

/// A `WebAuthenticationSessionPresenting` stub whose `open(url:)` blocks on a
/// per-call gate, so a test can interleave a `cancel()`/newer `begin()` while
/// the coordinator is suspended in the presenter await (S1).
@MainActor
private final class GatedWebAuthenticationSessionPresenter: WebAuthenticationSessionPresenting {
    private(set) var openCount = 0
    private var openGates: [BootstrapGate] = []
    private var openResults: [Int: Bool] = [:]
    private var openWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func waitUntilOpenStarted(_ count: Int) async {
        guard openCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            openWaiters.append((count, continuation))
        }
    }

    func releaseOpen(index: Int, result: Bool) async {
        guard openGates.indices.contains(index) else {
            XCTFail("releaseOpen(index: \(index)) but only \(openGates.count) open call(s) started")
            return
        }
        openResults[index] = result
        await openGates[index].release()
    }

    func open(url: URL) async -> Bool {
        let index = openCount
        let gate = BootstrapGate()
        openGates.append(gate)
        openCount += 1
        let ready = openWaiters.filter { $0.target <= openCount }
        openWaiters.removeAll { $0.target <= openCount }
        for waiter in ready { waiter.continuation.resume() }

        await gate.wait()
        return openResults[index] ?? true
    }

    func cancel() {}
}

nonisolated final class TeleportBootstrapCoordinatorGenerationTests: XCTestCase {

    @MainActor
    private func makeCluster() -> TeleportCluster {
        // The fixture user cert's keyID is `user-cert-ed25519`; the bootstrap
        // coordinator binds `cert.keyID` to the cluster's Teleport user, so
        // the test cluster must name that user (see #262).
        TeleportCluster(host: "teleport.pcad.it", username: "user-cert-ed25519")
    }

    @MainActor
    private func makeCoordinator(
        http: any TeleportHTTPClienting,
        keyRing: any TeleportCredentialStore,
        presenter: (any WebAuthenticationSessionPresenting)? = nil,
        sshKeyPairGenerator: (any TeleportSSHKeyPairGenerating)? = nil,
        privateKeyDataEncoder: ((String) -> Data?)? = nil
    ) -> TeleportBootstrapCoordinator {
        TeleportBootstrapCoordinator(
            httpClient: http,
            keyRing: keyRing,
            safariPresenter: presenter ?? MockWebAuthenticationSessionPresenter(),
            logging: DefaultTeleportLogging(),
            signer: MockSEPKeySigner(outcome: .success),
            sshKeyPairGenerator: sshKeyPairGenerator ?? TeleportFixtureSupport.makeFixedSSHGenerator(),
            tlsKeyPairGenerator: try! TeleportFixtureSupport.makeFixedTLSGenerator(),
            now: { TeleportFixtureSupport.fixtureClock },
            privateKeyDataEncoder: privateKeyDataEncoder ?? { $0.data(using: .utf8) }
        )
    }

    /// Suspends until `coordinator.state` becomes `expected`. Driven by the
    /// `@Published` state, so it is signal-based (no polling).
    @MainActor
    private func awaitState(
        _ expected: TeleportBootstrapState,
        on coordinator: TeleportBootstrapCoordinator
    ) async {
        if coordinator.state == expected { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            var cancellable: AnyCancellable?
            cancellable = coordinator.$state.sink { state in
                guard !resumed, state == expected else { return }
                resumed = true
                continuation.resume()
                cancellable?.cancel()
            }
        }
    }

    /// A superseded `begin()` that resumes from the presenter await with a
    /// failed open must not write `.failed(.safariUnavailable)` over the newer
    /// attempt's `.awaitingApproval` (S1). The post-`open` re-take is the only
    /// thing that prevents it: the state-case check alone lets the stale write
    /// through because the newer attempt is in `.awaitingApproval`.
    @MainActor
    func testSupersededBeginDoesNotClobberTheNewerAttemptsAwaitingApproval() async {
        let http = GatedTeleportHTTPClient()
        let presenter = GatedWebAuthenticationSessionPresenter()
        let coordinator = makeCoordinator(
            http: http,
            keyRing: MockTeleportKeyRing(),
            presenter: presenter
        )
        let cluster = makeCluster()

        let first = Task { await coordinator.begin(cluster: cluster) }
        await presenter.waitUntilOpenStarted(1)

        let second = Task { await coordinator.begin(cluster: cluster) }
        await presenter.waitUntilOpenStarted(2)

        // The newer attempt opens Safari and reaches `.awaitingApproval`.
        await presenter.releaseOpen(index: 1, result: true)
        await awaitState(.awaitingApproval, on: coordinator)

        // The superseded first attempt now resumes with a failed open.
        await presenter.releaseOpen(index: 0, result: false)
        // Drain the first attempt's POST (cancelled by the newer begin) so it
        // cannot outlive the test.
        await http.release(index: 0, with: .failure(HeadlessError.http(status: 403, body: "denied")))
        await first.value

        XCTAssertEqual(coordinator.state, .awaitingApproval)

        // Drain the second attempt so its POST task does not outlive the test.
        await http.release(index: 1, with: .failure(HeadlessError.http(status: 403, body: "denied")))
        await second.value
    }

    /// `cancel()` bumps the generation, so a failure continuation that
    /// resumes afterwards must not overwrite `.userCancelled`.
    @MainActor
    func testCancelledRequestDiscardsAStaleFailureContinuation() async {
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: MockTeleportKeyRing())

        let beginTask = Task { await coordinator.begin(cluster: makeCluster()) }
        await http.waitUntilStarted(1)

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await http.release(index: 0, with: .failure(HeadlessError.http(status: 403, body: "denied")))
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
    }

    /// Even a *successful* stale continuation must not land: it would flip the
    /// state to `.success` after the user cancelled.
    @MainActor
    func testCancelledRequestDiscardsAStaleSuccessContinuation() async {
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: MockTeleportKeyRing())

        let beginTask = Task { await coordinator.begin(cluster: makeCluster()) }
        await http.waitUntilStarted(1)

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await http.release(
            index: 0,
            with: .success(TeleportFixtureSupport.makeFixtureSuccessResponse())
        )
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
    }

    /// A stale success from the first attempt must not land after a newer
    /// `begin()` took over; the newer attempt's own success still lands.
    @MainActor
    func testStaleSuccessCannotOverwriteANewerBegin() async {
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: MockTeleportKeyRing())
        let cluster = makeCluster()

        let first = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)

        let second = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(2)

        await http.release(
            index: 0,
            with: .success(TeleportFixtureSupport.makeFixtureSuccessResponse())
        )
        await first.value

        // The second attempt is still in flight; the stale success must not
        // have produced the terminal state.
        XCTAssertNotEqual(coordinator.state, .success)

        await http.release(
            index: 1,
            with: .success(TeleportFixtureSupport.makeFixtureSuccessResponse())
        )
        await second.value

        XCTAssertEqual(coordinator.state, .success)
    }

    /// Interleave `cancel()` while the coordinator is suspended *inside* the
    /// final keyring store. The re-take after the last `await` must keep the
    /// stale success from committing the terminal state or the in-memory
    /// result — this is the window the final guard exists for, and the three
    /// entry-guard tests above never reach it.
    ///
    /// Counterfactual (measured): deleting the re-take immediately before
    /// `lastBootstrapResult = result` / `state = .success` makes this test
    /// fail with `state == .success`.
    @MainActor
    func testCancelledRequestDuringFinalKeyringStoreDiscardsStaleSuccess() async {
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false, gateTheLastStore: true)
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: store)
        let cluster = makeCluster()

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)

        await http.release(
            index: 0,
            with: .success(TeleportFixtureSupport.makeFixtureSuccessResponse())
        )
        await store.waitUntilTLSStoreStarted()

        // The coordinator is now suspended between the POST release and the
        // terminal state write.
        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await store.releaseTLSStore()
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertNil(coordinator.lastBootstrapResult)
    }

    /// Interleave `cancel()` while the coordinator is suspended *inside* the
    /// atomic pair write. The pair write was already in flight when the cancel
    /// landed, so it is allowed to land **complete** (§1.4) — the credential
    /// can never be torn. The later cluster-TLS write, the in-memory result
    /// and the terminal state must all be withheld. The explicit TLS
    /// assertions are the deleted middle-store test's coverage: they pin the
    /// post-credential re-take guard.
    @MainActor
    func testCancelledRequestDuringFirstKeyringStoreLetsTheInFlightPairLand() async {
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing)
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: store)
        let cluster = makeCluster()

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)

        await http.release(
            index: 0,
            with: .success(TeleportFixtureSupport.makeFixtureSuccessResponse())
        )
        await store.waitUntilFirstCredentialWriteStarted()

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await store.releaseFirstCredentialWrite()
        await beginTask.value

        XCTAssertEqual(coordinator.state, .failed(.userCancelled))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertEqual(store.storedPairCount, 1, "the in-flight pair write is allowed to land complete")
        XCTAssertEqual(store.storedPrivateKeyCount, 1)
        XCTAssertNotNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNotNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
        XCTAssertEqual(store.storedTLSStateCount, 0)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id))
    }
}