# Zuboklik API example: verify the signature of an incoming webhook.
# Runs on plain Python 3.9+, no packages.  Usage:  python3 verify_webhook.py

import hashlib
import hmac
import json
import time
from pathlib import Path

MAX_AGE = 300  # seconds; older deliveries are refused (replay protection)


def valid_webhook(secret, timestamp, body, signature, now=None):
    """secret    - the secret returned once by POST /api/v1/webhooks
    timestamp - the X-Zuboklik-Timestamp header
    body      - the raw request body, exactly as received (do not re-serialize the JSON)
    signature - the X-Zuboklik-Signature header, "sha256=<hex>"
    """
    now = int(time.time()) if now is None else now
    if abs(now - int(timestamp)) > MAX_AGE:
        return False

    digest = hmac.new(secret.encode(), f"{timestamp}.{body}".encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(f"sha256={digest}", signature)


vector = json.loads((Path(__file__).parent / ".." / "test-vectors" / "webhook.json").read_text(encoding="utf-8"))
secret, timestamp, body, signature = (vector[key] for key in ("secret", "timestamp", "body", "signature"))
now = int(timestamp) + 10


def show(value):
    return str(value).lower()


print("valid signature accepted:", show(valid_webhook(secret, timestamp, body, signature, now)))
print("tampered body rejected:", show(not valid_webhook(secret, timestamp, body.replace("4711", "4712"), signature, now)))
print("stale timestamp rejected:", show(not valid_webhook(secret, timestamp, body, signature, now + 3600)))
