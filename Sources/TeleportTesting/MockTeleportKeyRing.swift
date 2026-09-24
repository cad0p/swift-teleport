// SPDX-License-Identifier: MIT
//
//  MockTeleportKeyRing.swift
//  VVTerm
//
//  A mock `TeleportCredentialStore` implementation for UI tests.
//
//  Scripts the per-cluster credential state so the readiness matrix
//  (mockup B) is fully assertable without a real keychain. The mock lets
//  each test fixture pre-seed a cluster with:
//    - a bootstrap cert (present/absent)
//    - a registered SEP key (present/absent)
//    - a cert expiry (valid/expired/none)
//
//  The readiness computation goes through the real
//  `TeleportDeviceReadinessResolver` (a pure function), so the mock's job is
//  just to return the right probe results for each cluster.
//
//  The host restores its observation conformance (`TeleportKeyRingStoring`,
//  declared host-side) by extension in Phase 2; this mock conforms only to
//  the plain `TeleportCredentialStore` seam.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup B —
//      the 5-row readiness matrix)
//    - VVTerm/Features/Teleport/Application/TeleportKeyRing.swift
//      (TeleportKeyRingStoring protocol + real impl)
//    - VVTerm/Features/Teleport/Domain/TeleportDeviceReadiness.swift
//      (TeleportDeviceReadinessResolver)
//

import Combine
import Foundation
import TeleportCore

/// A mock Teleport key ring that scripts per-cluster credential state for
/// UI tests. Used by `TeleportUITestHarness` to drive the 5-row readiness
/// matrix (ready / needsLogin / needsRegistration / needsBootstrap /
/// cross-device).
@MainActor
public final class MockTeleportKeyRing: ObservableObject, TeleportCredentialStore {

    nonisolated deinit {}
    /// A scripted fixture for a single cluster's credential state.
    public struct Fixture {
        /// Whether a bootstrap cert (PEM) is present.
        public var hasBootstrapCert: Bool
        /// Whether a registered SEP key is present.
        public var hasSEPKey: Bool
        /// The cert's ValidBefore, or nil if no cert.
        public var certValidBefore: Date?
        /// The credential ID (for registeredCredentialID lookup).
        public var credentialID: Data
        /// The user handle (for registeredUserHandle lookup).
        public var userHandle: Data
        /// The device name.
        public var deviceName: String
        /// Whether Host CA checking keys are persisted. Defaults to true so
        /// pre-W4b fixtures (which never captured them) still resolve as
        /// ready; tests can script the legacy state with false.
        public var hasHostCAKeys: Bool

        public init(
            hasBootstrapCert: Bool,
            hasSEPKey: Bool,
            certValidBefore: Date?,
            credentialID: Data,
            userHandle: Data,
            deviceName: String,
            hasHostCAKeys: Bool = true
        ) {
            self.hasBootstrapCert = hasBootstrapCert
            self.hasSEPKey = hasSEPKey
            self.certValidBefore = certValidBefore
            self.credentialID = credentialID
            self.userHandle = userHandle
            self.deviceName = deviceName
            self.hasHostCAKeys = hasHostCAKeys
        }
    }

    /// The per-cluster fixtures, keyed by cluster ID.
    private var fixtures: [UUID: Fixture] = [:]

    @Published public private(set) var credentials: [UUID: TeleportCredential] = [:]

    public init() {}

    /// Seed a cluster with a fixture. The fixture drives all the probe results.
    public func seed(clusterId: UUID, fixture: Fixture) {
        fixtures[clusterId] = fixture
        // Build the TeleportCredential that matches (for the `credentials`
        // property + the registeredCredentialID/registeredUserHandle lookups).
        // When there's no SEP key, leave credentialID/userHandle empty so
        // registeredCredentialID(for:) returns nil (mirroring a real keychain
        // with no registered key).
        let credID: String = fixture.hasSEPKey
            ? fixture.credentialID.base64URLEncodedString()
            : ""
        let userHandle: String = fixture.hasSEPKey
            ? fixture.userHandle.base64URLEncodedString()
            : ""
        var cred = TeleportCredential(
            clusterId: clusterId,
            credentialID: credID,
            userHandle: userHandle,
            publicKeyRaw: "",
            deviceName: fixture.deviceName
        )
        if fixture.hasBootstrapCert {
            cred.sshCertPEM = "mock-bootstrap-cert-pem"
            cred.hasLiveCert = fixture.certValidBefore != nil
            cred.certValidBefore = fixture.certValidBefore ?? .distantPast
        }
        credentials[clusterId] = cred
    }

    // MARK: - TeleportCredentialStore

    public func readiness(for clusterId: UUID) -> TeleportDeviceReadiness {
        // Drive the real resolver (pure function) with the fixture's probes.
        // This means the mock tests the resolver end-to-end, not a parallel
        // implementation.
        let fixture = fixtures[clusterId]
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in fixture?.hasBootstrapCert == true },
            hasSEPKey: { _ in fixture?.hasSEPKey == true },
            certExpiry: { _ in fixture?.certValidBefore },
            hasHostCAKeys: { _ in fixture?.hasHostCAKeys == true }
        )
        return resolver.resolve(clusterId: clusterId)
    }

    public func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) {
        var cred = credentials[clusterId]
            ?? TeleportCredential(clusterId: clusterId, credentialID: "", userHandle: "", publicKeyRaw: "", deviceName: "")
        cred.sshCertPEM = certPEM
        cred.hasLiveCert = true
        cred.certValidBefore = validBefore
        credentials[clusterId] = cred
        // Update the fixture so readiness reflects the new state.
        if var f = fixtures[clusterId] {
            f.hasBootstrapCert = true
            f.certValidBefore = validBefore
            fixtures[clusterId] = f
        }
    }

    public func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    ) {
        var cred = credentials[clusterId]
            ?? TeleportCredential(clusterId: clusterId, credentialID: "", userHandle: "", publicKeyRaw: "", deviceName: "")
        cred.credentialID = credentialID.base64URLEncodedString()
        cred.userHandle = userHandle.base64URLEncodedString()
        cred.publicKeyRaw = publicKeyRaw.base64URLEncodedString()
        cred.deviceName = deviceName
        credentials[clusterId] = cred
        if var f = fixtures[clusterId] {
            f.hasSEPKey = true
            f.credentialID = credentialID
            f.userHandle = userHandle
            f.deviceName = deviceName
            fixtures[clusterId] = f
        }
    }

    public func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) {
        guard var cred = credentials[clusterId] else { return }
        cred.sshCertPEM = certPEM
        cred.hasLiveCert = true
        cred.certValidBefore = validBefore
        credentials[clusterId] = cred
        if var f = fixtures[clusterId] {
            f.hasBootstrapCert = true  // a login cert implies bootstrap happened
            f.certValidBefore = validBefore
            fixtures[clusterId] = f
        }
    }

    public func liveCertPEM(for clusterId: UUID) -> String? {
        guard let cred = credentials[clusterId], cred.isCertValid else { return nil }
        return cred.sshCertPEM
    }

    public func registeredCredentialID(for clusterId: UUID) -> Data? {
        guard let cred = credentials[clusterId],
              !cred.credentialID.isEmpty,
              let data = Data(base64URLEncoded: cred.credentialID) else {
            return nil
        }
        return data
    }

    public func registeredUserHandle(for clusterId: UUID) -> Data? {
        guard let cred = credentials[clusterId],
              !cred.userHandle.isEmpty,
              let data = Data(base64URLEncoded: cred.userHandle) else {
            return nil
        }
        return data
    }

    // MARK: - ed25519 SSH private key (in-memory for the mock)

    /// The per-cluster ed25519 private key (OpenSSH PEM bytes). The real
    /// `TeleportKeyRing` stores this in the keychain; the mock keeps it
    /// in-memory so UI tests don't touch the keychain.
    private var ed25519PrivateKeys: [UUID: Data] = [:]

    /// The per-cluster TLS state (cluster name + CA PEMs). In-memory for the
    /// mock (the real impl persists to UserDefaults).
    private var clusterTLSStates: [UUID: TeleportClusterTLSState] = [:]

    public func liveEd25519PrivateKey(for clusterId: UUID) -> Data? {
        ed25519PrivateKeys[clusterId]
    }

    /// When set, `storeEd25519PrivateKey` throws this instead of storing.
    /// Lets tests script the non-fatal keychain-failure path (the cert +
    /// TLS state must still persist).
    public var storeEd25519PrivateKeyError: Error?

    public func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) throws {
        if let storeEd25519PrivateKeyError {
            throw storeEd25519PrivateKeyError
        }
        ed25519PrivateKeys[clusterId] = pemData
    }

    public func clusterTLSState(for clusterId: UUID) -> TeleportClusterTLSState? {
        clusterTLSStates[clusterId]
    }

    public func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID) {
        clusterTLSStates[clusterId] = state
    }

    public func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) -> TeleportHostKeyUpdateResult {
        guard let state = clusterTLSStates[clusterId] else {
            return .noChange
        }
        let outcome = TeleportHostKeyUpdatePolicy.apply(checkingKeys: checkingKeys, to: state)
        if let updatedState = outcome.updatedState {
            clusterTLSStates[clusterId] = updatedState
        }
        return outcome.result
    }

    public func clear(for clusterId: UUID) {
        credentials.removeValue(forKey: clusterId)
        fixtures.removeValue(forKey: clusterId)
        ed25519PrivateKeys.removeValue(forKey: clusterId)
        clusterTLSStates.removeValue(forKey: clusterId)
    }
}
