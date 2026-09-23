# Architecture

## Layout

```
Sources/TeleportCore/
├── Domain/          pure types + rules (no I/O)
│   ├── BrowserMFAPresenting.swift      seam: in-app browser presenter
│   ├── HostKeyTrustPolicy.swift        pure host-key trust decision
│   ├── OpenSSHCertificate.swift        OpenSSH cert wire-format parser
│   ├── OpenSSHHostCertVerifier.swift   host-cert → Host CA verification
│   ├── TeleportChannelTransport.swift  seam: libssh2 channel bridge protocols
│   ├── TeleportCluster.swift           cluster config model
│   ├── TeleportClusterTLSState.swift   persisted cluster trust anchors
│   ├── TeleportCredential.swift        registered SEP key + cert metadata
│   ├── TeleportCredentialStore.swift   seam: credential store protocol
│   ├── TeleportDeviceName.swift        MFA device-name sanitization
│   ├── TeleportDeviceReadiness.swift   derived readiness resolver
│   ├── TeleportKeychainConfig.swift    keychain service + defaults injection
│   ├── TeleportLogging.swift           seam: os.Logger factory
│   └── TeleportPackageError.swift      package-owned error type
├── Application/
│   └── SSHCertExpiryParser.swift       cert ValidBefore extraction
└── Infrastructure/
    ├── SSHTLSTransport.swift           TLS+ALPN transport (actor + pump)
    ├── TeleportProxySubsystem.swift    proxy subsystem string builder
    └── TeleportTLSTrust.swift          TLS chain/name/EKU verification
```

The `Domain` / `Application` / `Infrastructure` split mirrors the host
repository's feature-first architecture. `Domain` holds pure types and rules;
`Infrastructure` holds the transports; nothing in `Domain` imports
`Infrastructure`.

## The D6 seam

The package cannot own the host app's keychain, logging subsystem, or browser
presentation. Instead it declares narrow protocols that the host implements at
its composition root:

| Protocol | Host responsibility |
| --- | --- |
| `TeleportCredentialStore` | per-cluster cert/key/TLS-state persistence |
| `TeleportLogging` | `os.Logger` factory (preserves the app subsystem + category strings) |
| `BrowserMFAPresenting` / `BrowserMFASessionHandle` | `ASWebAuthenticationSession` + presentation anchor |
| `TeleportSessionMutex` / `TeleportChannelTransport` / `TeleportChannelTransportFactory` | the libssh2 channel bridge |

The libssh2 channel bridge is **host-side by design**: the 14 libssh2 calls and
the `SessionMutex` live in the host, exposed to the package only through
`TeleportChannelTransportFactory`. Cancellation must stay synchronous
(`cancelPumpSync()` is `nonisolated` and non-`async`) so the pump can be
stopped before the outer libssh2 session is freed — an `await` there could
deadlock.

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

## Concurrency invariants

**Pump invariants (`SSHTLSTransport`).** The transport is an `actor`; the pump
runs on a detached task and its read/write loops are `nonisolated` so a
blocking socket call never hops onto (and stalls) the actor. The socketpair
ends are `O_NONBLOCK`; the pump loops yield cooperatively on `EAGAIN` rather
than blocking a cooperative-pool thread. FD ownership: the pump owns `pumpFD`
and closes it on teardown; the libssh2-facing FD is owned by the host's
`AtomicSocket` (closed after `libssh2_session_free`) — the transport must not
double-close it.

**`@unchecked Sendable` (`TeleportKeychainConfig`).** The only `@unchecked`
conformance in the package. It carries an injected `UserDefaults`; `UserDefaults`
is thread-safe, so the conformance is sound. The type never calls
`UserDefaults.standard` or names the app's keychain service — both are injected
by the host.

**Swift 6 isolation.** All three targets use
`.defaultIsolation(MainActor.self)` (see [`SPEC.md`](SPEC.md)). Declarations the
default does not cover are marked `nonisolated` and are pure or thread-safe:
`TeleportTLSTrust` (a pure-function enum), `TeleportLogging.logger(category:)`
and `DefaultTeleportLogging.logger(category:)` (`os.Logger` construction).
