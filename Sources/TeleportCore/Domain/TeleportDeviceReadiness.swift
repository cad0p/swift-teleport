import Foundation

/// The derived readiness state for a Teleport cluster on this device.
/// Computed locally from keychain presence — NO network call, NO stored state.
/// Per the parent decision's "derived readiness state" section, refined to 4 states
/// (splits needsRegistration from needsBootstrap).
///
/// See: 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup B)
public enum TeleportDeviceReadiness: Equatable {
    /// No Phase-1 cert in keychain. New device via iCloud, or never bootstrapped.
    case needsBootstrap
    /// Phase-1 cert present, but no SEP key registered for this cluster.
    /// The device-name pause between the two Safari trips is a natural resume point.
    case needsRegistration
    /// SEP key present, but cert missing or expired (now >= cert.ValidBefore).
    /// Re-auth is native Face ID — no Safari.
    case needsLogin
    /// Live cert, not expired. Connect immediately.
    case ready

    /// Whether setup is required (any non-ready state).
    public var needsSetup: Bool {
        switch self {
        case .ready: return false
        case .needsBootstrap, .needsRegistration, .needsLogin: return true
        }
    }

    /// Whether the Safari bootstrap flow is needed (vs. just native Face ID).
    public var needsSafari: Bool {
        switch self {
        case .ready, .needsLogin: return false
        case .needsBootstrap, .needsRegistration: return true
        }
    }
}

/// Pure function to compute readiness from keychain state.
/// The keychain queries are injected so this is unit-testable without a real keychain.
package struct TeleportDeviceReadinessResolver {
    /// Returns true if a Phase-1 bootstrap cert exists for this cluster.
    package typealias HasBootstrapCert = (UUID) -> Bool
    /// Returns true if a SEP key is registered for this cluster.
    package typealias HasSEPKey = (UUID) -> Bool
    /// Returns the live cert's ValidBefore, or nil if no cert.
    package typealias CertExpiry = (UUID) -> Date?
    /// Returns true if Host CA checking keys are persisted for this cluster.
    /// Missing keys fail closed in two cases: a device with a cert routes to
    /// `.needsLogin` (the login response refreshes them), and a device
    /// without routes to `.needsBootstrap`. Legacy installs never capture
    /// checking keys until their next login.
    package typealias HasHostCAKeys = (UUID) -> Bool

    package let hasBootstrapCert: HasBootstrapCert
    package let hasSEPKey: HasSEPKey
    package let certExpiry: CertExpiry
    package let hasHostCAKeys: HasHostCAKeys

    package init(
        hasBootstrapCert: @escaping HasBootstrapCert,
        hasSEPKey: @escaping HasSEPKey,
        certExpiry: @escaping CertExpiry,
        hasHostCAKeys: @escaping HasHostCAKeys = { _ in false }
    ) {
        self.hasBootstrapCert = hasBootstrapCert
        self.hasSEPKey = hasSEPKey
        self.certExpiry = certExpiry
        self.hasHostCAKeys = hasHostCAKeys
    }

    package func resolve(clusterId: UUID, now: Date = Date()) -> TeleportDeviceReadiness {
        let hasCert = hasBootstrapCert(clusterId)

        // No registered SEP key: a cert (Phase 1) means registration is the
        // next step; nothing at all means bootstrap.
        guard hasSEPKey(clusterId) else {
            return hasCert ? .needsRegistration : .needsBootstrap
        }

        // A registered device without Host CA checking keys is a legacy
        // install (the login response refreshes the pinned keys) — or a device
        // state the caller cannot prove complete. Fail closed: without pinned
        // anchors the SSH path cannot verify the proxy at all.
        guard hasHostCAKeys(clusterId) else {
            return hasCert ? .needsLogin : .needsBootstrap
        }

        // A key + pinned anchors with no (valid) cert is the reuse state: the
        // registration is complete, only Face ID login + the picker remain.
        guard hasCert, let expiry = certExpiry(clusterId), expiry > now else {
            return .needsLogin
        }
        return .ready
    }
}
