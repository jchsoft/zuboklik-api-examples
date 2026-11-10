// Zuboklik API example: verify the signature of an incoming webhook.
// Runs on Swift 5.9+ on macOS (CryptoKit).  Usage:  swift verify_webhook.swift

import CryptoKit
import Foundation

let maxAge = 300 // seconds; older deliveries are refused (replay protection)

// secret    - the secret returned once by POST /api/v1/webhooks
// timestamp - the X-Zuboklik-Timestamp header
// body      - the raw request body, exactly as received (do not re-serialize the JSON)
// signature - the X-Zuboklik-Signature header, "sha256=<hex>"
func validWebhook(secret: String, timestamp: String, body: String, signature: String,
                  now: Int = Int(Date().timeIntervalSince1970)) -> Bool {
    guard let sent = Int(timestamp), abs(now - sent) <= maxAge,
          signature.hasPrefix("sha256="),
          let received = Data(hex: String(signature.dropFirst("sha256=".count))) else { return false }

    // isValidAuthenticationCode compares in constant time.
    return HMAC<SHA256>.isValidAuthenticationCode(received, authenticating: Data("\(timestamp).\(body)".utf8),
                                                  using: SymmetricKey(data: Data(secret.utf8)))
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../test-vectors/webhook.json")
let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
let (secret, timestamp, body, signature) = (vector["secret"]!, vector["timestamp"]!, vector["body"]!, vector["signature"]!)
let now = Int(timestamp)! + 10

print("valid signature accepted: \(validWebhook(secret: secret, timestamp: timestamp, body: body, signature: signature, now: now))")
print("tampered body rejected: \(!validWebhook(secret: secret, timestamp: timestamp, body: body.replacingOccurrences(of: "4711", with: "4712"), signature: signature, now: now))")
print("stale timestamp rejected: \(!validWebhook(secret: secret, timestamp: timestamp, body: body, signature: signature, now: now + 3600))")
