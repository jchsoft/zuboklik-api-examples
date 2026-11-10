# Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
# Runs on plain Python 3.9+, no packages.  Usage:  ZUBOKLIK_API_KEY=... python3 patients.py

import json
import os
import urllib.error
import urllib.request

API_URL = os.environ.get("ZUBOKLIK_API_URL", "https://zuboklik.cz/api/v1")
API_KEY = os.environ["ZUBOKLIK_API_KEY"]


class ApiError(Exception):
    """Raised for every non-2xx answer. `errors` is the parsed "errors" array of the response."""

    def __init__(self, status, errors):
        super().__init__(f"HTTP {status}: {errors}")
        self.status = status
        self.errors = errors


def api(method, path, body=None, key=API_KEY):
    """One request. Returns the parsed JSON body (None for 204 No Content)."""
    request = urllib.request.Request(
        API_URL + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Accept": "application/json", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as error:
        text = error.read().decode()
        raise ApiError(error.code, json.loads(text).get("errors", []) if text else []) from None
    return json.loads(text) if text else None


# 1. Create two patients.
jana = api("POST", "/patients", {"patient": {"first_name": "Jana", "last_name": "Ukázková", "phone_number": "+420777111222"}})["patient"]
petr = api("POST", "/patients", {"patient": {"first_name": "Petr", "last_name": "Ukázkový", "email": "petr.ukazkovy@example.com"}})["patient"]
print(f"1. Patients created: {jana['first_name']} {jana['last_name']} and {petr['first_name']} {petr['last_name']}")

# 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
patients = []
page = 1
while True:
    listing = api("GET", f"/patients?page={page}&per_page=100")
    patients += listing["patients"]
    if page >= listing["meta"]["total_pages"]:
        break
    page += 1
ours = sum(patient["id"] in (jana["id"], petr["id"]) for patient in patients)
print(f"2. Patients listed: {len(patients)} on {page} page(s), ours among them: {ours}")

# 3. Read one patient.
detail = api("GET", f"/patients/{jana['id']}")["patient"]
print(f"3. Patient read: {detail['first_name']} {detail['last_name']}")

# 4. Update: only the attributes you send change.
updated = api("PATCH", f"/patients/{jana['id']}", {"patient": {"email": "jana.ukazkova@example.com"}})["patient"]
print(f"4. Patient updated: {updated['email']}, still {updated['last_name']}")

# 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
api("DELETE", f"/patients/{jana['id']}")
api("DELETE", f"/patients/{petr['id']}")
print("5. Patients deactivated")

# 6. A deactivated (or unknown) patient answers 404.
try:
    api("GET", f"/patients/{jana['id']}")
    raise SystemExit("the API still returns a deactivated patient")
except ApiError as error:
    print(f"6. Deactivated patient not found: HTTP {error.status}, {error.errors[0]['name']}")

# 7. A wrong key answers 401.
try:
    api("GET", "/patients", key="not-a-valid-key")
    raise SystemExit("the API accepted a wrong key")
except ApiError as error:
    print(f"7. Wrong key refused: HTTP {error.status}, {error.errors[0]['name']}")
