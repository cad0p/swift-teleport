// SPDX-License-Identifier: MIT
//
//  TeleportHostLogin.swift
//  swift-teleport
//
//  The pure resolver for the Teleport SSH username.
//
//  Ported from `cad0p/vvterm` at `30ac5388` (#262, "send the certificate's
//  host login as the SSH username"). The host's resolver read its normalizer
//  from `Server.normalizedTeleportHostLogin`; the package carries no host
//  types, so the shape rule moved in as `TeleportHostLogin.normalized(_:)`
//  and the host's `Server` delegates to it in Phase 2.
//
//  A Teleport SSH connection authenticates as the Teleport *user* (`pier`),
//  but the username libssh2 sends must be a **certificate principal** — the
//  host login (`deploy`). Teleport's `CertChecker.CheckCert` (x/crypto) runs
//  on the proxy and the node alike and rejects a username that is not one of
//  the certificate's `ValidPrincipals`, no matter how valid the certificate
//  itself is.
//
//  The resolution order is deliberately fail-closed:
//
//    1. The stored host login, if it is still a principal of the certificate
//       being sent (a role change may have dropped it).
//    2. Otherwise, only when the certificate carries **exactly one**
//       non-internal principal, that principal (the legacy/no-picker path).
//    3. Zero principals or an ambiguous set fails closed — the connect path
//       never guesses among logins, and never sends a non-principal.
//
//  Internal principals (`-teleport-internal-join` and any other `-…` name)
//  are filtered before both the stored-match and the fallback, mirroring
//  `tsh status`'s `Logins:` list. Principal order is the certificate's wire
//  order.
//

import Foundation

/// Why the SSH username could not be resolved from the certificate.
public enum TeleportHostLoginFailure: Error, Equatable, LocalizedError, CustomStringConvertible {
    /// The stored certificate could not be parsed as an OpenSSH certificate.
    case certificateUnreadable
    /// The certificate carries no non-internal principal.
    case noPrincipals
    /// The certificate carries several non-internal principals and no stored
    /// login matches one of them — the client must not guess.
    case ambiguousPrincipalSet([String])

    /// A stable, non-rendering case name for logs and diagnostics. The
    /// associated principal list is deliberately omitted so it can never
    /// reach the shareable diagnostics report through `String(describing:)`.
    public var caseDescription: String {
        switch self {
        case .certificateUnreadable: return "certificateUnreadable"
        case .noPrincipals: return "noPrincipals"
        case .ambiguousPrincipalSet: return "ambiguousPrincipalSet"
        }
    }

    /// `String(describing:)` (logs, diagnostics) renders the case name only;
    /// the user-facing message stays in `errorDescription`.
    public var description: String { caseDescription }

    public var errorDescription: String? {
        switch self {
        case .certificateUnreadable:
            return "The Teleport certificate could not be read. Sign in with Face ID to refresh it."
        case .noPrincipals:
            return "The Teleport certificate carries no login for this host. Ask an administrator to grant a login for this host on the Teleport role, then sign in again."
        case .ambiguousPrincipalSet(let logins):
            return "The Teleport certificate carries several logins (\(logins.joined(separator: ", "))). Re-run Teleport setup and pick the host login to use."
        }
    }
}

public enum TeleportHostLogin {

    /// The maximum UTF-8 byte length accepted for a stored host login.
    package static let maxTeleportHostLoginBytes = 255

    /// Shape-validates a stored host login for the persist/decode seam.
    ///
    /// Persist/decode can only check the shape — the authoritative check is
    /// the connect-time principal match against the certificate being sent,
    /// which a decode cannot perform. Returns `nil` for a value that is empty
    /// (or whitespace-only), longer than 255 UTF-8 bytes, or contains a
    /// control character. `@` is explicitly allowed (Teleport logins may
    /// contain it).
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= maxTeleportHostLoginBytes else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    /// Resolve the SSH username for a Teleport connection from the certificate
    /// PEM that is being sent and the stored preference.
    package static func resolveUsername(
        certPEM: String,
        storedLogin: String?
    ) -> Result<String, TeleportHostLoginFailure> {
        guard let cert = OpenSSHCertificate.parse(authorizedKeysOrPEM: certPEM) else {
            return .failure(.certificateUnreadable)
        }
        return resolve(cert: cert, storedLogin: storedLogin)
    }

    /// The parsed-certificate form of `resolveUsername` (used at the connect
    /// sites, which already had to parse the certificate for the keyID
    /// binding check).
    public static func resolve(
        cert: OpenSSHCertificate,
        storedLogin: String?
    ) -> Result<String, TeleportHostLoginFailure> {
        let logins = nonInternalPrincipals(of: cert)

        if let stored = normalized(storedLogin), logins.contains(stored) {
            return .success(stored)
        }

        switch logins.count {
        case 1:
            return .success(logins[0])
        case 0:
            return .failure(.noPrincipals)
        default:
            return .failure(.ambiguousPrincipalSet(logins))
        }
    }

    /// The certificate's non-internal principals in wire order (tsh `Logins:`
    /// parity). Internal Teleport principals are prefixed with `-`.
    package static func nonInternalPrincipals(of cert: OpenSSHCertificate) -> [String] {
        cert.validPrincipals.filter { !$0.isEmpty && !$0.hasPrefix("-") }
    }

    /// The host login the setup Phase-3 step starts with (the pure selection
    /// policy, kept out of the view).
    ///
    /// - A stored login that is still a principal of the fresh certificate is
    ///   the frozen per-row choice; the step renders it read-only.
    /// - A single non-internal principal is auto-selected but still shown.
    /// - Several non-internal principals with no stored login start with
    ///   **no selection**: the user must tap one explicitly, so Continue can
    ///   never freeze whichever login the CA happened to list first.
    public static func initialSelection(logins: [String], stored: String?) -> String? {
        if let stored = normalized(stored), logins.contains(stored) {
            return stored
        }
        return logins.count == 1 ? logins[0] : nil
    }
}
