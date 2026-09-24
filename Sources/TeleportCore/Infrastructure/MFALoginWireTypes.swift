// SPDX-License-Identifier: MIT
//
//  MFALoginWireTypes.swift
//  VVTerm
//
//  The HTTP wire types for /webapi/mfa/login/begin and /webapi/mfa/login/finish.
//  Copied verbatim from the 1.6b sep-biometry-iotest app
//  (SEPBiometryTestRunner.swift:284-352) so the Phase 3 login flow is
//  byte-identical to 1.6b's proven path.
//
//  These are JSON wire types (not protobuf) — the login flow uses the HTTP
//  webapi, not gRPC.
//

import Foundation

// MARK: - login/begin response

public struct LoginBeginResponse: Decodable {
    public let webauthnChallenge: WebauthnAssertion?
    enum CodingKeys: String, CodingKey {
        case webauthnChallenge = "webauthn_challenge"
    }

    public init(webauthnChallenge: WebauthnAssertion?) {
        self.webauthnChallenge = webauthnChallenge
    }

    public struct WebauthnAssertion: Decodable {
        public let publicKey: PublicKey

        public init(publicKey: PublicKey) {
            self.publicKey = publicKey
        }

        public struct PublicKey: Decodable {
            public let challenge: String
            public let rpId: String?
            enum CodingKeys: String, CodingKey {
                case challenge
                case rpId = "rpId"
            }

            public init(challenge: String, rpId: String?) {
                self.challenge = challenge
                self.rpId = rpId
            }
        }
    }
}

// MARK: - login/finish response

public struct LoginFinishResponse: Decodable {
    public let cert: String?
    public let hostSigners: [HostSigner]?
    enum CodingKeys: String, CodingKey {
        case cert
        case hostSigners = "host_signers"
    }

    public init(cert: String?, hostSigners: [HostSigner]?) {
        self.cert = cert
        self.hostSigners = hostSigners
    }

    public struct HostSigner: Decodable {
        public let domainName: String
        /// The Host CA SSH public keys as authorized_keys lines. The wire
        /// value is base64(authorized_keys line), decoded here.
        public let checkingKeys: [String]
        enum CodingKeys: String, CodingKey {
            case domainName = "domain_name"
            case checkingKeys = "checking_keys"
        }

        public init(domainName: String, checkingKeys: [String]) {
            self.domainName = domainName
            self.checkingKeys = checkingKeys
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            domainName = try container.decode(String.self, forKey: .domainName)
            let base64Keys = try container.decodeIfPresent([String].self, forKey: .checkingKeys) ?? []
            checkingKeys = TeleportHostCACheckingKeysDecoder.decodeAll(base64Keys)
        }
    }
}

// MARK: - login/finish request

public struct LoginFinishReq: Encodable {
    public let webauthnChallengeResponse: CredentialAssertionResponse
    public let sshPubKey: Data
    public let pubKey: Data
    public let ttl: Int64
    enum CodingKeys: String, CodingKey {
        case webauthnChallengeResponse = "webauthn_challenge_response"
        case sshPubKey = "ssh_pub_key"
        // v16-era proxies read `pub_key` ([]byte) and ignore `ssh_pub_key`
        // (introduced in v17); v17 prefers `ssh_pub_key` and still accepts
        // the deprecated `pub_key`. Send both so the login/finish ceremony
        // works against both server generations.
        case pubKey = "pub_key"
        case ttl
    }

    public init(
        webauthnChallengeResponse: CredentialAssertionResponse,
        sshPubKey: Data,
        pubKey: Data,
        ttl: Int64
    ) {
        self.webauthnChallengeResponse = webauthnChallengeResponse
        self.sshPubKey = sshPubKey
        self.pubKey = pubKey
        self.ttl = ttl
    }
}
