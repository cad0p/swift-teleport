# Protocol Mapping

## What maps to what

| Teleport protocol / RFD | This package |
| --- | --- |
| SSH over TLS Routing (RFD 39), ALPN `teleport-proxy-ssh` | `SSHTLSTransport`, `TeleportTLSTrust` |
| `proxy:<node>:<port>[@<cluster>]` subsystem (RFD 39 proxy mode) | `TeleportProxySubsystem.request(for:port:cluster:)` |
| Host CA SSH certificates (`host_signers[].checking_keys`) | `OpenSSHHostCertVerifier`, `HostKeyTrustPolicy` |
| OpenSSH certificate wire format (`PROTOCOL.certkeys`) | `OpenSSHCertificate` |
| Cluster TLS anchors (`host_signers[].tls_certs`) | `TeleportTLSTrust`, `TeleportClusterTLSState` |
| `host_signers[].domain_name` | `TeleportClusterTLSState.clusterName` |
| Encoded cluster name (`api/utils/cluster.go:EncodeClusterName`) | `TeleportTLSTrust.encodedClusterName(_:)` |
| Certificate ValidBefore | `SSHCertExpiryParser.validBefore(pem:)` |

## gRPC / protobuf — arrives in v0.2.0

**The `v0.1.0` skeleton ships no proto and no protobuf/gRPC mapping.** The
gRPC auth transport (`GRPCClient`, `GRPCTransport`), the committed
`iotest_mfa.pb.swift`, the `iotest_mfa.proto` IDL, and the proto regeneration
script are all deferred to `v0.2.0`.

That work needs the ALPN auth route (`teleport-auth@<hex(cluster)>`) and the
SwiftNIO + SwiftProtobuf dependency set — the package is intentionally
zero-dependency in `v0.1.0`, so the NIO/protobuf files are held back. The
mapping helpers that the gRPC leg will use (`TeleportTLSTrust.authServerNames`,
`encodedClusterName`, `makeVerifyBlock`) are already present and public.

See [`PROVENANCE.md`](PROVENANCE.md) for the full deferred inventory.
