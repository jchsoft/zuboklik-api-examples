// Zuboklik API example: verify the signature of an incoming webhook.
// C++17 with OpenSSL and nlohmann/json.  Usage:  cmake -B build && cmake --build build && ./build/verify_webhook

#include <cstdlib>
#include <ctime>
#include <fstream>
#include <iostream>
#include <string>

#include <nlohmann/json.hpp>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>

const long long MAX_AGE = 300; // seconds; older deliveries are refused (replay protection)

// secret    - the secret returned once by POST /api/v1/webhooks
// timestamp - the X-Zuboklik-Timestamp header
// body      - the raw request body, exactly as received (do not re-serialize the JSON)
// signature - the X-Zuboklik-Signature header, "sha256=<hex>"
bool valid_webhook(const std::string& secret, const std::string& timestamp, const std::string& body,
                   const std::string& signature, long long now = std::time(nullptr)) {
    if (std::llabs(now - std::stoll(timestamp)) > MAX_AGE) return false;

    const std::string signed_text = timestamp + "." + body;
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    HMAC(EVP_sha256(), secret.data(), static_cast<int>(secret.size()),
         reinterpret_cast<const unsigned char*>(signed_text.data()), signed_text.size(), digest, &length);

    static const char* hex = "0123456789abcdef";
    std::string expected = "sha256=";
    for (unsigned int i = 0; i < length; i++) {
        expected += hex[digest[i] >> 4];
        expected += hex[digest[i] & 0x0f];
    }
    // CRYPTO_memcmp compares in constant time.
    return expected.size() == signature.size() && CRYPTO_memcmp(expected.data(), signature.data(), expected.size()) == 0;
}

int main() {
    std::ifstream file("../test-vectors/webhook.json");
    if (!file) {
        std::cerr << "run from the cpp directory\n";
        return 1;
    }
    const auto vector = nlohmann::json::parse(file);
    const std::string secret = vector["secret"], timestamp = vector["timestamp"], body = vector["body"], signature = vector["signature"];
    const long long now = std::stoll(timestamp) + 10;

    std::string tampered = body;
    tampered.replace(tampered.find("4711"), 4, "4712");

    std::cout << std::boolalpha;
    std::cout << "valid signature accepted: " << valid_webhook(secret, timestamp, body, signature, now) << "\n";
    std::cout << "tampered body rejected: " << !valid_webhook(secret, timestamp, tampered, signature, now) << "\n";
    std::cout << "stale timestamp rejected: " << !valid_webhook(secret, timestamp, body, signature, now + 3600) << "\n";
}
