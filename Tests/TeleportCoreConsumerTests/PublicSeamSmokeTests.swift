// SPDX-License-Identifier: MIT
//
//  PublicSeamSmokeTests.swift
//  TeleportCoreConsumerTests
//
//  A NON-`@testable` consumer smoke test: it imports `TeleportCore` exactly as
//  a downstream package would and exercises the public seam. If the seam stops
//  being usable from outside the module — an access-level regression, a type
//  that is public only in name, or a missing isolation annotation — this
//  target fails to compile.
//
//  This target deliberately has no `@MainActor` annotations: it relies on the
//  target's `.defaultIsolation(MainActor.self)` to reach the package's
//  MainActor-isolated seam, which also proves the setting is applied here.
//

import Foundation
import Testing
import TeleportCore

struct PublicSeamSmokeTests {

    @Test
    func proxySubsystemRequestBuildsLocalAndLeafRoutes() {
        #expect(TeleportProxySubsystem.request(for: "node-1") == "proxy:node-1:0")
        #expect(TeleportProxySubsystem.request(for: "node-1", port: 22) == "proxy:node-1:22")
        #expect(
            TeleportProxySubsystem.request(for: "node-1", port: 0, cluster: "leaf")
                == "proxy:node-1:0@leaf"
        )
        // An empty cluster means "the local cluster" — no `@` suffix.
        #expect(TeleportProxySubsystem.request(for: "node-1", port: 0, cluster: "") == "proxy:node-1:0")
    }

    @Test
    func transportExposesALPNContract() {
        #expect(SSHTLSTransport.alpnProtocol == "teleport-proxy-ssh")
        #expect(SSHTLSTransport.offeredALPNProtocols == [SSHTLSTransport.alpnProtocol])
    }

    @Test
    func defaultLoggingIsUsableFromOutsideTheModule() {
        let logging = DefaultTeleportLogging(subsystem: "com.example.consumer")
        _ = logging.logger(category: "consumer-test")
        #expect(logging.subsystem == "com.example.consumer")
    }

    @Test
    func packageErrorDescriptionsAreStable() {
        #expect(
            TeleportPackageError.connectionFailed("boom").errorDescription
                == "Connection failed: boom"
        )
        #expect(TeleportPackageError.keychain(-25300).errorDescription == "Keychain error: -25300")
    }

    @Test
    func clusterTLSStateIsConstructibleAndHashable() {
        let state = TeleportClusterTLSState(
            clusterName: "teleport.example.com",
            clusterCAPEMs: ["-----BEGIN CERTIFICATE-----"],
            hostCACheckingKeys: ["ssh-ed25519 AAAA"]
        )
        let same = TeleportClusterTLSState(
            clusterName: "teleport.example.com",
            clusterCAPEMs: ["-----BEGIN CERTIFICATE-----"],
            hostCACheckingKeys: ["ssh-ed25519 AAAA"]
        )
        #expect(state == same)
        #expect(state.clusterName == "teleport.example.com")
        #expect(state.clusterCAPEMs.count == 1)
        #expect(state.hostCACheckingKeys.count == 1)
    }

    @Test
    func hostKeyUpdateResultCasesArePublic() {
        let results: [TeleportHostKeyUpdateResult] = [
            .updated, .rejectedWouldDropPinnedKeys, .noChange,
        ]
        #expect(results.count == 3)
    }

    @Test
    func tlsTrustHelpersArePublic() throws {
        #expect(TeleportTLSTrust.clusterLocalName == "teleport.cluster.local")
        #expect(TeleportTLSTrust.sshServerNames(dialHost: "h") == ["h", "teleport.cluster.local"])
        #expect(
            TeleportTLSTrust.authServerNames(clusterName: "ci")
                == [TeleportTLSTrust.encodedClusterName("ci"), "teleport.cluster.local"]
        )
        #expect(TeleportTLSTrust.anchors(fromPEMs: []).isEmpty)
    }
}
