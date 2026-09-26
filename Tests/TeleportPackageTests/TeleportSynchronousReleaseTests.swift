// SPDX-License-Identifier: MIT
//
//  TeleportSynchronousReleaseTests.swift
//  TeleportPackageTests
//
//  Regression for the isolated-deinit abort (issue #216): with
//  `.defaultIsolation(MainActor.self)` an unannotated class is
//  MainActor-isolated and its compiler-synthesized deinit takes the
//  back-deployed isolated-deinit path, which traps in
//  `TaskLocal::StopLookupScope` when the class is released outside a task
//  context (a synchronous XCTest method) — swiftlang/swift#85663, #88036.
//
//  The failure mode is an `Early unexpected exit` / signal trap in the test
//  host, not an assertion. This test is deliberately a **synchronous**
//  method: passing at all is the assertion.
//
//  Coverage is scoped to the classes that are constructible from a
//  synchronous test. `TeleportGRPCConnection` has a private init and
//  `GRPCUnaryHandler` needs an `EventLoopPromise`; their markers are pure
//  no-ops checked only by the build.
//

import Foundation
import Security
import os.log
import XCTest
@testable import TeleportCore
@testable import TeleportAuth
import TeleportTesting

/// Minimal gRPC stub so the registration coordinator can be constructed.
@MainActor
private final class ReleaseTestGRPCClient: TeleportGRPCClienting {
    nonisolated deinit {}
    func connect(
        host: String,
        clientCertPEM: String,
        privateKey: SecKey,
        clusterName: String,
        clusterCAPEMs: [String]
    ) async throws {}

    func createAuthenticateChallenge(
        browserMFATSHRedirectURL: String
    ) async throws -> Proto_MFAAuthenticateChallenge {
        Proto_MFAAuthenticateChallenge()
    }

    func createRegisterChallenge(
        existingMFAResponse: Proto_MFAAuthenticateResponse?
    ) async throws -> Proto_MFARegisterChallenge {
        Proto_MFARegisterChallenge()
    }

    func addMFADeviceSync(
        deviceName: String,
        newMFAResponse: Proto_MFARegisterResponse
    ) async throws {}

    func disconnect() async {}
}

/// Minimal `BrowserMFACeremonyRunning` stub so the registration coordinator
/// can be constructed without the host-only live adapter.
@MainActor
private final class ReleaseTestCeremony: BrowserMFACeremonyRunning {
    nonisolated deinit {}
    func run(
        grpcClient: any TeleportGRPCClienting,
        host: String
    ) async throws -> Proto_BrowserMFAResponse {
        Proto_BrowserMFAResponse()
    }
}

nonisolated final class TeleportSynchronousReleaseTests: XCTestCase {

    @MainActor
    private func makeTestKeyRing() -> TeleportKeyRing {
        let defaults = UserDefaults(suiteName: "TeleportSynchronousReleaseTests") ?? .standard
        return TeleportKeyRing(
            signer: MockSEPKeySigner(outcome: .success),
            logging: DefaultTeleportLogging(),
            config: TeleportKeychainConfig(
                keychainService: "vvterm.tests",
                defaults: defaults
            )
        )
    }

    /// Constructs and releases the coordinator graph synchronously.
    @MainActor
    func testCoordinatorGraphReleasesSynchronouslyWithoutTrapping() {
        let logging = DefaultTeleportLogging()

        autoreleasepool {
            let keyRing = makeTestKeyRing()
            let mockKeyRing = MockTeleportKeyRing()
            let http = MockTeleportHTTPClient()
            let signer = MockSEPKeySigner(outcome: .success)
            let safari = MockWebAuthenticationSessionPresenter()
            let presenter = RecordingBrowserMFAPresenter()
            let ceremony = BrowserMFACeremony(logging: logging, presenter: presenter)

            let bootstrap = TeleportBootstrapCoordinator(
                httpClient: http,
                keyRing: mockKeyRing,
                safariPresenter: safari,
                logging: logging,
                signer: signer,
                sshKeyPairGenerator: LiveTeleportSSHKeyPairGenerator(),
                tlsKeyPairGenerator: LiveTeleportTLSKeyPairGenerator()
            )
            let login = TeleportLoginCoordinator(
                httpClient: http,
                keyRing: mockKeyRing,
                logging: logging,
                signer: signer,
                webAuthnBuilder: TeleportWebAuthnBuilder(),
                keyPairGenerator: LiveTeleportSSHKeyPairGenerator()
            )
            let registration = TeleportRegistrationCoordinator(
                grpcClient: ReleaseTestGRPCClient(),
                browserMFACeremony: ReleaseTestCeremony(),
                keyRing: mockKeyRing,
                logging: logging,
                signer: signer,
                webAuthnBuilder: TeleportWebAuthnBuilder()
            )

            _ = (keyRing, bootstrap, login, registration, ceremony)
        }

        // The live generators, the SEP signer, and the single-owner guard.
        autoreleasepool {
            let sshGenerator = LiveTeleportSSHKeyPairGenerator()
            let tlsGenerator = LiveTeleportTLSKeyPairGenerator()
            let sepSigner = SecureEnclaveSigner()
            let softwareSigner = SoftwareSigner()
            let pumpCloser = PumpFDCloser()
            _ = (sshGenerator, tlsGenerator, sepSigner, softwareSigner, pumpCloser)
        }
    }
}
