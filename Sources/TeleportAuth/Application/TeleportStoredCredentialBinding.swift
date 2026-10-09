// SPDX-License-Identifier: MIT
//
//  TeleportStoredCredentialBinding.swift
//  VVTerm
//
//  One owner for the Teleport-user binding rule and the stored-credential
//  load shared by the bootstrap and login coordinators.
//

import Foundation
import TeleportCore

/// The binding rule both coordinators apply twice: to the freshly issued
/// cert (main path) and to the stored cert after a pair-write failure (D4).
///
/// Keep the rule here: a future binding change (e.g. also checking the cert's
/// principals) lands once and cannot drift between the main path and the D4
/// path, which is exactly the duplication class this type removes.
enum TeleportStoredCredentialBinding {
    enum Outcome {
        /// A stored cert whose `keyID` is the configured Teleport user. The
        /// `certPEM` is the exact PEM the cert was parsed from (the bootstrap
        /// hand-off reuses it verbatim).
        case bound(cert: OpenSSHCertificate, certPEM: String)
        /// No live credential pair, or its cert does not parse.
        case unavailable
        /// A stored cert for a different user. The caller clears and fails
        /// closed; this classification does not clear on its own — the
        /// bootstrap caller re-takes its request generation before and after
        /// the clear.
        case foreignUser
    }

    /// The binding predicate: the cert's `keyID` is the Teleport identity and
    /// must equal the configured username.
    static func isBound(cert: OpenSSHCertificate, username: String) -> Bool {
        cert.keyID == username
    }

    /// Classify a live credential snapshot's cert against the configured
    /// username. Synchronous by design: each caller awaits
    /// `liveCredentialSnapshot` itself and keeps its own continuation guards
    /// around that read (the bootstrap coordinator's generation re-takes; the
    /// login coordinator has none yet — follow-up #48).
    static func readBoundCert(
        snapshot: (certPEM: String, privateKeyPEM: Data)?,
        username: String
    ) -> Outcome {
        guard let snapshot,
              let storedCert = OpenSSHCertificate.parse(authorizedKeysOrPEM: snapshot.certPEM) else {
            return .unavailable
        }
        return isBound(cert: storedCert, username: username)
            ? .bound(cert: storedCert, certPEM: snapshot.certPEM)
            : .foreignUser
    }
}
