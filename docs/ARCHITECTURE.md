# Architecture

## Layout

```
Sources/
├── TeleportCore/                  pure logic + transports + wire (no Auth)
│   ├── Application/
│   │   ├── SSHCertExpiryParser.swift            cert ValidBefore extraction
│   │   └── TeleportInfrastructureProtocols.swift seam protocols + live generators
│   ├── Domain/
│   │   ├── BrowserMFAPresenting.swift           seam: in-app browser presenter
│   │   ├── HostKeyTrustPolicy.swift             pure host-key trust decision
│   │   ├── OpenSSHCertificate.swift             OpenSSH cert wire-format parser
│   │   ├── OpenSSHHostCertVerifier.swift        host-cert → Host CA verification
│   │   ├── TeleportChannelTransport.swift       seam: libssh2 channel bridge
│   │   ├── TeleportCluster.swift                cluster config model
│   │   ├── TeleportClusterTLSState.swift        persisted cluster trust anchors
│   │   ├── TeleportCredential.swift             registered SEP key + cert metadata
│   │   ├── TeleportCredentialStore.swift        seam: credential store protocol
│   │   ├── TeleportDeviceName.swift             MFA device-name sanitization
│   │   ├── TeleportDeviceReadiness.swift        derived readiness resolver
│   │   ├── TeleportIssuedCertValidator.swift    issued-cert binding checks
│   │   ├── TeleportKeychainConfig.swift         keychain service + defaults injection
│   │   ├── TeleportLogging.swift                seam: os.Logger factory
│   │   ├── TeleportPackageError.swift           package-owned error type
│   │   └── TeleportWebAuthnRPID.swift           server-vs-configured rpID rule
│   └── Infrastructure/
│       ├── SSHTLSTransport.swift                TLS+ALPN transport (actor + pump)
│       ├── TeleportProxySubsystem.swift         proxy subsystem string builder
│       ├── TeleportTLSTrust.swift               TLS chain/name/EKU verification
│       ├── GRPCClient.swift                     HTTP/2 framing + gRPC unary handler
│       ├── GRPCTransport.swift                  TLS+ALPN+mTLS gRPC dial
│       ├── iotest_mfa.pb.swift                  generated protobuf (+ .proto IDL)
│       ├── HeadlessID.swift                     UUIDv5 headless auth id
│       ├── HeadlessLogin.swift                  POST /webapi/headless/login
│       ├── MFALoginWireTypes.swift              login/begin + login/finish wire
│       ├── TeleportTrustSession.swift           the shared webapi URLSession
│       ├── TLSKeyPair.swift                     ephemeral EC P-256 TLS keypair
│       ├── BrowserMFAListener.swift             loopback callback listener
│       ├── BrowserMFACeremony.swift             the Browser MFA ceremony
│       └── SEPWebAuthn/
│           ├── CBOR.swift                       canonical CTAP2 CBOR encoder
│           ├── SSHPubKey.swift                  ed25519 authorized_keys + PEM
│           ├── Signer.swift                     WebAuthnSigner + SignerError
│           ├── Attestation.swift                clientData/authData/COSE builders
│           ├── WebAuthn.swift                   register/login response builders
│           └── SecureEnclaveSigner.swift        SEP-backed signer
├── TeleportAuth/                  coordinators + persistence
│   ├── Application/
│   │   ├── TeleportBootstrapCoordinator.swift   Phase 1 (headless bootstrap)
│   │   ├── TeleportLoginCoordinator.swift       Phase 3 (passwordless login)
│   │   ├── TeleportRegistrationCoordinator.swift Phase 2 (SEP registration)
│   │   └── TeleportKeyRing.swift                per-cluster credential store
│   ├── Infrastructure/
│   │   └── TeleportHTTPClient.swift             webapi convenience client
│   └── PrivacyInfo.xcprivacy                    UserDefaults CA92.1
└── TeleportTesting/               the 8 public test doubles
    ├── SoftwareSigner.swift                     software P-256 signer (CI seam)
    └── Mock*.swift                              the 7 scripted mocks
```

The `Domain` / `Application` / `Infrastructure` split mirrors the host
repository's feature-first architecture. Nothing in `Domain` imports
`Infrastructure`; `TeleportCore` never names a `TeleportAuth` symbol.

## The D6 seam

The package cannot own the host app's keychain, logging subsystem, or browser
presentation. Instead it declares narrow protocols that the host implements at
its composition root:

| Protocol | Host responsibility |
| --- | --- |
| `TeleportCredentialStore` | per-cluster cert/key/TLS-state persistence |
| `TeleportLogging` | `os.Logger` factory (preserves the app subsystem + category strings) |
| `BrowserMFAPresenting` / `BrowserMFASessionHandle` | `ASWebAuthenticationSession` + presentation anchor |
| `WebAuthenticationSessionPresenting` | the headless-flow Safari presenter |
| `TeleportHTTPClienting` / `TeleportGRPCClienting` / `BrowserMFACeremonyRunning` | the live adapter seams the coordinators consume |
| `TeleportSSHKeyPairGenerating` / `TeleportTLSKeyPairGenerating` / `TeleportWebAuthnBuilding` | injectable key/response builders |
| `TeleportSessionMutex` / `TeleportChannelTransport` / `TeleportChannelTransportFactory` | the libssh2 channel bridge |

The libssh2 channel bridge is **host-side by design**: the 14 libssh2 calls
and the `SessionMutex` live in the host, exposed to the package only through
`TeleportChannelTransportFactory`. Cancellation must stay synchronous
(`cancelPumpSync()` is `nonisolated` and non-`async`) so the pump can be
stopped before the outer libssh2 session is freed — an `await` there could
deadlock.

The host's observation protocol (`TeleportKeyRingStoring`) is host-side too:
`TeleportKeyRing` conforms to the plain `TeleportCredentialStore` seam, and
the host restores the `@MainActor` observation conformance by extension in
Phase 2.

## Transport: TLS + ALPN

Teleport proxies (Teleport 13+) multiplex all client protocols on port 443
behind one TLS listener. SSH is reached via ALPN protocol
`teleport-proxy-ssh` inside a TLS tunnel. `SSHTLSTransport` dials that tunnel
and bridges it to libssh2, which needs a raw file descriptor:

```
libssh2 ──read/write── libssh2FD ──┐
                                   │ socketpair (AF_UNIX, SOCK_STREAM)
NWConnection ──send/receive── pumpFD ┘
```

`TeleportTLSTrust` is the single place that turns an incoming `SecTrust` into
an accept/reject decision. It never evaluates the trust's inherited policy;
it sets an explicit SSL policy per candidate name and enforces the Host-CA
chain, the name (dial host / `teleport.cluster.local`), the negotiated ALPN,
and the leaf's EKU/keyUsage and non-CA status. Long-lived Host-CA host
certificates (which Apple's 398-day SSL policy rejects) fall back to a
BasicX509 chain + explicit SAN match, with the same EKU/keyUsage/CA checks.

## gRPC auth transport

`GRPCTransport` dials the auth service through the ALPN-SNI route
(`teleport-auth@<hex(cluster)>`) with the Phase-1 TLS cert as the client
identity, using NIOTS (Network.framework). `GRPCClient` owns the
platform-independent HTTP/2 framing, the unary handler, and the protobuf
message framing. Per-connect keychain identities are labelled
`vvterm-grpc-<millis>-<uuid>` and deleted on `close()`; a startup sweep
removes stale identities older than 30 minutes.

## Coordinators and the keyring

The three coordinators are `@MainActor` state machines (`ObservableObject`)
that drive the app's sheets:

- **Phase 1 `TeleportBootstrapCoordinator`** — generates the ed25519 + TLS
  keypairs, derives the headless ID, starts the blocking POST, opens Safari,
  and stores the issued cert + cluster TLS state. On success it exposes a
  `BootstrapResult` (cert + TLS private key + cluster CA bundle).
- **Phase 2 `TeleportRegistrationCoordinator`** — dials the auth service with
  the bootstrap cert, runs the Browser MFA ceremony (or the first-device
  fallback), creates the SEP key, builds the WebAuthn registration response,
  and calls `AddMFADeviceSync`.
- **Phase 3 `TeleportLoginCoordinator`** — loads the registered SEP key, runs
  `login/begin` + `login/finish`, and stores the new cert.

`TeleportKeyRing` is the per-cluster credential owner: UserDefaults holds the
metadata + certs + cluster TLS state (via an injected store), the keychain
holds the ed25519 private key, and the SEP key itself lives in the Secure
Enclave. Readiness is derived locally through
`TeleportDeviceReadinessResolver`; the Host CA key refresh is additions-only
(`TeleportHostKeyUpdatePolicy`).

## Concurrency invariants

**Pump invariants (`SSHTLSTransport`).** The transport is an `actor`; the pump
runs on a detached task and its read/write loops are `nonisolated` so a
blocking socket call never hops onto (and stalls) the actor. The socketpair
ends are `O_NONBLOCK`; the pump loops yield cooperatively on `EAGAIN` rather
than blocking a cooperative-pool thread. FD ownership: the pump owns `pumpFD`
and closes it on teardown; the libssh2-facing FD is owned by the host's
`AtomicSocket` (closed after `libssh2_session_free`) — the transport must not
double-close it.

**`BrowserMFAListener`.** `nonisolated` + `@unchecked Sendable`: every piece
of mutable state is guarded by `stateLock`, and Network callbacks run on a
private serial queue. The RNG/key-source contract fails closed, and the
listener resolves exactly once.

**`@unchecked Sendable` / MainActor-bound types (D14).**

| Type | Discipline |
| --- | --- |
| `TeleportGRPCConnection` | `@unchecked Sendable`; NIO channel + multiplexer are thread-safe; identity deletion is lock-guarded |
| `TeleportKeychainConfig` | `@unchecked Sendable`; carries an injected `UserDefaults` (thread-safe) |
| `BootstrapResult`, `TLSKeyPair`, `GRPCClientIdentity` | **not** `Sendable`; MainActor-bound (they hold `SecKey`/CF refs). `GRPCClientIdentity` also owns the lock-guarded static label registry, and its `sec_identity_t` handle is consumed on the connection's queue |
| `TeleportKeyRing`, the coordinators, the mocks | `@MainActor`-isolated (global-actor classes are implicitly `Sendable`) |

**`nonisolated deinit` convention.** Every MainActor-isolated class that can
be released synchronously — `TeleportWebAuthnBuilder`, `TeleportGRPCConnection`,
`BrowserMFACeremony`, `SecureEnclaveSigner`, and the 8 `TeleportTesting` test
doubles (12 classes) — declares an empty `nonisolated deinit {}`.
The compiler-synthesized deinit of a MainActor class takes the back-deployed
isolated-deinit path, which aborts (invalid free) when the last reference drops
outside a task context (swiftlang/swift#85663, #88036). The empty body is
deliberate: it changes which deinit path is emitted, not behavior.

**Swift 6 isolation.** Every target uses `.defaultIsolation(MainActor.self)`
(see [`SPEC.md`](SPEC.md)). Declarations the default does not cover are marked
`nonisolated` and are pure or thread-safe: `TeleportTLSTrust`,
`TeleportLogging`/`DefaultTeleportLogging.logger(category:)`, the generated
protobuf declarations, `TLSKeyPair`, the `Data` base64url helpers, and
`BrowserMFAListener`. XCTest suites are `nonisolated final class` with
`@MainActor` test methods because `XCTestCase`'s inherited initializers are
nonisolated.
