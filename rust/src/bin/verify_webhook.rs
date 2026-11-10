// Zuboklik API example: verify the signature of an incoming webhook.
// Usage:  cargo run --quiet --bin verify_webhook

use hmac::{Hmac, Mac};
use sha2::Sha256;

const MAX_AGE: i64 = 300; // seconds; older deliveries are refused (replay protection)

/// secret    - the secret returned once by POST /api/v1/webhooks
/// timestamp - the X-Zuboklik-Timestamp header
/// body      - the raw request body, exactly as received (do not re-serialize the JSON)
/// signature - the X-Zuboklik-Signature header, "sha256=<hex>"
fn valid_webhook(secret: &str, timestamp: &str, body: &str, signature: &str, now: i64) -> bool {
    let Ok(sent) = timestamp.parse::<i64>() else { return false };
    if (now - sent).abs() > MAX_AGE {
        return false;
    }
    let Some(Ok(received)) = signature.strip_prefix("sha256=").map(hex::decode) else { return false };

    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepts a key of any length");
    mac.update(format!("{timestamp}.{body}").as_bytes());
    mac.verify_slice(&received).is_ok() // constant-time comparison
}

fn main() {
    let raw = std::fs::read_to_string("../test-vectors/webhook.json").expect("run from the rust directory");
    let vector: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let field = |name: &str| vector[name].as_str().unwrap().to_string();
    let (secret, timestamp, body, signature) = (field("secret"), field("timestamp"), field("body"), field("signature"));
    let now = timestamp.parse::<i64>().unwrap() + 10; // in a real handler pass the current Unix time

    println!("valid signature accepted: {}", valid_webhook(&secret, &timestamp, &body, &signature, now));
    println!("tampered body rejected: {}", !valid_webhook(&secret, &timestamp, &body.replace("4711", "4712"), &signature, now));
    println!("stale timestamp rejected: {}", !valid_webhook(&secret, &timestamp, &body, &signature, now + 3600));
}
