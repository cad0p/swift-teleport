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

/// A `TeleportHTTPClienting` stub whose `headlessLogin`/`loginBegin`/
/// `loginFinish` calls block on a per-call gate until the test releases them
/// with a scripted result. Shared by the bootstrap and login generation
/// suites.
@MainActor
final class GatedTeleportHTTPClient: TeleportHTTPClienting {
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

    // MARK: - Phase-3 login (the login coordinator's per-method gates)

    /// The number of `loginBegin` calls that have started.
    private(set) var loginBeginStartedCount = 0
    /// The number of `loginFinish` calls that have started.
    private(set) var loginFinishStartedCount = 0

    /// Scripted Phase-3 responses, used by the no-result release forms
    /// (`releaseLoginBegin(index:)` / `releaseLoginFinish(index:)`). Seeded
    /// from the committed fixtures so a released call returns a cert the login
    /// coordinator can actually validate.
    var scriptedLoginBeginResponse: LoginBeginResponse? = MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
    var scriptedLoginFinishResponse: LoginFinishResponse? = TeleportFixtureSupport.makeFixtureLoginFinishResponse()

    private var loginBeginGates: [BootstrapGate] = []
    private var loginBeginResults: [Int: Result<LoginBeginResponse, Error>] = [:]
    private var loginBeginStartWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var loginFinishGates: [BootstrapGate] = []
    private var loginFinishResults: [Int: Result<LoginFinishResponse, Error>] = [:]
    private var loginFinishStartWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Suspends until at least `count` `loginBegin` calls have started.
    func waitUntilLoginBeginStarted(_ count: Int) async {
        guard loginBeginStartedCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loginBeginStartWaiters.append((count, continuation))
        }
    }

    /// Suspends until at least `count` `loginFinish` calls have started.
    func waitUntilLoginFinishStarted(_ count: Int) async {
        guard loginFinishStartedCount < count else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loginFinishStartWaiters.append((count, continuation))
        }
    }

    /// A bounded variant of `waitUntilLoginBeginStarted`: `true` when at least
    /// `count` `loginBegin` calls started within `timeout` (see
    /// `waitForStarted` for why the latch tests need the bound).
    func waitForLoginBeginStarted(_ count: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loginBeginStartedCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return loginBeginStartedCount >= count
    }

    /// Release the gate for the `index`-th `loginBegin` call with `result`.
    func releaseLoginBegin(index: Int, with result: Result<LoginBeginResponse, Error>) async {
        guard loginBeginGates.indices.contains(index) else {
            XCTFail("releaseLoginBegin(index: \(index)) but only \(loginBeginGates.count) loginBegin call(s) started")
            return
        }
        loginBeginResults[index] = result
        await loginBeginGates[index].release()
    }

    /// Release the gate for the `index`-th `loginBegin` call with the scripted
    /// response (or the committed fixture when none is scripted).
    func releaseLoginBegin(index: Int) async {
        await releaseLoginBegin(
            index: index,
            with: .success(scriptedLoginBeginResponse ?? MockTeleportHTTPClient.makeFixtureLoginBeginResponse())
        )
    }

    /// Release the gate for the `index`-th `loginFinish` call with `result`.
    func releaseLoginFinish(index: Int, with result: Result<LoginFinishResponse, Error>) async {
        guard loginFinishGates.indices.contains(index) else {
            XCTFail("releaseLoginFinish(index: \(index)) but only \(loginFinishGates.count) loginFinish call(s) started")
            return
        }
        loginFinishResults[index] = result
        await loginFinishGates[index].release()
    }

    /// Release the gate for the `index`-th `loginFinish` call with the scripted
    /// response (or the committed fixture when none is scripted).
    func releaseLoginFinish(index: Int) async {
        await releaseLoginFinish(
            index: index,
            with: .success(scriptedLoginFinishResponse ?? TeleportFixtureSupport.makeFixtureLoginFinishResponse())
        )
    }

    /// Release the `index`-th `loginBegin` gate only when that call has
    /// started, with the scripted response (or the committed fixture). Unlike
    /// `releaseLoginBegin(index:)` this never `XCTFail`s, so a drain path can
    /// call it unconditionally.
    func releaseLoginBeginIfStarted(index: Int) async {
        await releaseLoginBeginIfStarted(
            index: index,
            with: .success(scriptedLoginBeginResponse ?? MockTeleportHTTPClient.makeFixtureLoginBeginResponse())
        )
    }

    /// Release the `index`-th `loginBegin` gate only when that call has started.
    func releaseLoginBeginIfStarted(index: Int, with result: Result<LoginBeginResponse, Error>) async {
        guard loginBeginGates.indices.contains(index) else { return }
        loginBeginResults[index] = result
        await loginBeginGates[index].release()
    }

    /// Release the `index`-th `loginFinish` gate only when that call has
    /// started, with the scripted response (or the committed fixture).
    func releaseLoginFinishIfStarted(index: Int) async {
        await releaseLoginFinishIfStarted(
            index: index,
            with: .success(scriptedLoginFinishResponse ?? TeleportFixtureSupport.makeFixtureLoginFinishResponse())
        )
    }

    /// Release the `index`-th `loginFinish` gate only when that call has started.
    func releaseLoginFinishIfStarted(index: Int, with result: Result<LoginFinishResponse, Error>) async {
        guard loginFinishGates.indices.contains(index) else { return }
        loginFinishResults[index] = result
        await loginFinishGates[index].release()
    }

    func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        let index = loginBeginStartedCount
        let gate = BootstrapGate()
        loginBeginGates.append(gate)
        loginBeginStartedCount += 1
        resumeLoginBeginStartWaiters()

        await gate.wait()
        guard let result = loginBeginResults.removeValue(forKey: index) else {
            throw HeadlessError.transport("loginBegin not scripted", code: nil)
        }
        return try result.get()
    }

    func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
        let index = loginFinishStartedCount
        let gate = BootstrapGate()
        loginFinishGates.append(gate)
        loginFinishStartedCount += 1
        resumeLoginFinishStartWaiters()

        await gate.wait()
        guard let result = loginFinishResults.removeValue(forKey: index) else {
            throw HeadlessError.transport("loginFinish not scripted", code: nil)
        }
        return try result.get()
    }

    private func resumeLoginBeginStartWaiters() {
        guard !loginBeginStartWaiters.isEmpty else { return }
        let ready = loginBeginStartWaiters.filter { $0.target <= loginBeginStartedCount }
        loginBeginStartWaiters.removeAll { $0.target <= loginBeginStartedCount }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func resumeLoginFinishStartWaiters() {
        guard !loginFinishStartWaiters.isEmpty else { return }
        let ready = loginFinishStartWaiters.filter { $0.target <= loginFinishStartedCount }
        loginFinishStartWaiters.removeAll { $0.target <= loginFinishStartedCount }
        for waiter in ready { waiter.continuation.resume() }
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

    // MARK: - A superseded atomic pair write cannot tear the credential

    /// A supersession landing while attempt 1's atomic pair write is parked
    /// cannot tear the credential. Attempt 2 runs to `.success` (pair 2 + TLS
    /// state) while attempt 1 is parked; releasing attempt 1 then lands **pair
    /// 1 complete** over pair 2. The final snapshot is one attempt's complete
    /// pair, and the committed cert and key halves come from the same write
    /// invocation.
    ///
    /// This is a coordinator-shape test with a suspension-capable conformer;
    /// the production atomicity is pinned structurally by
    /// `TeleportCredentialPairPinsTests` (the keyring pair body suspends
    /// nowhere).
    ///
    /// The measured counterfactual (coordinator-only revert to the two
    /// singles) fails this test with `(cert_1, key_2)` — see the PR report.
    @MainActor
    func testSupersededPairWriteCannotTearTheBootstrapCredential() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing)
        let http = GatedTeleportHTTPClient()
        let generator = AttemptTaggedSSHKeyPairGenerator(attemptCount: 2)
        let coordinator = makeCoordinator(http: http, keyRing: store, sshKeyPairGenerator: generator)

        // Distinct per-attempt validity so a stale attempt-1 terminal write is
        // distinguishable from attempt 2's (with identical payloads the
        // final-state assertion below would be vacuous).
        let attempt1ValidBefore = TeleportFixtureSupport.attemptCertValidBefore.addingTimeInterval(60)
        let attempt2ValidBefore = TeleportFixtureSupport.attemptCertValidBefore.addingTimeInterval(120)

        let attempt1Cert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: generator.attempts[0].rawKey,
            keyID: cluster.username,
            validBefore: attempt1ValidBefore
        )
        let attempt2Cert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: generator.attempts[1].rawKey,
            keyID: cluster.username,
            validBefore: attempt2ValidBefore
        )

        // Attempt 1: release its POST so it reaches the pair write and parks.
        let first = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(1)
        await http.release(
            index: 0,
            with: .success(TeleportFixtureSupport.makeAttemptHeadlessResponse(
                attempt: 0,
                generator: generator,
                cluster: cluster,
                validBefore: attempt1ValidBefore
            ))
        )
        await store.waitUntilFirstCredentialWriteStarted()
        XCTAssertEqual(store.storedPairCount, 0, "attempt 1's pair write is parked, not committed")

        // Attempt 2: supersedes attempt 1 and runs to `.success`, landing its
        // complete pair + TLS state while attempt 1 is still parked.
        let second = Task { await coordinator.begin(cluster: cluster) }
        await http.waitUntilStarted(2)
        await http.release(
            index: 1,
            with: .success(TeleportFixtureSupport.makeAttemptHeadlessResponse(
                attempt: 1,
                generator: generator,
                cluster: cluster,
                validBefore: attempt2ValidBefore
            ))
        )
        await second.value

        XCTAssertEqual(coordinator.state, .success)
        XCTAssertEqual(
            coordinator.lastBootstrapResult?.certValidBefore,
            attempt2ValidBefore,
            "attempt 2's result is the current hand-off"
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
        XCTAssertEqual(coordinator.state, .success, "attempt 1's stale pair write must not write the terminal state")
        XCTAssertEqual(
            coordinator.lastBootstrapResult?.certValidBefore,
            attempt2ValidBefore,
            "attempt 1's stale pair write must not overwrite attempt 2's hand-off result"
        )
    }

    // MARK: - Exactly one pair write, zero single writes

    /// T2 (bootstrap): exactly one atomic pair write and zero single writes,
    /// with the terminal `.success` as the positive control (a flow that bails
    /// before the store cannot satisfy it).
    @MainActor
    func testBootstrapStoresTheCredentialAsExactlyOnePairWrite() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .success)
        XCTAssertEqual(store.storedPairCount, 1)
        XCTAssertEqual(store.singleStoreBootstrapCertCount, 0)
        XCTAssertEqual(store.singleStoreEd25519PrivateKeyCount, 0)
    }

    // MARK: - The pair-write failure and the post-throw states

    /// `cancel()` while the pair write is parked, then a throwing key seam on
    /// release — nothing is committed, no TLS state is written, and the
    /// cancel's `.failed(.userCancelled)` wins over the store-failure outcome
    /// (the generation re-take withholds it).
    @MainActor
    func testCancelledRequestDuringPairStoreFailureCommitsNothing() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)
        let store = GatedTeleportCredentialStore(underlying: keyRing)
        let http = GatedTeleportHTTPClient()
        let coordinator = makeCoordinator(http: http, keyRing: store)

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
        XCTAssertEqual(store.storedPairCount, 0, "the throwing write was attempted but committed nothing")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id))
    }

    /// D4 (bootstrap) non-nil branch: a failed pair write with a usable prior
    /// stored pair keeps the hand-off working — `.success` with the STORED
    /// cert's fields, and no TLS state written on this path.
    @MainActor
    func testBootstrapPairStoreFailureWithAPriorPairSucceedsWithTheStoredPair() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let priorCert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: Data(repeating: 0x77, count: 32),
            keyID: cluster.username
        )
        let priorKey = Data("prior-ed25519-private-key".utf8)
        keyRing.seed(
            clusterId: cluster.id,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: Data([1, 2, 3]),
                userHandle: Data("handle".utf8),
                deviceName: "test-device"
            )
        )
        keyRing.storeBootstrapCert(priorCert, validBefore: TeleportFixtureSupport.attemptCertValidBefore, for: cluster.id)
        try keyRing.storeEd25519PrivateKey(priorKey, for: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)

        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .success)
        XCTAssertEqual(coordinator.lastBootstrapResult?.sshCertPEM, priorCert)
        XCTAssertEqual(coordinator.lastBootstrapResult?.certValidBefore, TeleportFixtureSupport.attemptCertValidBefore)
        XCTAssertEqual(keyRing.liveCredentialSnapshot(for: cluster.id)?.certPEM, priorCert)
        XCTAssertEqual(keyRing.liveCredentialSnapshot(for: cluster.id)?.privateKeyPEM, priorKey)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id), "the throw path does not write TLS state")
    }

    /// F1 (bootstrap): the D4 helper must re-apply the stored cert's
    /// user-binding gate. A prior stored pair whose cert belongs to a foreign
    /// Teleport user (the row's username was edited after storage) must not be
    /// handed off as `.success` when this attempt's pair write throws: the
    /// helper clears the credential and fails closed, exactly like the main
    /// path.
    @MainActor
    func testBootstrapPairStoreFailureWithAForeignStoredCertClearsAndFails() async throws {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let priorCert = TeleportFixtureSupport.makeSynthUserCert(
            rawKey: Data(repeating: 0x88, count: 32),
            keyID: "someone-else"  // not cluster.username — the stored cert is foreign
        )
        let priorKey = Data("foreign-prior-ed25519-key".utf8)
        keyRing.seed(
            clusterId: cluster.id,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: Data([1, 2, 3]),
                userHandle: Data("handle".utf8),
                deviceName: "test-device"
            )
        )
        keyRing.storeBootstrapCert(priorCert, validBefore: TeleportFixtureSupport.attemptCertValidBefore, for: cluster.id)
        try keyRing.storeEd25519PrivateKey(priorKey, for: cluster.id)
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)

        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(
            coordinator.state,
            .failed(.unknown("Certificate user binding check failed: the certificate does not belong to this Teleport user")),
            "the stored foreign cert must not be handed off as .success"
        )
        XCTAssertNil(keyRing.credentials[cluster.id], "the foreign stored credential was cleared")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id))
    }

    /// G5 (bootstrap): the `privKeyData == nil` branch is unreachable in
    /// production (a Swift `String` always UTF-8-encodes), so it is driven
    /// through the injected encoder. It must fail closed through the D4
    /// outcome instead of committing half a credential.
    @MainActor
    func testBootstrapNilPrivateKeyDataFailsClosedWithoutAWrite() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        let store = GatedTeleportCredentialStore(underlying: keyRing, gateTheFirstStore: false)
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store, privateKeyDataEncoder: { _ in nil })

        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.unknown("credentials could not be stored")))
        XCTAssertEqual(store.storedPairCount, 0, "the nil branch must not attempt a pair write")
        XCTAssertNil(keyRing.liveCertPEM(for: cluster.id))
        XCTAssertNil(keyRing.liveEd25519PrivateKey(for: cluster.id))
        XCTAssertNil(coordinator.lastBootstrapResult)
        XCTAssertNil(keyRing.clusterTLSState(for: cluster.id))
    }

    /// G5 (bootstrap): the D4 helper's post-read re-take. A `cancel()` landing
    /// while the helper is suspended in `liveCredentialSnapshot` must keep the
    /// helper from writing the store-failure state over `.failed(.userCancelled)`.
    @MainActor
    func testSupersessionDuringTheD4SnapshotReadWithholdsTheStoreFailure() async {
        let cluster = makeCluster()
        let keyRing = MockTeleportKeyRing()
        keyRing.storeEd25519PrivateKeyError = TeleportPackageError.keychain(errSecAuthFailed)
        let store = GatedTeleportCredentialStore(
            underlying: keyRing,
            gateTheFirstStore: false,
            gateTheSnapshotRead: true
        )
        let http = MockTeleportHTTPClient()
        http.scriptedHeadlessResponse = TeleportFixtureSupport.makeFixtureSuccessResponse()
        let coordinator = makeCoordinator(http: http, keyRing: store)

        let beginTask = Task { await coordinator.begin(cluster: cluster) }
        await store.waitUntilSnapshotReadStarted()

        await coordinator.cancel()
        XCTAssertEqual(coordinator.state, .failed(.userCancelled))

        await store.releaseSnapshotRead()
        await beginTask.value

        XCTAssertEqual(
            coordinator.state,
            .failed(.userCancelled),
            "the stale store-failure must not overwrite the cancel's terminal state"
        )
    }
}