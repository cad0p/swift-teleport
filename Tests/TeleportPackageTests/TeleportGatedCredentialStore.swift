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
//  writes are counted. `liveCredentialSnapshot` can also be gated, so a test
//  can supersede the bootstrap coordinator during a D4 helper's snapshot read.
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
    private let snapshotGate = BootstrapGate()
    /// The shared hold-first gate: parks only the *first* credential write
    /// across both shapes, before any mutation. Later credential writes pass
    /// through.
    private let firstWriteGate = BootstrapGate()
    private var firstWriteClaimed = false
    private let gateTheFirstStore: Bool
    private let gateTheLastStore: Bool
    private let gateTheLoginCertStore: Bool
    private let gateTheSnapshotRead: Bool

    private var certStoreStarted = false
    private var certStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var tlsStoreStarted = false
    private var tlsStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var loginCertStoreStarted = false
    private var loginCertStoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWriteStarted = false
    private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var snapshotReadStarted = false
    private var snapshotReadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Committed write counts: incremented only after the underlying store
    /// accepted the write, so a throwing write (the `.login` no-record case,
    /// or a keychain-status throw) is never counted as stored.
    private(set) var storedCertCount = 0
    private(set) var storedPrivateKeyCount = 0
    private(set) var storedTLSStateCount = 0
    private(set) var storedLoginCertCount = 0
    /// The atomic pair-write count (T2's positive side).
    private(set) var storedPairCount = 0
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
        gateTheSnapshotRead: Bool = false
    ) {
        self.underlying = underlying
        self.gateTheFirstStore = gateTheFirstStore
        self.gateTheLastStore = gateTheLastStore
        self.gateTheLoginCertStore = gateTheLoginCertStore
        self.gateTheSnapshotRead = gateTheSnapshotRead
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

    /// Releases the parked first credential write in either shape.
    func releaseFirstCredentialWrite() async {
        await firstWriteGate.release()
        await certGate.release()
        await loginCertGate.release()
    }

    // MARK: - Reads (delegate)

    func clusterTLSState(for clusterId: UUID) async -> TeleportClusterTLSState? {
        underlying.clusterTLSState(for: clusterId)
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
        underlying.registeredCredentialID(for: clusterId)
    }

    func registeredUserHandle(for clusterId: UUID) async -> Data? {
        underlying.registeredUserHandle(for: clusterId)
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
        underlying.updateClusterHostKeys(checkingKeys, for: clusterId)
    }

    func clear(for clusterId: UUID) async {
        underlying.clear(for: clusterId)
    }
}
