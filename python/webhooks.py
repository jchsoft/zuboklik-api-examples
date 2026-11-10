# Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
# Runs on plain Python 3.9+, no packages.  Usage:  ZUBOKLIK_API_KEY=... python3 webhooks.py
# How to verify what the webhook then receives: verify_webhook.py.

import json
import os
import urllib.error
import urllib.request

API_URL = os.environ.get("ZUBOKLIK_API_URL", "https://zuboklik.cz/api/v1")
API_KEY = os.environ["ZUBOKLIK_API_KEY"]
WEBHOOK_URL = "https://example.com/zuboklik-webhook"  # your endpoint; must be https and publicly reachable


class ApiError(Exception):
    """Raised for every non-2xx answer. `errors` is the parsed "errors" array of the response."""

    def __init__(self, status, errors):
        super().__init__(f"HTTP {status}: {errors}")
        self.status = status
        self.errors = errors


def api(method, path, body=None):
    """One request. Returns the parsed JSON body (None for 204 No Content)."""
    request = urllib.request.Request(
        API_URL + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {API_KEY}", "Accept": "application/json", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as error:
        text = error.read().decode()
        raise ApiError(error.code, json.loads(text).get("errors", []) if text else []) from None
    return json.loads(text) if text else None


def active_count():
    return sum(webhook["status"] == "active" for webhook in api("GET", "/webhooks")["webhooks"])


# 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
registered = api("POST", "/webhooks", {"webhook": {"url": WEBHOOK_URL}})
webhook = registered["webhook"]
print(f"1. Webhook registered: {webhook['url']} ({webhook['status']}, secret of {len(registered['secret'])} characters)")

# 2. List the webhooks of this connected system.
print(f"2. Webhooks listed: {active_count()} active")

# 3. A URL that is not https (or points to a private address) is refused with 422.
try:
    api("POST", "/webhooks", {"webhook": {"url": "http://example.com/zuboklik-webhook"}})
    raise SystemExit("the API accepted a plain http URL")
except ApiError as error:
    print(f"3. Plain http refused: HTTP {error.status}, attribute {error.errors[0]['attribute']}")

# 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
api("DELETE", f"/webhooks/{webhook['id']}")
print(f"4. Webhook switched off, {active_count()} active")
