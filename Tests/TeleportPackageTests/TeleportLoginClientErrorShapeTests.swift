// SPDX-License-Identifier: MIT
//
//  TeleportLoginClientErrorShapeTests.swift
//  swift-teleport
//
//  Issue #40: a non-200 `login/begin` / `login/finish` must surface as a
//  structured `HeadlessError.http(status:body:)` — never as a free-form
//  `GRPCError.http2("<op> HTTP <status>: <body>")` string, which loses the
//  status in the log (`wireFailure` renders the bare case `http2`) and routes
//  the UI to `.unknown` instead of `.server` with the server's message.
//
//  Why the loopback section is the discriminating evidence: the
//  mock-scripted redaction tests script `HeadlessError.http` *into* the mock
//  — the shape production should throw — so they stayed green while the real
//  client packed both fields into one string. That is exactly how the defect
//  survived. The `…RealTwinClient…` tests below drive the real
//  `TeleportHTTPClient` over the in-process `LoopbackHTTPServer` from
//  `HeadlessLoginWireTests`, so a reintroduced `GRPCError.http2` packing
//  reddens them.
//
//  The coordinator-driven end-to-end variant is infeasible and not
//  attempted: `TeleportLoginCoordinator.begin` hardcodes
//  `URL(string: "https://\(cluster.host)")`, so the plain-HTTP loopback
//  harness cannot be reached through it. The chain is bracketed by
//  (1) these real-client tests — the client throws the structured type,
//  (2) the `…Coordinator…` tests below — the structured type maps to
//  `.failed(.server("HTTP <status>: <body>"))` / `.failed(.unknown(…))`,
//  and (3) `TeleportRedactionTests` — the coordinator's catch renders the
//  status without the body.
//

import Foundation
import XCTest
@testable import TeleportCore
@testable import TeleportAuth
import TeleportTesting

#if canImport(Network)

nonisolated final class TeleportLoginClientErrorShapeTests: XCTestCase {

    // MARK: - Fixtures

    @MainActor
    private func loopbackURL(_ server: LoopbackHTTPServer) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)")!
    }

    /// A publicly constructible WebAuthn assertion — the only input the
    /// client needs for the `login/finish` POST body.
    @MainActor
    private func makeAssertion() -> CredentialAssertionResponse {
        CredentialAssertionResponse(
            id: "aWQ",
            type: "public-key",
            rawId: "cmF3",
            response: AuthenticatorAssertionResponse(
                clientDataJSON: "Y2Rq",
                authenticatorData: "YWRhdGE",
                signature: "c2ln",
                userHandle: nil
            )
        )
    }

    @MainActor
    private func makeServer(status: Int, body: Data) throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer(
            response: LoopbackHTTPServer.Response(statusCode: status, body: body)
        )
    }

    // MARK: - Real client over the loopback harness (discriminating)

    /// The package's concrete client (`TeleportHTTPClient`) must throw the
    /// structured error, keeping the status and the body separate.
    @MainActor
    func testRealTwinClientLoginBegin403_throwsStructuredHTTPFailure() async throws {
        let marker = "twin-login-begin-server-body-marker"
        let server = try makeServer(status: 403, body: Data(marker.utf8))
        defer { server.stop() }

        do {
            _ = try await TeleportHTTPClient(baseURL: loopbackURL(server)).loginBegin()
            XCTFail("a non-200 login/begin must throw")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                XCTFail("expected HeadlessError.http, got \(error)")
                return
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(body, marker, "the server body must survive in the structured error")

            // The exact log payload the coordinator renders from this thrown
            // error (`TeleportErrorRedaction.wireFailure`): status present,
            // body absent. This is the loopback 403 → log-line check.
            XCTAssertEqual(TeleportErrorRedaction.wireFailure(error), "HTTP 403")
            XCTAssertFalse(
                TeleportErrorRedaction.wireFailure(error).contains(marker),
                "the server body must not reach a log payload"
            )
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// The client's `login/finish` site.
    @MainActor
    func testRealTwinClientLoginFinish500_throwsStructuredHTTPFailure() async throws {
        let marker = "twin-login-finish-server-body-marker"
        let server = try makeServer(status: 500, body: Data(marker.utf8))
        defer { server.stop() }

        do {
            _ = try await TeleportHTTPClient(baseURL: loopbackURL(server)).loginFinish(
                assertion: makeAssertion(),
                sshPubKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey ci",
                ttl: 3_600_000_000_000
            )
            XCTFail("a non-200 login/finish must throw")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                XCTFail("expected HeadlessError.http, got \(error)")
                return
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, marker, "the server body must survive in the structured error")
            XCTAssertEqual(TeleportErrorRedaction.wireFailure(error), "HTTP 500")
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// A non-UTF-8 body must not crash or leak raw bytes: it becomes the
    /// `<binary>` marker the shared `HeadlessLogin.post` path also uses.
    @MainActor
    func testRealTwinClientLoginBegin403WithNonUTF8Body_reportsBinaryBody() async throws {
        let server = try makeServer(status: 403, body: Data([0xFF, 0xFE, 0xFD]))
        defer { server.stop() }

        do {
            _ = try await TeleportHTTPClient(baseURL: loopbackURL(server)).loginBegin()
            XCTFail("a non-200 login/begin must throw")
        } catch let error as HeadlessError {
            guard case .http(let status, let body) = error else {
                XCTFail("expected HeadlessError.http, got \(error)")
                return
            }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(body, "<binary>")
        } catch {
            XCTFail("expected HeadlessError.http, got \(type(of: error)): \(error)")
        }
    }

    /// S3: the 200-with-empty-cert decode failure is body-free — it must not
    /// embed a server-supplied body snippet.
    @MainActor
    func testRealTwinClientLoginFinish200EmptyCert_throwsBodyFreeDecodeError() async throws {
        let marker = "no-cert-body-marker"
        let body = Data(#"{"cert":"","marker":"\#(marker)"}"#.utf8)
        let server = try makeServer(status: 200, body: body)
        defer { server.stop() }

        do {
            _ = try await TeleportHTTPClient(baseURL: loopbackURL(server)).loginFinish(
                assertion: makeAssertion(),
                sshPubKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey ci",
                ttl: 3_600_000_000_000
            )
            XCTFail("a 200 with an empty cert must throw")
        } catch let error as HeadlessError {
            guard case .decode(let message) = error else {
                XCTFail("expected HeadlessError.decode, got \(error)")
                return
            }
            XCTAssertEqual(message, "login/finish: no cert")
            XCTAssertFalse(
                message.contains(marker),
                "the decode message must not embed the response body: \(message)"
            )
        } catch {
            XCTFail("expected HeadlessError.decode, got \(type(of: error)): \(error)")
        }
    }

    /// A 200 with a non-JSON body keeps the decode branch (`.decode`), not
    /// the status branch: the fix must not repack a decode failure as an
    /// HTTP-status failure.
    @MainActor
    func testRealTwinClientLoginBegin200NonJSON_throwsGRPCErrorDecode() async throws {
        let server = try makeServer(status: 200, body: Data("not json".utf8))
        defer { server.stop() }

        do {
            _ = try await TeleportHTTPClient(baseURL: loopbackURL(server)).loginBegin()
            XCTFail("a non-JSON login/begin response must throw")
        } catch let error as GRPCError {
            guard case .decode(let message) = error else {
                XCTFail("expected GRPCError.decode, got \(error)")
                return
            }
            XCTAssertEqual(message, "login/begin response")
        } catch {
            XCTFail("expected GRPCError.decode, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - State mapping through the coordinator's public surface
    //
    // `mapHTTPError` is private, so these drive `begin(cluster:)` and read
    // `state`. They are contract tests: they script the structured error the
    // real client now throws and pin the mapping the UI relies on
    // ("Teleport Server Error" + the server's message verbatim). The loopback
    // section above is the discriminating evidence.

    @MainActor
    func testCoordinatorLoginBeginHTTPFailure_mapsToServerStateWithTheVerbatimBody() async throws {
        let marker = "login-begin-mapping-marker"
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginBeginError = HeadlessError.http(status: 403, body: marker)

        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            webAuthnBuilder: ScriptedWebAuthnBuilderStub(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.server("HTTP 403: \(marker)")))
    }

    @MainActor
    func testCoordinatorLoginFinishHTTPFailure_mapsToServerStateWithTheVerbatimBody() async throws {
        let marker = "login-finish-mapping-marker"
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginFinishError = HeadlessError.http(status: 500, body: marker)

        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            webAuthnBuilder: ScriptedWebAuthnBuilderStub(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.server("HTTP 500: \(marker)")))
    }

    /// S3's state/log delta: the body-free decode failure maps to `.unknown`
    /// (rendering the decode message under the generic title) and its log
    /// payload is the body-free `decode: …` text — never a server body.
    @MainActor
    func testCoordinatorLoginFinishDecodeFailure_mapsToUnknownWithoutTheBody() async throws {
        let decodeError = HeadlessError.decode("login/finish: no cert")
        let cluster = TeleportCluster(host: "teleport.pcad.it", username: "pier")
        let credentialID = Data([1, 2, 3, 4])
        let keyRing = Self.makeRegisteredKeyRing(clusterId: cluster.id, credentialID: credentialID)
        let signer = MockSEPKeySigner(outcome: .success)
        _ = try signer.createKey(credentialID: credentialID)
        let http = MockTeleportHTTPClient()
        http.scriptedLoginFinishError = decodeError

        let coordinator = TeleportLoginCoordinator(
            httpClient: http,
            keyRing: keyRing,
            logging: DefaultTeleportLogging(),
            signer: signer,
            webAuthnBuilder: ScriptedWebAuthnBuilderStub(),
            keyPairGenerator: TeleportFixtureSupport.makeFixedSSHGenerator(),
            now: { TeleportFixtureSupport.fixtureClock }
        )
        await coordinator.begin(cluster: cluster)

        XCTAssertEqual(coordinator.state, .failed(.unknown("decode: login/finish: no cert")))
        XCTAssertEqual(
            TeleportErrorRedaction.wireFailure(decodeError),
            "decode: login/finish: no cert",
            "the decode message must render body-free in the failure log"
        )
    }

    // MARK: - Tripwire

    /// A tripwire, not a proof: the literal `GRPCError.http2("` must not
    /// reappear anywhere in `Sources/` or the host-surface fixture. The quote
    /// anchor admits `GRPCClient.swift`'s variable-arg construction (where
    /// `.http2` is the right case for a genuine HTTP/2-layer failure) and
    /// catches a reintroduced literal status+body packing.
    ///
    /// Known defeats (why this is a tripwire): an aliased factory
    /// (`let m = …; throw GRPCError.http2(m)`), a multi-line call (the quote
    /// lands on the next line), a `typealias`, whitespace spellings
    /// (`GRPCError.http2 ("…")`, `GRPCError . http2("…")`), and exotic
    /// spellings such as an extra parenthesis (`GRPCError.http2(("…")`). The
    /// behavioural tests above are the primary evidence; this scan catches
    /// the direct regression.
    ///
    /// Known false positives — the scan fails closed, so they only add reds
    /// and can never hide a packing: a trailing `//` comment quoting the
    /// spelling, an inline `/* … */` block, or a string literal containing
    /// the needle. Comment lines are skipped (a doc comment quoting the old
    /// spelling must not satisfy the tripwire) and the coverage guards assert
    /// the roots really contained the two known fix sites, so a wrong path
    /// derivation fails loudly instead of passing vacuously.
    @MainActor
    func testNoLiteralGRPCErrorHTTP2PackingRemainsInSources() throws {
        let needle = "GRPCError.http2(\""
        let roots = [
            Self.repositoryRoot().appendingPathComponent("Sources"),
            Self.repositoryRoot().appendingPathComponent("Fixtures/HostSurfaceCheck/Sources"),
        ]
        let files = roots.flatMap { Self.swiftFiles(under: $0) }
        XCTAssertTrue(
            files.contains { $0.lastPathComponent == "TeleportHTTPClient.swift" },
            "the tripwire scan must cover Sources/TeleportAuth/Infrastructure/TeleportHTTPClient.swift"
        )
        XCTAssertTrue(
            files.contains { $0.lastPathComponent == "HostSurfaceMirrors.swift" },
            "the tripwire scan must cover Fixtures/HostSurfaceCheck/Sources/…/HostSurfaceMirrors.swift"
        )

        var offenders: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // `//`, `///`, `/*`, and `*` all start a comment line.
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    continue
                }
                if line.contains(needle) {
                    offenders.insert(file.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(
            offenders.sorted(),
            [],
            "a literal GRPCError.http2(\"…) status+body packing reappeared; the login path must throw HeadlessError.http (#40)"
        )
    }

    /// The repository root, derived from this file's location.
    @MainActor
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportLoginClientErrorShapeTests.swift
            .deletingLastPathComponent()  // TeleportPackageTests/
            .deletingLastPathComponent()  // Tests/
    }

    @MainActor
    private static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files
    }

    // MARK: - Helpers

    @MainActor
    private static func makeRegisteredKeyRing(
        clusterId: UUID,
        credentialID: Data
    ) -> MockTeleportKeyRing {
        let keyRing = MockTeleportKeyRing()
        keyRing.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: credentialID,
                userHandle: Data("user-handle".utf8),
                deviceName: "test-device"
            )
        )
        return keyRing
    }

    /// A WebAuthn builder stub that returns a plausible scripted assertion so
    /// the coordinator reaches `login/finish`.
    private final class ScriptedWebAuthnBuilderStub: TeleportWebAuthnBuilding {
        nonisolated deinit {}
        func register(
            origin: String,
            rpID: String,
            challenge: Data,
            credentialID: Data,
            publicKeyRaw: Data,
            signer: any WebAuthnSigner
        ) throws -> CredentialCreationResponse {
            CredentialCreationResponse(
                id: "credential-id",
                type: "public-key",
                rawId: Data([1, 2, 3, 4]).base64URLEncodedString(),
                response: AuthenticatorAttestationResponse(
                    clientDataJSON: Data([1, 2, 3]).base64URLEncodedString(),
                    attestationObject: Data([4, 5, 6]).base64URLEncodedString()
                )
            )
        }

        func login(
            origin: String,
            rpID: String,
            challenge: Data,
            credentialID: Data,
            userHandle: Data?,
            signer: any WebAuthnSigner
        ) throws -> CredentialAssertionResponse {
            CredentialAssertionResponse(
                id: "credential-id",
                type: "public-key",
                rawId: Data([1, 2, 3, 4]).base64URLEncodedString(),
                response: AuthenticatorAssertionResponse(
                    clientDataJSON: Data([1, 2, 3]).base64URLEncodedString(),
                    authenticatorData: Data([4, 5, 6]).base64URLEncodedString(),
                    signature: Data([7, 8, 9]).base64URLEncodedString(),
                    userHandle: Data("user-handle".utf8).base64URLEncodedString()
                )
            )
        }
    }
}

#endif
