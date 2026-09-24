// SPDX-License-Identifier: MIT
//
//  MockTeleportHTTPClient.swift
//  swift-teleport
//
//  A mock `TeleportHTTPClienting` for unit tests. Scripts the Phase-1
//  headless login response (or error) so the bootstrap coordinator can be
//  exercised without a real Teleport server.
//
//  Unlike the UI-test mocks (MockTeleportBootstrapCoordinator), this mocks
//  the *infrastructure* seam — letting the REAL
//  `TeleportBootstrapCoordinator` run its state machine while controlling
//  only the HTTP + Safari layer. This is what proves the coordinator's
//  success path and (via a hosted SwiftUI parent) the view-wiring
//  regression where the coordinator is orphaned by parent body re-evals.
//
//  The mock is fixture-free: it scripts responses through
//  `scriptedHeadlessResponse` / `scriptedHeadlessError` and the login
//  begin/finish equivalents. Fixture-bound payload factories live in the
//  test targets (the host's `#filePath` fixture coupling is gone).
//

import Foundation
import TeleportCore

/// A mock Teleport web-api HTTP client. Returns a scripted
/// `HeadlessLoginResponse` (or throws) on `headlessLogin`.
@MainActor
public final class MockTeleportHTTPClient: TeleportHTTPClienting {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}

    /// The scripted Phase-1 response. `nil` means throw the scripted error.
    public var scriptedHeadlessResponse: HeadlessLoginResponse?

    /// The scripted Phase-1 error. Thrown when
    /// `scriptedHeadlessResponse == nil`.
    public var scriptedHeadlessError: Error?

    /// The scripted Phase-3 `/mfa/login/begin` response.
    public var scriptedLoginBeginResponse: LoginBeginResponse?

    /// The scripted Phase-3 `/mfa/login/finish` response.
    public var scriptedLoginFinishResponse: LoginFinishResponse?

    /// The scripted Phase-3 `/mfa/login/finish` error.
    public var scriptedLoginFinishError: Error?

    /// The number of times `headlessLogin` was called.
    public private(set) var headlessLoginCallCount = 0

    /// The number of times `loginFinish` was called.
    public private(set) var loginFinishCallCount = 0

    /// An optional delay applied before returning the scripted response,
    /// so tests can race the POST against parent body re-evaluations.
    public var scriptedDelay: TimeInterval = 0

    public init() {}

    public func headlessLogin(
        baseURL: URL,
        user: String,
        headlessAuthenticationID: String,
        sshPubKeyB64: String,
        tlsPubKeyB64: String?,
        ttl: Int64
    ) async throws -> HeadlessLoginResponse {
        headlessLoginCallCount += 1
        if scriptedDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(scriptedDelay * 1_000_000_000))
        }
        if let response = scriptedHeadlessResponse {
            return response
        }
        if let error = scriptedHeadlessError {
            throw error
        }
        // Default: a minimal valid success response (cert + tls_cert +
        // host_signers). Tests that want a different outcome should set
        // `scriptedHeadlessResponse` / `scriptedHeadlessError` explicitly.
        return MockTeleportHTTPClient.makeSuccessResponse(clusterName: "teleport.pcad.it")
    }

    // MARK: - Login begin/finish (Phase 3)

    public func loginBegin(baseURL: URL) async throws -> LoginBeginResponse {
        if let response = scriptedLoginBeginResponse {
            return response
        }
        return MockTeleportHTTPClient.makeFixtureLoginBeginResponse()
    }

    public func loginFinish(
        baseURL: URL,
        assertion: CredentialAssertionResponse,
        sshPubKey: Data,
        ttl: Int64
    ) async throws -> LoginFinishResponse {
        loginFinishCallCount += 1
        if let error = scriptedLoginFinishError {
            throw error
        }
        if let response = scriptedLoginFinishResponse {
            return response
        }
        throw GRPCError.transport("MockTeleportHTTPClient.loginFinish not scripted")
    }

    // MARK: - Response factory

    /// Build a minimal success response with base64(PEM) cert + tls_cert.
    public static func makeSuccessResponse(clusterName: String) -> HeadlessLoginResponse {
        let certPEM = "-----BEGIN CERTIFICATE-----\nmock-bootstrap-cert\n-----END CERTIFICATE-----\n"
        let tlsPEM = "-----BEGIN CERTIFICATE-----\nmock-tls-cert\n-----END CERTIFICATE-----\n"
        let certB64 = Data(certPEM.utf8).base64EncodedString()
        let tlsB64 = Data(tlsPEM.utf8).base64EncodedString()
        let hostSigner = HeadlessLoginResponse.TrustedCerts(
            clusterName: clusterName,
            checkingKeys: [],
            tlsCerts: [tlsB64]
        )
        return HeadlessLoginResponse(
            cert: certB64,
            tlsCert: tlsB64,
            hostSigners: [hostSigner]
        )
    }

    /// A `login/begin` response carrying a challenge and no explicit rpID
    /// (falls back to the cluster's configured rpID / host).
    public static func makeFixtureLoginBeginResponse() -> LoginBeginResponse {
        LoginBeginResponse(
            webauthnChallenge: LoginBeginResponse.WebauthnAssertion(
                publicKey: LoginBeginResponse.WebauthnAssertion.PublicKey(
                    challenge: Data([1, 2, 3, 4]).base64URLEncodedString(),
                    rpId: nil
                )
            )
        )
    }
}
