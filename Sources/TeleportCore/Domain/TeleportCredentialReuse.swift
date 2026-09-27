// SPDX-License-Identifier: MIT
//
//  TeleportCredentialReuse.swift
//  swift-teleport
//
//  The pure matcher that lets a duplicate server row reuse an existing
//  device registration.
//
//  Ported from `cad0p/vvterm` at `30ac5388` (#262). The host matcher took
//  `newServer: Server` / `liveServers: [Server]`; the package carries no host
//  types, so the row shape is generalized to `TeleportCredentialReuseRow` and
//  the host's `Server` conforms to it in Phase 2. The matching semantics are
//  unchanged.
//
//  A Teleport SEP key belongs to a (cluster, Teleport user) — not to a node.
//  Registering a second row for the same cluster + user does not need a second
//  MFA device registration (and the cluster's device-name collision makes one
//  awkward): the row can seed the registration metadata (credentialID,
//  userHandle, publicKeyRaw, deviceName + cluster TLS state) from a complete
//  live setup and go straight to Face ID login + the host-login picker.
//
//  The keyring is keyed by server UUID only and cannot match on host/user, so
//  the matcher takes the live row list plus the credential map. The
//  completeness precondition is injected as `isReusable` so this type stays
//  pure and unit-testable.
//
//  Match key: the candidate must be a different Face-ID-Teleport row with the
//  same `host` and `username` (the Teleport user) as the new row, and a
//  complete live registration. When the new row already knows its cluster name
//  (a re-setup of an existing row) the cluster names must also be equal — a
//  proxy host can front several clusters. A brand-new row has no cluster name
//  yet, so host+user is its only discriminator (recorded: two proxies on one
//  host with different ports collide — deliberate).
//

import Foundation

/// The row shape the reuse matcher needs. The host's `Server` conforms to it
/// in Phase 2 (`displayName` is the row's `name`, `isFaceIDTeleport` is
/// `authMethod == .faceIDTeleport`).
public protocol TeleportCredentialReuseRow {
    var id: UUID { get }
    /// The row's display name (used only for the deterministic name ordering).
    var displayName: String { get }
    var host: String { get }
    /// The Teleport user (`Server.username`).
    var username: String { get }
    /// Whether the row authenticates with a Teleport Face ID credential.
    var isFaceIDTeleport: Bool { get }
}

public enum TeleportCredentialReuse {

    /// The completeness precondition for a candidate row's registration:
    /// a credential record with a non-empty `credentialID`, the SEP key still
    /// present, and a cluster TLS state with non-empty Host CA checking keys.
    public typealias IsReusable = (UUID) -> Bool

    /// The first reusable live source row for `newRow`, or nil.
    ///
    /// - Parameters:
    ///   - newRow: the row being set up.
    ///   - liveRows: the live server list.
    ///   - credentials: the keyring's credential map.
    ///   - clusterName: the cluster name persisted in the keyring's TLS state
    ///     for a row, or nil when the row has none yet.
    ///   - isReusable: the completeness precondition (see `IsReusable`).
    public static func match<Row: TeleportCredentialReuseRow>(
        newRow: Row,
        liveRows: [Row],
        credentials: [UUID: TeleportCredential],
        clusterName: (UUID) -> String?,
        isReusable: IsReusable
    ) -> Row? {
        guard newRow.isFaceIDTeleport else { return nil }
        let newClusterName = clusterName(newRow.id)

        return liveRows
            .filter { candidate in
                guard candidate.id != newRow.id else { return false }
                guard candidate.isFaceIDTeleport else { return false }
                guard candidate.host == newRow.host, candidate.username == newRow.username else {
                    return false
                }
                guard credentials[candidate.id] != nil else { return false }
                return isReusable(candidate.id)
            }
            .filter { candidate in
                // A brand-new row has no cluster name yet; when it does, the
                // candidate must belong to the same cluster.
                guard let newClusterName, !newClusterName.isEmpty else { return true }
                guard let candidateClusterName = clusterName(candidate.id) else { return false }
                return candidateClusterName == newClusterName
            }
            .sorted { $0.displayName < $1.displayName }
            .first
    }
}
