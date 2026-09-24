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

## gRPC / protobuf

| Teleport protocol / route | This package |
| --- | --- |
| Auth-service mTLS over ALPN-SNI `teleport-auth@<hex(cluster)>` + `h2` | `GRPCTLSOptions.make`, `TeleportGRPCConnection.connect` |
| HTTP/2 framing + gRPC unary calls (`POST /proto.AuthService/<Method>`) | `GRPCClient.grpcUnaryCall(Typed)`, `TeleportGRPCConnection.unary` |
| `AuthService/CreateAuthenticateChallenge` (MANAGE_DEVICES scope + BrowserMFA redirect) | `Proto_CreateAuthenticateChallengeRequest`/`Proto_MFAAuthenticateChallenge` |
| `AuthService/CreateRegisterChallenge` (WEBAUTHN + PASSWORDLESS) | `Proto_CreateRegisterChallengeRequest`/`Proto_MFARegisterChallenge` |
| `AuthService/AddMFADeviceSync` (ContextUser cert auth) | `Proto_AddMFADeviceSyncRequest` |
| Browser MFA challenge/response (`/web/mfa/browser/<request_id>`) | `Proto_BrowserMFAChallenge`/`Proto_BrowserMFAResponse`, `BrowserMFACeremony`, `BrowserMFAListener` |
| WebAuthn credential creation/assertion wire JSON | `WebAuthn.register`/`login`, `CredentialCreationResponse`/`CredentialAssertionResponse` |

The IDL is the committed `Sources/TeleportCore/Infrastructure/iotest_mfa.proto`;
the generated `iotest_mfa.pb.swift` is `Visibility=Public` and patched
`nonisolated` (see the regen script). The message/field numbers are the wire
contract; `ProtoWireCompatTests` pins golden bytes captured from the
pre-rewrite IDL.

## Headless + web-api

| Teleport route | This package |
| --- | --- |
| Headless auth ID (`services.NewHeadlessAuthenticationID`) | `HeadlessID.compute(sshAuthorizedKey:)` — UUIDv5 layout with SHA-256, 16-zero-byte namespace, one trailing `\n` |
| `POST /webapi/headless/login` (blocking, ~180 s) | `HeadlessLogin.post`, `TeleportTrustSession.session` (200 s timeouts) |
| `GET /webapi/ping` | `TeleportHTTPClient.ping` |
| `POST /webapi/mfa/login/begin` + `/finish` | `TeleportHTTPClient.loginBegin`/`loginFinish`, `LoginBeginResponse`/`LoginFinishResponse`/`LoginFinishReq` |
| `tls_cert`/`cert`/`checking_keys` base64 `[]byte` wire shape | `HeadlessLoginResponse`, `TeleportHostCACheckingKeysDecoder` |
