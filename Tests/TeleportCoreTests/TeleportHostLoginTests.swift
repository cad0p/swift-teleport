// SPDX-License-Identifier: MIT
//
//  TeleportHostLoginTests.swift
//  TeleportCoreTests
//
//  Unit coverage for the pure Teleport SSH-username resolver (#262), ported
//  from the host's `VVTermTests/Features/Teleport/TeleportHostLoginTests.swift`
//  at `30ac5388`. The host's `failClosedRouteClearsTheCredentialAndReturnsTheNamedError`
//  is deliberately absent: that route (`SSHError.teleportHostLoginUnresolvable`
//  + the keyring clear) is host-only app policy (A3), not package behavior.
//
//  The resolver is the only writer of the Teleport SSH username. It must:
//    - use the stored login only when it is still a principal of the exact
//      certificate being sent;
//    - derive a login only for an exactly-one-principal certificate;
//    - fail closed (never guess, never send a non-principal) for an ambiguous
//      or empty principal set, or an unreadable certificate;
//    - filter internal (`-…`) principals before both paths, in certificate
//      wire order (tsh `Logins:` parity).
//

import Foundation
import Testing
@testable import TeleportCore

struct TeleportHostLoginTests {

    // MARK: - Fixtures

    private func makeCert(
        keyID: String = "pier",
        principals: [String]
    ) -> OpenSSHCertificate {
        OpenSSHCertificate(
            rawBlob: Data([0x01, 0x02]),
            certKeyType: "ssh-ed25519-cert-v01@openssh.com",
            nonce: Data([0, 1, 2, 3]),
            publicKeyBlob: Data([9, 9, 9]),
            serial: 1,
            certType: .user,
            keyID: keyID,
            validPrincipals: principals,
            validAfter: 0,
            validBefore: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970),
            criticalOptions: Data(),
            extensions: Data(),
            reserved: Data(),
            signatureKeyBlob: Data([7, 7]),
            signatureBlob: Data([8, 8]),
            signedData: Data([1, 2, 3])
        )
    }

    // MARK: - Stored login

    @Test
    func storedLoginIsUsedWhenItIsStillAPrincipal() {
        let cert = makeCert(principals: ["deploy", "root", "-teleport-internal-join"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "root")
                == .success("root")
        )
    }

    @Test
    func storedLoginThatIsNoLongerAPrincipalFallsBackToASinglePrincipal() {
        let cert = makeCert(principals: ["deploy"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "old-login")
                == .success("deploy")
        )
    }

    @Test
    func storedLoginThatIsNoLongerAPrincipalFailsClosedWhenAmbiguous() {
        let cert = makeCert(principals: ["deploy", "root"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "old-login")
                == .failure(.ambiguousPrincipalSet(["deploy", "root"]))
        )
    }

    @Test
    func storedInternalPrincipalIsNeverUsed() {
        // A stored value that only matches an internal principal must not be
        // sent; the internal principal is filtered from the logins, so the
        // resolution falls through to the fallback.
        let cert = makeCert(principals: ["deploy", "-teleport-internal-join"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "-teleport-internal-join")
                == .success("deploy")
        )
    }

    @Test
    func blankStoredLoginIsTreatedAsNoPreference() {
        let cert = makeCert(principals: ["deploy"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "   ")
                == .success("deploy")
        )
    }

    // MARK: - Derived fallback

    @Test
    func singleNonInternalPrincipalIsDerived() {
        let cert = makeCert(principals: ["deploy", "-teleport-internal-join"])
        #expect(TeleportHostLogin.resolve(cert: cert, storedLogin: nil) == .success("deploy"))
    }

    @Test
    func multiplePrincipalsFailClosed() {
        let cert = makeCert(principals: ["deploy", "root", "-teleport-internal-join"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: nil)
                == .failure(.ambiguousPrincipalSet(["deploy", "root"]))
        )
    }

    @Test
    func noPrincipalsFailClosed() {
        #expect(
            TeleportHostLogin.resolve(cert: makeCert(principals: []), storedLogin: nil)
                == .failure(.noPrincipals)
        )
    }

    @Test
    func onlyInternalPrincipalsFailClosed() {
        #expect(
            TeleportHostLogin.resolve(
                cert: makeCert(principals: ["-teleport-internal-join"]),
                storedLogin: nil
            ) == .failure(.noPrincipals)
        )
    }

    @Test
    func principalOrderIsCertificateWireOrder() {
        let cert = makeCert(principals: ["first", "second", "third"])
        // Wire order matters for the ambiguous error (tsh `Logins:` parity).
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: nil)
                == .failure(.ambiguousPrincipalSet(["first", "second", "third"]))
        )
        #expect(TeleportHostLogin.nonInternalPrincipals(of: cert) == ["first", "second", "third"])
    }

    // MARK: - Parse path

    @Test
    func parsesTheFixtureCertAndUsesItsPrincipal() {
        // The fixture cert (`user-cert-ed25519.pub`) carries one principal:
        // `alice`. A stored `alice` is used; a stored non-principal degrades to
        // the derived single principal.
        let certPEM = TeleportFixtureSupport.fixedIssuedUserCert
        #expect(
            TeleportHostLogin.resolveUsername(certPEM: certPEM, storedLogin: "alice")
                == .success("alice")
        )
        #expect(
            TeleportHostLogin.resolveUsername(certPEM: certPEM, storedLogin: "deploy")
                == .success("alice")
        )
    }

    @Test
    func unreadableCertificateFailsClosed() {
        #expect(
            TeleportHostLogin.resolveUsername(certPEM: "not-a-certificate", storedLogin: "deploy")
                == .failure(.certificateUnreadable)
        )
        #expect(
            TeleportHostLogin.resolveUsername(certPEM: "", storedLogin: nil)
                == .failure(.certificateUnreadable)
        )
    }

    // MARK: - Setup picker initial selection

    @Test
    func initialSelectionPrefersAStillValidStoredLogin() {
        #expect(
            TeleportHostLogin.initialSelection(logins: ["deploy", "root"], stored: "root") == "root"
        )
    }

    @Test
    func initialSelectionAutoSelectsASinglePrincipal() {
        #expect(TeleportHostLogin.initialSelection(logins: ["deploy"], stored: nil) == "deploy")
    }

    @Test
    func initialSelectionRequiresAnExplicitPickForMultiplePrincipals() {
        // The CA's wire order must never be frozen silently.
        #expect(TeleportHostLogin.initialSelection(logins: ["deploy", "root"], stored: nil) == nil)
        // A stored value that is no longer a principal is not a valid default
        // either: the fresh cert is ambiguous, so the user must pick.
        #expect(
            TeleportHostLogin.initialSelection(logins: ["deploy", "root"], stored: "old-login") == nil
        )
    }

    @Test
    func initialSelectionIgnoresBlankStoredValuesAndEmptyLogins() {
        #expect(TeleportHostLogin.initialSelection(logins: ["deploy"], stored: "   ") == "deploy")
        #expect(TeleportHostLogin.initialSelection(logins: [], stored: "deploy") == nil)
    }

    // MARK: - Shape normalization (moved out of the host's `Server`)

    @Test
    func normalizedAcceptsOnlyUsableLoginShapes() {
        #expect(TeleportHostLogin.normalized(nil) == nil)
        #expect(TeleportHostLogin.normalized("") == nil)
        #expect(TeleportHostLogin.normalized("   ") == nil)
        #expect(TeleportHostLogin.normalized("de\nploy") == nil)
        #expect(TeleportHostLogin.normalized(String(repeating: "a", count: 256)) == nil)
        #expect(
            TeleportHostLogin.normalized(String(repeating: "a", count: 255))
                == String(repeating: "a", count: 255)
        )
        #expect(TeleportHostLogin.normalized("deploy") == "deploy")
        // `@` is explicitly allowed (Teleport logins may contain it).
        #expect(TeleportHostLogin.normalized("deploy@example.com") == "deploy@example.com")
        #expect(TeleportHostLogin.normalized(" deploy ") == "deploy")
    }

    @Test
    func normalizedUsesTheFrozenByteBound() {
        #expect(TeleportHostLogin.maxTeleportHostLoginBytes == 255)
    }

    // MARK: - Failure descriptions

    @Test
    func failureDescriptionsAreUserFacingAndNameTheLoginsOnlyForAmbiguity() {
        #expect(TeleportHostLoginFailure.noPrincipals.errorDescription?.isEmpty == false)
        let ambiguous = TeleportHostLoginFailure.ambiguousPrincipalSet(["deploy", "root"])
        #expect(ambiguous.errorDescription?.contains("deploy, root") == true)
        #expect(TeleportHostLoginFailure.certificateUnreadable.errorDescription?.isEmpty == false)
    }

    /// The package-level redaction pin: `String(describing:)` (logs, the
    /// shareable diagnostics export) must render the stable case name only —
    /// the principal array is identity material and must never be interpolated
    /// into a log line or a report.
    @Test
    func failureDescriptionsNeverRenderThePrincipalsThroughStringDescribing() {
        let ambiguous = TeleportHostLoginFailure.ambiguousPrincipalSet(["deploy", "root"])
        #expect(String(describing: ambiguous) == ambiguous.caseDescription)
        #expect(String(describing: ambiguous) == "ambiguousPrincipalSet")
        #expect(!String(describing: ambiguous).contains("deploy"))
        #expect(!String(describing: ambiguous).contains("root"))

        #expect(String(describing: TeleportHostLoginFailure.noPrincipals) == "noPrincipals")
        #expect(String(describing: TeleportHostLoginFailure.certificateUnreadable) == "certificateUnreadable")
    }

    /// The reflection pin: `dump(_:)` and `Mirror(reflecting:)` bypass
    /// `description` and read the reflection surface, which used to expose the
    /// associated principal list (`["deploy", "root"]`). The conformance makes
    /// the reflection surface payload-free — one labelled child carrying the
    /// stable case name.
    @Test
    func failureDescriptionsNeverRenderThePrincipalsThroughReflection() {
        let ambiguous = TeleportHostLoginFailure.ambiguousPrincipalSet(["deploy", "root"])

        var dumped = ""
        dump(ambiguous, to: &dumped)
        #expect(!dumped.contains("deploy"))
        #expect(!dumped.contains("root"))

        let mirror = Mirror(reflecting: ambiguous)
        #expect(mirror.children.count == 1)
        #expect(mirror.children.first?.label == "case")
        #expect(mirror.children.first.map { String(describing: $0.value) } == ambiguous.caseDescription)

        // Regression guards, not the counterfactual: these render through
        // `CustomStringConvertible` and already passed before the
        // `CustomReflectable` conformance.
        #expect(String(reflecting: ambiguous) == ambiguous.caseDescription)
        #expect(ambiguous.debugDescription == ambiguous.caseDescription)
    }
}
