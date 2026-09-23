# Integration

How a host app consumes `swift-teleport`.

## Adding the dependency

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/cad0p/swift-teleport.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "TeleportCore", package: "swift-teleport"),
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
   exposed directly or through a MainActor-hop adapter.
3. **`BrowserMFAPresenting`** — owns `ASWebAuthenticationSession`, the
   `vvterm` callback scheme, and the presentation anchor.
4. **`TeleportChannelTransportFactory`** — the host-side libssh2 channel
   bridge (`SSHProxySubsystemTransport` + `SessionMutex`). Cancellation must
   stay synchronous (`cancelPumpSync()`), because it is called before the
   outer libssh2 session is freed.

The host keeps ownership of the libssh2 session and the libssh2-facing FD:
`SSHTLSTransport.connect()` returns the FD, and the host's `AtomicSocket`
closes it after `libssh2_session_free` (the transport closes only its pump
end).

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

## Error mapping

The package throws `TeleportPackageError`. The host maps it back to its own
`SSHError` / `KeychainError` at the seam boundary so existing
`error as? SSHError` classification (disconnect-before-retry, diagnostics
rendering) keeps working. The user-visible descriptions are byte-identical
(`connectionFailed` → "Connection failed: …", `keychain` → "Keychain error: …").

## What v0.1.0 does not provide

`TeleportAuth` (the gRPC/protobuf login + registration flows), `TeleportTesting`
(mocks), and the keyring are **not** in `v0.1.0`; they arrive in `v0.2.0`. A
host that needs the full bootstrap/login/registration flow should wait for
`v0.2.0` or vendor the deferred files until then.

## Upstream contact

This package is community-led and **not affiliated with Gravitational**. The
host's integration into `cad0p/vvterm` is the reference consumer; upstream
contact (Phase 3) is owner-led.
