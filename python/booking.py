# Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
# Runs on plain Python 3.9+, no packages.  Usage:  ZUBOKLIK_API_KEY=... python3 booking.py

import json
import os
import urllib.error
import urllib.request
from datetime import date, timedelta

API_URL = os.environ.get("ZUBOKLIK_API_URL", "https://zuboklik.cz/api/v1")
API_KEY = os.environ["ZUBOKLIK_API_KEY"]


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


def find_by_code(items, code):
    return next(item for item in items if item["code"] == code)


def slot(item):
    """'2026-11-24 09:00-09:30' from anything that has booked_for, start_time and end_time."""
    return f"{item['booked_for']} {item['start_time'][11:16]}-{item['end_time'][11:16]}"


# 1. Check the connection and the key.
print(f"1. API is up ({api('GET', '')['version']})")

# 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
symptom = find_by_code(api("GET", "/symptoms")["symptoms"], "without_complications")
entry_type = find_by_code(api("GET", "/entry_types")["entry_types"], "prevention")
state = find_by_code(api("GET", "/entry_states")["entry_states"], "reserved")
print(f"2. Catalogs loaded: symptom {symptom['code']}, type {entry_type['code']}, state {state['code']}")

# 3. Create a patient.
patient = api("POST", "/patients", {"patient": {
    "first_name": "Jan", "last_name": "Ukázkový", "phone_number": "+420777111222", "email": "jan.ukazkovy@example.com",
}})["patient"]
print(f"3. Patient created: {patient['first_name']} {patient['last_name']}")

# 4. Ask for free 30-minute slots in the next 30 days.
start = date.today() + timedelta(days=1)
vacancies = api("GET", f"/vacancies?from={start}&to={start + timedelta(days=30)}&duration=30")["vacancies"]
if len(vacancies) < 2:
    raise SystemExit("the practice has fewer than two free slots in the next 30 days")
first, second = vacancies[:2]
print(f"4. Free slots found: {slot(first)} and {slot(second)}")

# 5. Book the first one.
times = ("booked_for", "start_time", "end_time")
entry = api("POST", "/entries", {"entry": {
    "entry_type_id": entry_type["id"], "entry_state_id": state["id"],
    **{key: first[key] for key in times},
    "note": "Booked by the API example",
    "patient_symptoms_attributes": [{"patient_id": patient["id"], "symptom_id": symptom["id"]}],
}})["entry"]
print(f"5. Appointment booked: {slot(entry)}")

# 6. Move it to the second one.
entry = api("PATCH", f"/entries/{entry['id']}", {"entry": {key: second[key] for key in times}})["entry"]
print(f"6. Appointment moved: {slot(entry)}")

# 7. Errors: a patient without a last name is refused with 422 and a list of reasons.
try:
    api("POST", "/patients", {"patient": {"first_name": "Jan"}})
    raise SystemExit("the API accepted an invalid patient")
except ApiError as error:
    print(f"7. Invalid patient refused: HTTP {error.status}, attribute {error.errors[0]['attribute']}")

# 8. Clean up: delete the appointment, deactivate the patient.
api("DELETE", f"/entries/{entry['id']}")
api("DELETE", f"/patients/{patient['id']}")
print("8. Cleaned up")
