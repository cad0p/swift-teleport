# Public API

Three products: `TeleportCore` (seam + transports + gRPC/protobuf + WebAuthn/SEP
+ wire types), `TeleportAuth` (coordinators + keyring + web-api client), and
`TeleportTesting` (the mocks). Per the package's `0.x` policy (D13), minors may
break the API; patches never.

## `TeleportCore`

### Seam protocols

```swift
public protocol TeleportLogging: Sendable {
    nonisolated func logger(category: String) -> Logger
}

public struct DefaultTeleportLogging: TeleportLogging {
    public let subsystem: String
    public init(subsystem: String = "Teleport")
    public nonisolated func logger(category: String) -> Logger
}

public protocol TeleportCredentialStore: Sendable { /* 12 async members */ }

@MainActor public protocol BrowserMFASessionHandle: AnyObject, Sendable { … }
@MainActor public protocol BrowserMFAPresenting: Sendable { … }
public protocol WebAuthenticationSessionPresenting: AnyObject { … }

public protocol TeleportSessionMutex: Sendable { … }
public protocol TeleportChannelTransport: Sendable { … }
public protocol TeleportChannelTransportFactory: Sendable { … }

public protocol TeleportHTTPClienting: AnyObject { … }
public protocol TeleportGRPCClienting: AnyObject { … }
public protocol BrowserMFACeremonyRunning: AnyObject { … }
public protocol TeleportSSHKeyPairGenerating: AnyObject { … }
public protocol TeleportTLSKeyPairGenerating: AnyObject { … }
public protocol TeleportWebAuthnBuilding: AnyObject { … }
public protocol TeleportSEPSigning: WebAuthnSigner, SEPKeySigning, AnyObject {}
```

Live defaults (public, constructible): `LiveTeleportSSHKeyPairGenerator`,
`LiveTeleportTLSKeyPairGenerator`, `TeleportWebAuthnBuilder`.

### Transports

```swift
public actor SSHTLSTransport { … }                 // TLS+ALPN SSH bridge
nonisolated public enum TeleportTLSTrust { … }     // chain/name/EKU/ALPN verification
public enum TeleportProxySubsystem { … }

public final class TeleportGRPCConnection: @unchecked Sendable {
    public static func connect(host:port:clientCertPEM:privateKey:clusterName:clusterCAPEMs:logger:) async throws -> TeleportGRPCConnection
    public func unary<R: SwiftProtobuf.Message, S: SwiftProtobuf.Message>(path:request:responseType:) async throws -> S
    public func close() async throws
    public func deleteKeychainIdentity()
}

public enum GRPCError: Error, CustomStringConvertible, LocalizedError { … }
public enum GRPCTLSOptions { … }

/// The per-connect keychain identity. The cleanup surface is **release-
/// visible by decision** (issue #16):
///
/// - `labelPrefix = "vvterm-grpc-"` scopes every identity this app creates.
/// - `staleIdentityAge = 30 * 60` ages out leftovers from a crashed process.
/// - the sweep runs at most once per process, skips registered live labels,
///   and only re-arms when every keychain class enumerated successfully.
/// - the `…ForTesting` seams are `#if DEBUG`-gated and absent from release.
///
/// DECISION (recorded on #16): keep the release-visible surface. The sweep is
/// bounded by the app's own label registry + the age gate, and the direct
/// `deleteKeychainItems(label:)` call below is **caller-supplied-label only**
/// — it is NOT prefix-scoped; only `deleteStaleIdentities(logger:)` is.
public struct GRPCClientIdentity {
    public static let labelPrefix: String
    public static let staleIdentityAge: TimeInterval
    public static func makeLabel(now: Date) -> String
    public static func isLiveLabel(_ label: String) -> Bool
    public func deleteKeychainItems(logger: Logger)
    public static func deleteKeychainItems(label: String, logger: Logger)
    @discardableResult public static func deleteStaleIdentities(logger: Logger) -> Bool
    #if DEBUG
    public static func deleteStaleIdentitiesForTesting(logger: Logger) -> Bool
    public static func resetSweepGateForTesting()
    #endif
}
```

### Domain + wire

```swift
public enum HostKeyTrustPolicy { public enum Decision { … }; public static func decide(…) -> Decision }
public struct OpenSSHCertificate { public enum CertType; /* public fields */; public static func parse(…) }
public enum OpenSSHHostCertVerifier { public static func verify(…) -> OpenSSHHostCertVerification }
public struct TeleportCluster { public init(…); public var sepKeyLabel }
public struct TeleportCredential { public init(…); public var isCertValid }
public enum TeleportDeviceReadiness { … }
public enum TeleportDeviceName { public static func `default`/sanitize/validate }
public struct TeleportKeychainConfig: @unchecked Sendable { public init(keychainService:defaults:) }
public enum TeleportHostKeyUpdatePolicy { public static func apply(…); matchesPinnedCluster(…) }
public enum TeleportHostCACheckingKeysDecoder { … }

public enum HeadlessID { public static func compute(sshAuthorizedKey:) -> String }
public enum HeadlessError: LocalizedError { … }
public struct HeadlessLoginReq: Encodable { public init(…) }
public struct HeadlessLoginResponse: Decodable { public init(…); public struct TrustedCerts }
public enum HeadlessLogin { public static var defaultSession; public static func post(…) }
public enum TeleportTrustSession { public static let session: URLSession }
public struct TLSKeyPair { public init(privateKey:publicKeyPEM:) }
public struct LoginBeginResponse: Decodable { public init(…); … }
public struct LoginFinishResponse: Decodable { public init(…); … }
public struct LoginFinishReq: Encodable { public init(…) }

// WebAuthn / SEP
public protocol WebAuthnSigner: AnyObject { … }
public protocol SEPKeySigning { … }
public enum CeremonyType; public struct CollectedClientData; public struct AttestationData
public struct CredentialData; public struct PublicKeyCredential; public struct AuthenticatorResponse
public struct AuthenticatorAttestationResponse; public struct AuthenticatorAssertionResponse
public struct CredentialCreationResponse; public struct CredentialAssertionResponse
public final class SecureEnclaveSigner: WebAuthnSigner, SEPKeySigning { … }

@MainActor public final class BrowserMFACeremony: NSObject {
    public init(logging: any TeleportLogging, presenter: any BrowserMFAPresenting)
    public func run(grpcClient: any TeleportGRPCClienting, host: String) async throws -> Proto_BrowserMFAResponse
}
public enum BrowserMFACeremonyError: Error, LocalizedError { public var errorDescription: String? }

// Generated protobuf (Visibility=Public): all Proto_* messages/enums.
```

### Package-internal (`package`, not host-visible)

These are reachable from every target inside this package (the coordinators,
`TeleportTesting`, and the test targets) but deliberately not `public`: no
Phase 2 host file names them, and a `public` surface they do not need would
freeze them against future refactors.

```swift
package enum TeleportIssuedCertValidator { package enum Failure; … }
package enum TeleportWebAuthnRPID { package enum ResolveError; … }
package struct TeleportDeviceReadinessResolver { … }
package enum TLSKeyPairGen { package static func generate() throws -> TLSKeyPair }
package enum SignerError: Error, LocalizedError, CustomStringConvertible { … }
package enum CBOR { … }
package enum SSHPubKey { … }
package func makeAttestationData(…) throws -> AttestationData
package func coseEC2PublicKeyCBOR(publicKeyRaw:) throws -> Data
package enum WebAuthn { package static func register(…)/login(…) }
```

The software P-256 signer is **not** in this list: `SoftwareSigner` ships in
**`TeleportTesting`** as a `public` test double, so an external test target —
the host-side `TeleportServerIntegrationTests` that constructs it today, and
the Phase 2 host generally — can inject it without `package` access.

## `TeleportAuth`

```swift
@MainActor public protocol TeleportBootstrapCoordinating: AnyObject, ObservableObject { … }
@MainActor public final class TeleportBootstrapCoordinator: ObservableObject, TeleportBootstrapCoordinating {
    public init(httpClient:keyRing:safariPresenter:logging:signer:sshKeyPairGenerator:tlsKeyPairGenerator:now:)
    public struct BootstrapResult { public init(…); /* public fields */ }
    public func begin(cluster:) async; public func cancel() async; public func retry() async
}
public enum TeleportBootstrapState / TeleportBootstrapError { … }

@MainActor public protocol TeleportLoginCoordinating: AnyObject, ObservableObject { … }
@MainActor public final class TeleportLoginCoordinator: ObservableObject, TeleportLoginCoordinating { … }
public enum TeleportLoginState / TeleportLoginError { … }

@MainActor public protocol TeleportRegistrationCoordinating: AnyObject, ObservableObject { … }
@MainActor public final class TeleportRegistrationCoordinator: ObservableObject, TeleportRegistrationCoordinating { … }
public enum TeleportRegistrationState / TeleportRegistrationError { … }

@MainActor public final class TeleportKeyRing: ObservableObject, TeleportCredentialStore {
    public init(signer:logging:config:)
    @Published public private(set) var credentials: [UUID: TeleportCredential]
    public func readiness(for:) -> TeleportDeviceReadiness
    // + the TeleportCredentialStore witnesses
}

public struct TeleportHTTPClient { public init(baseURL:); public struct HeadlessLoginResult / LoginBeginResult; … }
```

## `TeleportTesting`

The 7 public mocks, UI-free and app-type-free: `MockSEPKeySigner` (`.success`,
`.cancelled`, `.lockout`, `.notEnrolled`), `MockTeleportHTTPClient`,
`MockTeleportKeyRing` (+ `Fixture`), `MockTeleportBootstrapCoordinator`
(+ `Scenario`), `MockTeleportLoginCoordinator` (+ `Scenario`),
`MockTeleportRegistrationCoordinator` (+ `Scenario`),
`MockWebAuthenticationSessionPresenter`.

Plus `SoftwareSigner`: the software P-256 signer (`public final class
SoftwareSigner: WebAuthnSigner, SEPKeySigning, TeleportSEPSigning`) that makes
the SEP ceremony testable without hardware. It is a test double, so it lives
here rather than in `TeleportCore` — that is also what lets the kept host-side
`TeleportServerIntegrationTests` construct it from a different package.

`MockTeleportKeyRing` conforms only to `TeleportCredentialStore`; the host
restores its `TeleportKeyRingStoring` observation conformance by extension in
Phase 2.

## Enforcement

`Fixtures/HostSurfaceCheck` is a **separate SwiftPM package** that
path-depends on this one; its `HostSurfaceMirrors` compile the host's
`TeleportComposition`, `TeleportLiveCoordinators`, `TeleportKeyRingStoring`,
`TeleportKeyRingCredentialStore`, `SSHClient` host-key verification, and one
iOS harness against the public surface only. A missing promotion fails that
build instead of Phase 2.

The in-package `Tests/TeleportCoreConsumerTests` target is a non-`@testable`
public-seam smoke test (`PublicSeamSmokeTests`); it catches `public` →
`internal` demotions but, because `package` access is visible to every target
in this package, it cannot catch a `public` → `package` demotion. That is what
the sibling fixture package is for.
