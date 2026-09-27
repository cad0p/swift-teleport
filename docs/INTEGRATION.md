# Integration

How a host app consumes `swift-teleport`.

## Adding the dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/cad0p/swift-teleport.git", from: "0.2.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "TeleportCore", package: "swift-teleport"),
        .product(name: "TeleportAuth", package: "swift-teleport"),
    ]),
    .testTarget(name: "MyAppTests", dependencies: [
        .product(name: "TeleportTesting", package: "swift-teleport"),
    ]),
]
```

The host (`cad0p/vvterm`) pins the package by `exactVersion` in its Xcode
project (D7).

## Implementing the seam

The package declares the protocols; the host supplies the implementations at
its composition root:

1. **`TeleportLogging`** — an adapter that preserves the app's `os.Logger`
   subsystem (bundle id) and the existing category strings, so the diagnostics
   export (which filters by `subsystem == bundleID`) keeps working.
2. **`TeleportCredentialStore`** — the host keyring (`TeleportKeyRing`),
   exposed directly or through a MainActor-hop adapter. The seam includes
   `liveCredentialSnapshot(for:)`, the one-read cert + paired ed25519 key the
   connect path resolves the SSH username against. The host also wires
   `TeleportCredentialInvalidating` (the keyring conforms) into
   `ServerManager`, which applies `TeleportCredentialInvalidationPolicy` on
   row edits / CloudKit merges / deletes.
3. **`BrowserMFAPresenting` / `WebAuthenticationSessionPresenting`** — own
   `ASWebAuthenticationSession`, the `vvterm` callback scheme, and the
   presentation anchor.
4. **`TeleportHTTPClienting` / `TeleportGRPCClienting` /
   `BrowserMFACeremonyRunning`** — the host's live adapters
   (`LiveTeleportHTTPClient`, `LiveTeleportGRPCClient`,
   `LiveBrowserMFACeremony`).
5. **`TeleportChannelTransportFactory`** — the host-side libssh2 channel
   bridge (`SSHProxySubsystemTransport` + `SessionMutex`). Cancellation must
   stay synchronous (`cancelPumpSync()`), because it is called before the
   outer libssh2 session is freed.

The host keeps ownership of the libssh2 session and the libssh2-facing FD:
`SSHTLSTransport.connect()` returns the FD, and the host's `AtomicSocket`
closes it after `libssh2_session_free` (the transport closes only its pump
end).

The host's observation protocol (`TeleportKeyRingStoring`) stays host-side;
`TeleportKeyRing` conforms to the plain `TeleportCredentialStore` seam, so
the host restores the observation conformance by extension:

```swift
extension TeleportKeyRing: TeleportKeyRingStoring {}
```

## Using the transport

```swift
import TeleportCore

let transport = SSHTLSTransport(
    host: cluster.host,
    port: cluster.port,
    clusterName: tlsState.clusterName,
    clusterCAPEMs: tlsState.clusterCAPEMs,
    logging: appLogging
)
let fd = try await transport.connect()
// libssh2_session_handshake(session, fd) …
await transport.close()
```

## Using the coordinators

```swift
import TeleportAuth

let keyRing = TeleportKeyRing(logging: appLogging, config: .vvterm)
let bootstrap = TeleportBootstrapCoordinator(
    httpClient: LiveTeleportHTTPClient(),
    keyRing: keyRing,
    safariPresenter: WebAuthenticationSessionPresenter.shared,
    logging: appLogging,
    signer: SecureEnclaveSigner()
)
await bootstrap.begin(cluster: cluster)
```

The `TeleportComposition`-shaped factory set (one coordinator per sheet
presentation; the keyring, logging, and presenter shared) is the reference
integration. `Fixtures/HostSurfaceCheck/Sources/HostSurfaceCheck/HostSurfaceMirrors.swift`
mirrors it as a compile-time contract in a separate package (so it sees only
`public`).

## Error mapping

The package throws `TeleportPackageError` (transport/keychain) and its own
flow errors (`HeadlessError`, `GRPCError`, `SignerError`,
`TeleportBootstrapError`/`TeleportLoginError`/`TeleportRegistrationError`,
`TeleportHostLoginFailure`).
The host maps `TeleportPackageError` back to its own `SSHError` /
`KeychainError` at the seam boundary so existing `error as? SSHError`
classification (disconnect-before-retry, diagnostics rendering) keeps
working. The user-visible descriptions are byte-identical
(`connectionFailed` → "Connection failed: …", `keychain` → "Keychain error: …").

The host's `SSHClient` maps a `TeleportHostLoginFailure` to its
`SSHError.teleportHostLoginUnresolvable` (an app-only case) and renders the
failure into logs/diagnostics through `caseDescription` — never the principal
array, which is identity material. The user-facing text is
`errorDescription`. Reflection on the failure (`dump`/`Mirror`) also renders
the case name only: the enum's `CustomReflectable` mirror carries a single
`case` child, not the associated principals.

## Host-login (SSH username) adoption

The connect path must send a certificate principal, not the Teleport user
(Teleport's `CertChecker` rejects a username outside the cert's
`ValidPrincipals`). Phase 2 adoption:

- resolve with `TeleportHostLogin.resolve(cert:storedLogin:)` against the
  exact PEM read via `liveCredentialSnapshot`; a failure clears the credential
  and fails closed;
- conform `Server` to `TeleportCredentialReuseRow` and delegate
  `Server.normalizedTeleportHostLogin` to `TeleportHostLogin.normalized(_:)`;
- drive the setup picker from `TeleportLoginState.success(…, logins:)` with
  `TeleportHostLogin.initialSelection(logins:stored:)`;
- bind `cert.keyID == cluster.username` at every issue site (the coordinators
  already do it; the host's connect path re-checks it).

## What the package provides

The full D5 product set: the `TeleportCore` seam + transports + gRPC/protobuf
+ WebAuthn/SEP, the `TeleportAuth` coordinators + keyring + web-api client,
and the `TeleportTesting` mocks. A host can run the Phase-1 headless
bootstrap, Phase-2 SEP registration, and Phase-3 passwordless login against a
real cluster.

Out of scope (host-side by design): the libssh2 channel bridge, the SwiftUI
surfaces, the UI-test harnesses, the `teleport-e2e` legs, and the device
smoke (SEP hardware custody + the headless-POST backgrounding path).

## Upstream contact

This package is community-led and **not affiliated with Gravitational**. The
host's integration into `cad0p/vvterm` is the reference consumer; upstream
contact (Phase 3) is owner-led.
