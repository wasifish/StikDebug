//
//  AdRunnerClient.swift
//  StikDebug
//
//  Talks to an iCTRL automation runner running on this same device, over
//  127.0.0.1 only. The runner is a separate app (an XCUITest runner) that can
//  read the screen and tap; this file only sends it requests.
//
//  The pairing and request-envelope code is adapted from OpenMinis/iCTRL
//  (iCTRLApp/Models/RunnerClient.swift and iCTRLKit/SecureEnvelope.swift),
//  licensed under the Apache License 2.0. Changes from the original: merged
//  into one file, renamed, uses its own keychain item, adds a status probe.
//

import CryptoKit
import Foundation
import Security

enum AdRunnerError: LocalizedError, Equatable {
    /// Nothing answers on the port: the runner app is not running.
    case notRunning
    /// No key yet; pair first.
    case notPaired
    /// The runner no longer accepts our key (revoked, expired, reinstalled).
    case keyRejected
    /// The request was refused on the device, or nobody answered in time.
    case pairDenied
    /// Another request is waiting, or one was just refused.
    case pairBusy(retryAfter: Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "The control app is not running.".localized
        case .notPaired:
            return "Not connected to the control app yet.".localized
        case .keyRejected:
            return "The control app no longer accepts this connection. Connect again.".localized
        case .pairDenied:
            return "The connection request was refused or not answered in time.".localized
        case .pairBusy(let seconds):
            return String(format: "The control app is busy. Try again in %lld seconds.".localized, seconds)
        case .server(let message):
            return message
        }
    }
}

final class AdRunnerClient {
    static let shared = AdRunnerClient()

    /// What the runner shows in its approval prompt and client list.
    static let clientName = "StikDebug"
    static let port = 8200

    private struct Record: Codable {
        var key: String   // hex, 32 bytes
        var tok: String   // hex, 4 bytes: the session id on the runner
    }

    private let lock = NSLock()
    private var storedRecord: Record?

    private init() {
        if let data = AdRunnerKeychain.load() {
            storedRecord = try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    private var record: Record? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedRecord
        }
        set {
            lock.lock()
            storedRecord = newValue
            lock.unlock()
        }
    }

    var isPaired: Bool { record != nil }

    func forget() {
        record = nil
        AdRunnerKeychain.clear()
    }

    // MARK: - Status

    /// The runner's version when it answers, nil when nothing is listening.
    func runnerVersion() async -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/schema") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (body?["server_version"] as? String) ?? (body?["version"] as? String) ?? "?"
    }

    // MARK: - Pairing

    /// Ask the runner for a key. Waits until the user answers the runner's
    /// notification, or it times out (60 s on the runner side).
    func pair() async throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let (status, body) = try await post("/pair", json: [
            "client_name": Self.clientName,
            "pub": publicKey.base64EncodedString(),
        ], timeout: 90)

        switch status {
        case 200:
            break
        case 403:
            throw AdRunnerError.pairDenied
        case 429:
            let error = body["error"] as? [String: Any]
            let wait = (error?["retry_after"] as? Int) ?? (body["retry_after"] as? Int) ?? 15
            throw AdRunnerError.pairBusy(retryAfter: wait)
        default:
            throw AdRunnerError.server(Self.message(body, status: status))
        }

        guard let devicePublicBase64 = body["pub"] as? String,
              let devicePublic = Data(base64Encoded: devicePublicBase64),
              let wrappedHex = body["token_ct"] as? String,
              let wrapped = Data(adHex: wrappedHex), wrapped.count == 32 else {
            throw AdRunnerError.server("Malformed pairing response")
        }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublic)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        let wrapKey = AdEnvelope.hmac(shared, Data(AdEnvelope.labelPair.utf8) + publicKey + devicePublic)
        let pad = AdEnvelope.hmac(wrapKey, Data(AdEnvelope.labelWrap.utf8))
        let key = Data(zip(wrapped, pad).map { $0 ^ $1 })

        let newRecord = Record(key: key.adHexString, tok: AdEnvelope.tokenId(for: key))
        record = newRecord
        if let data = try? JSONEncoder().encode(newRecord) {
            AdRunnerKeychain.save(data)
        }
    }

    // MARK: - RPC

    /// One enveloped JSON-RPC call; returns its `result` object.
    func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> [String: Any] {
        guard let current = record,
              let key = Data(adHex: current.key),
              let tok4 = Data(adHex: current.tok),
              let nonce = AdEnvelope.randomBytes(16) else {
            throw AdRunnerError.notPaired
        }

        let request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params, "id": 1]
        let plaintext = try JSONSerialization.data(withJSONObject: request)
        let timestamp = UInt64(Date().timeIntervalSince1970)
        let encryptionKey = AdEnvelope.hmac(key, Data(AdEnvelope.labelEncRequest.utf8) + nonce)
        let macKey = AdEnvelope.hmac(key, Data(AdEnvelope.labelMac.utf8) + nonce)
        let ciphertext = AdEnvelope.keystreamXOR(key: encryptionKey, nonce: nonce, data: plaintext)
        let tag = AdEnvelope.hmac(
            macKey,
            Data("v1".utf8) + tok4 + AdEnvelope.be64(timestamp) + nonce + ciphertext
        )

        let (status, body) = try await post("/rpc", json: [
            "v": 1,
            "tok": current.tok,
            "ts": Int(timestamp),
            "nonce": nonce.adHexString,
            "ct": ciphertext.base64EncodedString(),
            "tag": tag.adHexString,
        ], timeout: timeout)

        if status == 401 {
            // Revoked, expired, or the runner was reinstalled: the key is dead.
            forget()
            throw AdRunnerError.keyRejected
        }
        guard status == 200 else {
            throw AdRunnerError.server(Self.message(body, status: status))
        }

        guard let responseBase64 = body["ct"] as? String,
              let responseCiphertext = Data(base64Encoded: responseBase64),
              let responseTagHex = body["tag"] as? String,
              let responseTag = Data(adHex: responseTagHex),
              AdEnvelope.tagMatches(responseTag,
                                    message: Data("resp".utf8) + nonce + responseCiphertext,
                                    key: macKey) else {
            throw AdRunnerError.server("Response failed verification")
        }
        let responseKey = AdEnvelope.hmac(key, Data(AdEnvelope.labelEncResponse.utf8) + nonce)
        let decoded = AdEnvelope.keystreamXOR(key: responseKey, nonce: nonce, data: responseCiphertext)
        guard let reply = (try? JSONSerialization.jsonObject(with: decoded)) as? [String: Any] else {
            throw AdRunnerError.server("Malformed response")
        }
        if let error = reply["error"] as? [String: Any] {
            throw AdRunnerError.server((error["message"] as? String) ?? "RPC error")
        }
        return (reply["result"] as? [String: Any]) ?? [:]
    }

    // MARK: - HTTP

    private func post(_ path: String, json: [String: Any], timeout: TimeInterval) async throws -> (Int, [String: Any]) {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)\(path)") else {
            throw AdRunnerError.notRunning
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            return (status, body)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet:
                throw AdRunnerError.notRunning
            default:
                throw AdRunnerError.server(error.localizedDescription)
            }
        }
    }

    private static func message(_ body: [String: Any], status: Int) -> String {
        if let error = body["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return "HTTP \(status)"
    }
}

// MARK: - Envelope primitives

/// Protocol v1 primitives, wire-compatible with the iCTRL runner.
///
///     K_enc_req  = HMAC(K, "ictrl-v1|enc-req"  || nonce)
///     K_enc_resp = HMAC(K, "ictrl-v1|enc-resp" || nonce)
///     K_mac      = HMAC(K, "ictrl-v1|mac"      || nonce)
///     ct  = plaintext XOR (HMAC(Kx, nonce || be32(0)) || HMAC(Kx, nonce || be32(1)) || ...)
///     tag = HMAC(K_mac, "v1" || tok_4B || be64(ts) || nonce || ct)
enum AdEnvelope {
    static let labelMac = "ictrl-v1|mac"
    static let labelEncRequest = "ictrl-v1|enc-req"
    static let labelEncResponse = "ictrl-v1|enc-resp"
    static let labelPair = "ictrl-pair"
    static let labelWrap = "ictrl-wrap"

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func tagMatches(_ tag: Data, message: Data, key: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: message, using: SymmetricKey(data: key))
    }

    static func keystreamXOR(key: Data, nonce: Data, data: Data) -> Data {
        var stream = Data(capacity: data.count + 32)
        var counter: UInt32 = 0
        while stream.count < data.count {
            var bigEndian = counter.bigEndian
            stream.append(hmac(key, nonce + Data(bytes: &bigEndian, count: 4)))
            counter += 1
        }
        return Data(zip(data, stream).map { $0 ^ $1 })
    }

    static func be64(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 8)
    }

    /// The lookup id derived from a key: first 4 bytes of SHA256(K), hex.
    static func tokenId(for key: Data) -> String {
        Data(SHA256.hash(data: key)).prefix(4).adHexString
    }

    static func randomBytes(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }
}

// MARK: - Keychain

private enum AdRunnerKeychain {
    private static let service = "com.stik.stikdebug.adrunner"
    private static let account = "runner-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ data: Data) {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - Hex helpers

extension Data {
    init?(adHex hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var adHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
