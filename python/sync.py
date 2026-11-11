# Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
# survive a repeated request, and read "what changed since last time" (deletions included).
# Runs on plain Python 3.9+, no packages.  Usage:  ZUBOKLIK_API_KEY=... python3 sync.py

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

API_URL = os.environ.get("ZUBOKLIK_API_URL", "https://zuboklik.cz/api/v1")
API_KEY = os.environ["ZUBOKLIK_API_KEY"]
# Where to start reading changes. A real integration stores the cursor of the last change it processed
# and never needs this; the example starts "now" unless told otherwise.
SINCE = os.environ.get("ZUBOKLIK_SYNC_SINCE") or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
EXTERNAL_ID = "example-patient-1"  # the id of this patient in YOUR system


class ApiError(Exception):
    """Raised for every non-2xx answer. `errors` is the parsed "errors" array, `body` the whole parsed response."""

    def __init__(self, status, body):
        self.status = status
        self.body = body or {}
        self.errors = self.body.get("errors", [])
        super().__init__(f"HTTP {status}: {self.errors}")


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
        raise ApiError(error.code, json.loads(text) if text else None) from None
    return json.loads(text) if text else None


def apply(change):
    """What your system does with one change. A webhook delivery has the same fields, so the same code handles both.

    Returns a line describing what was done.
    """
    collection = "patients" if change["resource_type"] == "Patient" else "entries"
    if change["action"] == "destroy":
        return f"{change['event']}: removed from our system"
    try:
        api("GET", f"/{collection}/{change['resource_id']}")  # the current state of the record; save it on your side
        return f"{change['event']}: saved to our system"
    except ApiError as error:
        if error.status != 404:
            raise
        return f"{change['event']}: already gone, removed from our system"  # deleted again before we asked


new_patient = {"patient": {"first_name": "Eva", "last_name": "Ukázková", "phone_number": "+420777111222", "external_id": EXTERNAL_ID}}

# 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
#    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
found = api("GET", f"/patients?external_id={EXTERNAL_ID}")["patients"]
patient = found[0] if found else api("POST", "/patients", new_patient)["patient"]
print(f"1. Patient paired: {patient['first_name']} {patient['last_name']}, external_id {patient['external_id']}")

# 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
try:
    api("POST", "/patients", new_patient)
    raise SystemExit("the API created the same patient twice")
except ApiError as error:
    same = error.body.get("patient", {}).get("id") == patient["id"]
    print(f"2. Repeated request created nothing: HTTP {error.status}, {error.errors[0]['name']}, same patient: {str(same).lower()}")

# 3. From now on find the record by your own id.
found = api("GET", f"/patients?external_id={EXTERNAL_ID}")["patients"]
print(f"3. Found by external_id: {len(found)} patient(s)")

# 4. What changed in the practice since last time? Page by cursor until `more` is false.
#    Changes made by this key are left out; you see what the staff, the patients and other systems did.
applied = []
query = f"since={urllib.parse.quote(SINCE, safe='')}"
while True:
    page = api("GET", f"/changes?{query}")
    applied += [apply(change) for change in page["changes"]]
    if not page["meta"]["more"]:
        break
    query = f"after={page['meta']['next_cursor']}"  # store this cursor; next time start from it
print(f"4. Changes from the practice: {len(applied)}")
for line in applied:
    print(f"   {line}")

# 5. Clean up: give the external_id back, then deactivate the patient.
api("PATCH", f"/patients/{patient['id']}", {"patient": {"external_id": None}})
api("DELETE", f"/patients/{patient['id']}")
print("5. Cleaned up")
