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
public struct GRPCClientIdentity { … }
```

### Domain + wire

```swift
public enum HostKeyTrustPolicy { public enum Decision { … }; public static func decide(…) -> Decision }
public struct OpenSSHCertificate { public enum CertType; /* public fields */; public static func parse(…) }
public enum OpenSSHHostCertVerifier { public static func verify(…) -> OpenSSHHostCertVerification }
public enum TeleportIssuedCertValidator { public enum Failure; public static func validateIssuedUserCert(…); validateTLSCertBinding(…) }
public enum TeleportWebAuthnRPID { public enum ResolveError; public static func resolve(serverProvided:cluster:) }
public struct TeleportCluster { public init(…); public var sepKeyLabel }
public struct TeleportCredential { public init(…); public var isCertValid }
public enum TeleportDeviceReadiness { … }
public struct TeleportDeviceReadinessResolver { public init(…); public func resolve(clusterId:now:) }
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
public enum TLSKeyPairGen { public static func generate() throws -> TLSKeyPair }
public struct LoginBeginResponse: Decodable { public init(…); … }
public struct LoginFinishResponse: Decodable { public init(…); … }
public struct LoginFinishReq: Encodable { public init(…) }

// WebAuthn / SEP
public protocol WebAuthnSigner: AnyObject { … }
public protocol SEPKeySigning { … }
public enum SignerError: Error, LocalizedError, CustomStringConvertible { … }
public enum CBOR { … }
public enum SSHPubKey { public static func generateEd25519KeyPair(…) }
public enum CeremonyType; public struct CollectedClientData; public struct AttestationData
public struct CredentialData; public struct PublicKeyCredential; public struct AuthenticatorResponse
public struct AuthenticatorAttestationResponse; public struct AuthenticatorAssertionResponse
public struct CredentialCreationResponse; public struct CredentialAssertionResponse
public func makeAttestationData(…) throws -> AttestationData
public func coseEC2PublicKeyCBOR(publicKeyRaw:) throws -> Data
public enum WebAuthn { public static func register(…)/login(…) }
public final class SecureEnclaveSigner: WebAuthnSigner, SEPKeySigning { … }
public final class SoftwareSigner: WebAuthnSigner { … }

@MainActor public final class BrowserMFACeremony: NSObject {
    public init(logging: any TeleportLogging, presenter: any BrowserMFAPresenting)
    public func run(grpcClient: any TeleportGRPCClienting, host: String) async throws -> Proto_BrowserMFAResponse
}

// Generated protobuf (Visibility=Public): all Proto_* messages/enums.
```

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

`MockTeleportKeyRing` conforms only to `TeleportCredentialStore`; the host
restores its `TeleportKeyRingStoring` observation conformance by extension in
Phase 2.

## Enforcement

`Tests/TeleportCoreConsumerTests` is a non-`@testable` target: its
`HostSurfaceCompileTests` mirrors the host's `TeleportComposition`,
`TeleportLiveCoordinators`, `TeleportKeyRingStoring`,
`TeleportKeyRingCredentialStore`, `SSHClient` host-key verification, and one
iOS harness. A missing promotion fails that target instead of Phase 2.
