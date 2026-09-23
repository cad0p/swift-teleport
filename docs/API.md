# Public API

The `TeleportCore` product exports the **D6 seam**, the **transports**, and the
types reachable from their signatures. Model internals (the OpenSSH parser, the
trust policy, the readiness resolver, the cluster/credential models) stay
`internal` until `v0.2.0`.

Per the package's `0.x` policy (D13), minors may break the API; patches never.

## Seam protocols

```swift
public protocol TeleportLogging: Sendable {
    nonisolated func logger(category: String) -> Logger
}

public struct DefaultTeleportLogging: TeleportLogging {
    public let subsystem: String
    public init(subsystem: String = "Teleport")
    public nonisolated func logger(category: String) -> Logger
}

public protocol TeleportCredentialStore: Sendable {
    func clusterTLSState(for clusterId: UUID) async -> TeleportClusterTLSState?
    func liveCertPEM(for clusterId: UUID) async -> String?
    func liveEd25519PrivateKey(for clusterId: UUID) async -> Data?
    func registeredCredentialID(for clusterId: UUID) async -> Data?
    func registeredUserHandle(for clusterId: UUID) async -> Data?
    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async
    func storeRegisteredSEPKey(credentialID: Data, userHandle: Data, publicKeyRaw: Data,
                               deviceName: String, for clusterId: UUID) async
    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async
    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) async throws
    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID) async
    func updateClusterHostKeys(_ checkingKeys: [String],
                               for clusterId: UUID) async -> TeleportHostKeyUpdateResult
    func clear(for clusterId: UUID) async
}

@MainActor public protocol BrowserMFASessionHandle: AnyObject, Sendable {
    var didStart: Bool { get }
    func cancel()
}

@MainActor public protocol BrowserMFAPresenting: Sendable {
    func present(url: URL,
                 completion: @escaping @Sendable (Error?) -> Void) async -> any BrowserMFASessionHandle
}

public protocol TeleportSessionMutex: Sendable {
    func withLock<T>(_ body: () -> T) -> T
}

public protocol TeleportChannelTransport: Sendable {
    func start() async throws -> Int32
    func close() async
    nonisolated func cancelPumpSync()
}

public protocol TeleportChannelTransportFactory: Sendable {
    func makeChannelTransport(channel: OpaquePointer,
                              outerSession: OpaquePointer?,
                              mutex: any TeleportSessionMutex) -> any TeleportChannelTransport
}
```

## Seam payload types

```swift
public struct TeleportClusterTLSState: Codable, Hashable, Sendable {
    public let clusterName: String
    public let clusterCAPEMs: [String]
    public let hostCACheckingKeys: [String]
    public init(clusterName: String, clusterCAPEMs: [String], hostCACheckingKeys: [String] = [])
}

public enum TeleportHostKeyUpdateResult: Equatable {
    case updated
    case rejectedWouldDropPinnedKeys
    case noChange
}

public enum TeleportPackageError: Error, LocalizedError, Equatable {
    case connectionFailed(String)
    case keychain(OSStatus)
}
```

## Transports

```swift
public actor SSHTLSTransport {
    public static let alpnProtocol = "teleport-proxy-ssh"
    public static let offeredALPNProtocols: [String]
    public struct SocketPair: Sendable { public let libssh2FD: Int32; public let pumpFD: Int32 }
    public init(host: String, port: Int, clusterName: String,
                clusterCAPEMs: [String], logging: any TeleportLogging)
    public static func makeTLSOptions(clusterName: String, clusterCAPEMs: [String],
                                      dialHost: String, logger: Logger) throws -> NWProtocolTLS.Options
    public static func makeSocketPair() throws -> SocketPair
    public func connect() async throws -> Int32
    public func close()
}

public enum TeleportProxySubsystem {
    public static func request(for nodeName: String, port: Int = 0, cluster: String? = nil) -> String
}

nonisolated public enum TeleportTLSTrust {
    public static let clusterLocalName = "teleport.cluster.local"
    public static func anchors(fromPEMs pems: [String]) -> [SecCertificate]
    public static func pemToDER(pem: String, label: String) throws -> Data
    public static func sshServerNames(dialHost: String) -> [String]
    public static func authServerNames(clusterName: String) -> [String]
    public static func encodedClusterName(_ name: String) -> String
    public static func verify(trust: SecTrust, anchors: [SecCertificate], serverNames: [String],
                              negotiatedALPN: String?, allowedALPNs: [String]) -> (ok: Bool, error: CFError?)
    public static func certificateIsCA(_ certificate: SecCertificate) -> Bool
    public static func certificateAllowsTLSServerUse(_ certificate: SecCertificate) -> Bool
    public static func certificate(_ certificate: SecCertificate, matchesName name: String) -> Bool
    public static func parseExtensions(der: Data) -> ParsedExtensions?
    public static func makeVerifyBlock(anchors: [SecCertificate], serverNames: [String],
                                       allowedALPNs: [String], logger: Logger) -> sec_protocol_verify_t
    public static func negotiatedProtocol(from metadata: sec_protocol_metadata_t) -> String?
    public struct ParsedExtensions { /* public fields */ }
}

public enum TeleportTLSTrustError: LocalizedError {
    case malformedPEM(String)
}
```

## Usage sketch

```swift
import TeleportCore

let subsystem = "com.example.app"
let logging = DefaultTeleportLogging(subsystem: subsystem)

let subsystemRequest = TeleportProxySubsystem.request(for: "node-1", port: 0, cluster: nil)
// "proxy:node-1:0"

let transport = SSHTLSTransport(
    host: "teleport.example.com", port: 443,
    clusterName: "teleport.example.com",
    clusterCAPEMs: caPEMs,
    logging: logging
)
let fd = try await transport.connect()
// hand `fd` to libssh2_session_handshake …
await transport.close()
```

The non-`@testable` consumer test target
(`Tests/TeleportCoreConsumerTests`) exercises exactly this surface.
