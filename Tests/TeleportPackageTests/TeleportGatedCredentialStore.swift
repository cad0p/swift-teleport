// SPDX-License-Identifier: MIT
//
//  TeleportGatedCredentialStore.swift
//  TeleportPackageTests
//
//  The continuation-gated `TeleportCredentialStore` double shared by the
//  bootstrap and login generation suites. It gates credential writes (the
//  atomic pair write, the single writes in the reverted two-call shape, and/or
//  the final cluster-TLS store) on a continuation, so a test can interleave a
//  supersession while the coordinator is suspended *inside* the persistence
//  sequence. Reads and the ungated writes delegate to the underlying mock;
//  writes are counted. The credentialID/userHandle reads, the pinned-name
//  read, the Host-CA refresh and `liveCredentialSnapshot` can also be gated,
//  so a test can supersede the coordinator during a read or a fail-closed
//  `clear`.
//
//  The first credential write — the atomic pair write in the new shape, or the
//  first single in the reverted two-call shape — also parks on a shared
//  hold-first gate (before any mutation) so a test can interleave a
//  supersession at the top of the write. Later writes pass through, so a second
//  attempt can complete while the first attempt's write is parked.
//

import Foundation
import TeleportCore
import TeleportTesting

/// A per-call gate: `wait()` suspends until `release()` is called (or returns
/// immediately if it was already released). An actor so it is safe to hold a
/// `CheckedContinuation` across the store's isolation boundary.
actor BootstrapGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor
final class GatedTeleportCredentialStore: TeleportCredentialStore {
    private let underlying: MockTeleportKeyRing
    private let certGate = BootstrapGate()
    private let tlsGate = BootstrapGate()
    private let loginCertGate = BootstrapGate()
    private let clearGate = BootstrapGate()
    private let snapshotGate = BootstrapGate()
    // The four #298 read/refresh gates park **every** call, unlike the
    // claim-once `firstWriteGate`. That is safe only because every test that
    // enables one is single-attempt: the gated read/refresh is reached by
    // exactly one `begin`, so a gate can never be a second caller's blocker.
    // If a test ever adds a second attempt to a gated call, the gate must
    // become claim-once (see `holdFirstCredentialWriteIfNeeded`).
    private let registeredCredentialIDGate = BootstrapGate()
    private let registeredUserHandleGate = BootstrapGate()
    private let clusterTLSStateGate = BootstrapGate()
    private let updateClusterHostKeysGate = BootstrapGate()
    /// The shared hold-first gate: parks only the *first* credential write
    /// across both shapes, before any mutation. Later credential writes pass
    /// through.
    private let firstWriteGate = BootstrapGate()
    private var firstWriteClaimed = false
    private let gateTheFirstStore: Bool
    private let gateTheLastStore: Bool
    private let gateTheLoginCertStore: Bool
    private let gateTheClear: Bool
    private let gateTheSnapshotRead: Bool
    private let gateTheRegisteredCredentialIDRead: Bool
    private let gateTheRegisteredUserHandleRead: Bool
    private let gateTheClusterTLSStateRead: Bool
    private let gateTheUpdateClusterHostKeys: Bool

    private var certStoreStarted = false
    private var certStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var tlsStoreStarted = false
    private var tlsStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginCertStoreStarted = false
    private var loginCertStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearStarted = false
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWriteStarted = false
    private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotReadStarted = false
    private var snapshotReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var registeredCredentialIDReadStarted = false
    private var registeredCredentialIDReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var registeredUserHandleReadStarted = false
    private var registeredUserHandleReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var clusterTLSStateReadStarted = false
    private var clusterTLSStateReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var updateClusterHostKeysStarted = false
    private var updateClusterHostKeysWaiters: [CheckedContinuation<Void, Never>] = []

    /// Committed write counts: incremented only after the underlying store
    /// accepted the write, so a throwing write (the `.login` no-record case,
    /// or a keychain-status throw) is never counted as stored.
    private(set) var storedCertCount = 0
    private(set) var storedPrivateKeyCount = 0
    private(set) var storedTLSStateCount = 0
    private(set) var storedLoginCertCount = 0
    /// The atomic pair-write count (T2's positive side).
    private(set) var storedPairCount = 0
    /// The fail-closed `clear` count (the login/bootstrap foreign-cert
    /// branch). A clear already in flight when the generation changes is
    /// allowed to land (§1.4), so the discriminating assertion for the
    /// post-`clear` re-take is the withheld terminal state.
    private(set) var clearedCount = 0
    /// The `updateClusterHostKeys` (Host CA refresh) invocation count — the
    /// #298 site-#6 discriminator (site #7's is `storedPairCount`: its
    /// terminal state is masked by the post-pair re-take). The mock mutates
    /// its TLS state in place, so the call itself is the observation point.
    /// Incremented at delegate entry, before the gate.
    private(set) var updateClusterHostKeysCallCount = 0
    /// Direct single-write invocation counts: the legacy counters above stay
    /// populated for existing probes; pair-vs-single discrimination is what
    /// these `singleStore*` counters are for.
    private(set) var singleStoreBootstrapCertCount = 0
    private(set) var singleStoreLoginCertCount = 0
    private(set) var singleStoreEd25519PrivateKeyCount = 0
    /// The write-invocation ordinal of the last *committed* cert / key half.
    /// The pair write installs both halves in one invocation, so a torn pair
    /// (halves from two invocations) is detectable without value comparison;
    /// the two-call counterfactual always leaves these different.
    private(set) var committedCertWriteOrdinal = 0
    private(set) var committedKeyWriteOrdinal = 0
    private var writeOrdinal = 0

    init(
        underlying: MockTeleportKeyRing,
        gateTheFirstStore: Bool = true,
        gateTheLastStore: Bool = false,
        gateTheLoginCertStore: Bool = false,
        gateTheClear: Bool = false,
        gateTheSnapshotRead: Bool = false,
        gateTheRegisteredCredentialIDRead: Bool = false,
        gateTheRegisteredUserHandleRead: Bool = false,
        gateTheClusterTLSStateRead: Bool = false,
        gateTheUpdateClusterHostKeys: Bool = false
    ) {
        self.underlying = underlying
        self.gateTheFirstStore = gateTheFirstStore
        self.gateTheLastStore = gateTheLastStore
        self.gateTheLoginCertStore = gateTheLoginCertStore
        self.gateTheClear = gateTheClear
        self.gateTheSnapshotRead = gateTheSnapshotRead
        self.gateTheRegisteredCredentialIDRead = gateTheRegisteredCredentialIDRead
        self.gateTheRegisteredUserHandleRead = gateTheRegisteredUserHandleRead
        self.gateTheClusterTLSStateRead = gateTheClusterTLSStateRead
        self.gateTheUpdateClusterHostKeys = gateTheUpdateClusterHostKeys
    }

    /// Suspends until the gated `storeBootstrapCert` (or the `.bootstrap` pair
    /// write) has been entered.
    func waitUntilCertStoreStarted() async {
        guard !certStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            certStoreWaiters.append(continuation)
        }
    }

    /// Suspends until the gated `storeClusterTLSState` has been entered.
    func waitUntilTLSStoreStarted() async {
        guard !tlsStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            tlsStoreWaiters.append(continuation)
        }
    }

    /// Suspends until the gated login-cert write (or the `.login` pair write)
    /// has been entered.
    func waitUntilLoginCertStoreStarted() async {
        guard !loginCertStoreStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loginCertStoreWaiters.append(continuation)
        }
    }

    /// Suspends until the first credential write (the atomic pair write, or
    /// the first single in the reverted two-call shape) is entered.
    func waitUntilFirstCredentialWriteStarted() async {
        guard !firstWriteStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            firstWriteWaiters.append(continuation)
        }
    }

    /// Suspends until the gated `liveCredentialSnapshot` has been entered.
    func waitUntilSnapshotReadStarted() async {
        guard !snapshotReadStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            snapshotReadWaiters.append(continuation)
        }
    }

    func releaseSnapshotRead() async {
        await snapshotGate.release()
    }

    func releaseCertStore() async {
        await certGate.release()
        // The atomic pair write parks on the shared gate instead of the
        // per-single cert gate; releasing either name must unpark it.
        await firstWriteGate.release()
    }

    func releaseTLSStore() async {
        await tlsGate.release()
    }

    func releaseLoginCertStore() async {
        await loginCertGate.release()
        await firstWriteGate.release()
    }

    func releaseClear() async {
        await clearGate.release()
    }

    /// Releases the parked first credential write in either shape.
    func releaseFirstCredentialWrite() async {
        await firstWriteGate.release()
        await certGate.release()
        await loginCertGate.release()
    }

    /// Suspends until the gated `clear` has been entered.
    func waitUntilClearStarted() async {
        guard !clearStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            clearWaiters.append(continuation)
        }
    }

    private func signalClearStarted() {
        clearStarted = true
        let waiters = clearWaiters
        clearWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until the gated `registeredCredentialID` read has been entered.
    func waitUntilRegisteredCredentialIDReadStarted() async {
        guard !registeredCredentialIDReadStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registeredCredentialIDReadWaiters.append(continuation)
        }
    }

    func releaseRegisteredCredentialIDRead() async {
        await registeredCredentialIDGate.release()
    }

    /// Suspends until the gated `registeredUserHandle` read has been entered.
    func waitUntilRegisteredUserHandleReadStarted() async {
        guard !registeredUserHandleReadStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registeredUserHandleReadWaiters.append(continuation)
        }
    }

    func releaseRegisteredUserHandleRead() async {
        await registeredUserHandleGate.release()
    }

    /// Suspends until the gated `clusterTLSState` read has been entered.
    func waitUntilClusterTLSStateReadStarted() async {
        guard !clusterTLSStateReadStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            clusterTLSStateReadWaiters.append(continuation)
        }
    }

    func releaseClusterTLSStateRead() async {
        await clusterTLSStateGate.release()
    }

    /// Suspends until the gated `updateClusterHostKeys` has been entered.
    func waitUntilUpdateClusterHostKeysStarted() async {
        guard !updateClusterHostKeysStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            updateClusterHostKeysWaiters.append(continuation)
        }
    }

    func releaseUpdateClusterHostKeys() async {
        await updateClusterHostKeysGate.release()
    }

    // MARK: - Reads (delegate)

    func clusterTLSState(for clusterId: UUID) async -> TeleportClusterTLSState? {
        if gateTheClusterTLSStateRead {
            clusterTLSStateReadStarted = true
            let waiters = clusterTLSStateReadWaiters
            clusterTLSStateReadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await clusterTLSStateGate.wait()
        }
        return underlying.clusterTLSState(for: clusterId)
    }

    func liveCertPEM(for clusterId: UUID) async -> String? {
        underlying.liveCertPEM(for: clusterId)
    }

    func liveCredentialSnapshot(for clusterId: UUID) async -> (certPEM: String, privateKeyPEM: Data)? {
        if gateTheSnapshotRead {
            snapshotReadStarted = true
            let waiters = snapshotReadWaiters
            snapshotReadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await snapshotGate.wait()
        }
        return underlying.liveCredentialSnapshot(for: clusterId)
    }

    func liveEd25519PrivateKey(for clusterId: UUID) async -> Data? {
        underlying.liveEd25519PrivateKey(for: clusterId)
    }

    func registeredCredentialID(for clusterId: UUID) async -> Data? {
        if gateTheRegisteredCredentialIDRead {
            registeredCredentialIDReadStarted = true
            let waiters = registeredCredentialIDReadWaiters
            registeredCredentialIDReadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await registeredCredentialIDGate.wait()
        }
        return underlying.registeredCredentialID(for: clusterId)
    }

    func registeredUserHandle(for clusterId: UUID) async -> Data? {
        if gateTheRegisteredUserHandleRead {
            registeredUserHandleReadStarted = true
            let waiters = registeredUserHandleReadWaiters
            registeredUserHandleReadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await registeredUserHandleGate.wait()
        }
        return underlying.registeredUserHandle(for: clusterId)
    }

    // MARK: - Writes

    /// Parks the first credential write across both shapes: the pair write
    /// parks on the shared `firstWriteGate`, the first single (the two-call
    /// counterfactual) on its per-single gate. Later writes pass through. The
    /// wait sits before any mutation, never between a write's own mutations.
    private func holdFirstCredentialWriteIfNeeded(gate: BootstrapGate) async {
        guard !firstWriteClaimed else { return }
        firstWriteClaimed = true
        firstWriteStarted = true
        let waiters = firstWriteWaiters
        firstWriteWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await gate.wait()
    }

    private func signalCertStoreStarted() {
        certStoreStarted = true
        let waiters = certStoreWaiters
        certStoreWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func signalLoginCertStoreStarted() {
        loginCertStoreStarted = true
        let waiters = loginCertStoreWaiters
        loginCertStoreWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async {
        if gateTheFirstStore {
            signalCertStoreStarted()
            await holdFirstCredentialWriteIfNeeded(gate: certGate)
        }
        writeOrdinal += 1
        let ordinal = writeOrdinal
        singleStoreBootstrapCertCount += 1
        storedCertCount += 1
        underlying.storeBootstrapCert(certPEM, validBefore: validBefore, for: clusterId)
        committedCertWriteOrdinal = ordinal
    }

    func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    ) async {
        underlying.storeRegisteredSEPKey(
            credentialID: credentialID,
            userHandle: userHandle,
            publicKeyRaw: publicKeyRaw,
            deviceName: deviceName,
            for: clusterId
        )
    }

    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async {
        if gateTheLoginCertStore {
            signalLoginCertStoreStarted()
            await holdFirstCredentialWriteIfNeeded(gate: loginCertGate)
        }
        writeOrdinal += 1
        let ordinal = writeOrdinal
        singleStoreLoginCertCount += 1
        storedLoginCertCount += 1
        underlying.storeLoginCert(certPEM, validBefore: validBefore, for: clusterId)
        committedCertWriteOrdinal = ordinal
    }

    func storeCredentialPair(
        _ certPEM: String,
        validBefore: Date,
        privateKeyPEM: Data,
        policy: TeleportCredentialWritePolicy,
        for clusterId: UUID
    ) async throws {
        switch policy {
        case .bootstrap:
            if gateTheFirstStore {
                signalCertStoreStarted()
                await holdFirstCredentialWriteIfNeeded(gate: firstWriteGate)
            }
        case .login:
            if gateTheLoginCertStore {
                signalLoginCertStoreStarted()
                await holdFirstCredentialWriteIfNeeded(gate: firstWriteGate)
            }
        }
        // The counting block runs only after the underlying store accepted the
        // write, so a throw (the `.login` no-record case, or a keychain-status
        // throw) counts as attempted-but-not-committed. Both halves of the
        // committed pair share this invocation's ordinal.
        try underlying.storeCredentialPair(
            certPEM,
            validBefore: validBefore,
            privateKeyPEM: privateKeyPEM,
            policy: policy,
            for: clusterId
        )
        writeOrdinal += 1
        let ordinal = writeOrdinal
        storedPairCount += 1
        storedCertCount += 1
        storedLoginCertCount += 1
        storedPrivateKeyCount += 1
        committedCertWriteOrdinal = ordinal
        committedKeyWriteOrdinal = ordinal
    }

    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) async throws {
        try underlying.storeEd25519PrivateKey(pemData, for: clusterId)
        writeOrdinal += 1
        let ordinal = writeOrdinal
        singleStoreEd25519PrivateKeyCount += 1
        storedPrivateKeyCount += 1
        committedKeyWriteOrdinal = ordinal
    }

    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID) async {
        if gateTheLastStore {
            tlsStoreStarted = true
            let waiters = tlsStoreWaiters
            tlsStoreWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await tlsGate.wait()
        }
        storedTLSStateCount += 1
        underlying.storeClusterTLSState(state, for: clusterId)
    }

    func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) async -> TeleportHostKeyUpdateResult {
        updateClusterHostKeysCallCount += 1
        if gateTheUpdateClusterHostKeys {
            updateClusterHostKeysStarted = true
            let waiters = updateClusterHostKeysWaiters
            updateClusterHostKeysWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await updateClusterHostKeysGate.wait()
        }
        return underlying.updateClusterHostKeys(checkingKeys, for: clusterId)
    }

    func clear(for clusterId: UUID) async {
        if gateTheClear {
            signalClearStarted()
            await clearGate.wait()
        }
        clearedCount += 1
        underlying.clear(for: clusterId)
    }
}
