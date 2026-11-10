#!/usr/bin/env bash
# Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
# Needs curl and jq.  Usage:  ZUBOKLIK_API_KEY=... ./booking.sh

set -euo pipefail

API_URL="${ZUBOKLIK_API_URL:-https://zuboklik.cz/api/v1}"
: "${ZUBOKLIK_API_KEY:?set ZUBOKLIK_API_KEY}"

# One request: request METHOD PATH [JSON_BODY]. Leaves the HTTP status in $STATUS and the response body in $BODY.
request() {
  local method=$1 path=$2 body=${3:-} output
  output=$(curl --silent --show-error --request "$method" "$API_URL$path" \
    --header "Authorization: Bearer $ZUBOKLIK_API_KEY" \
    --header 'Accept: application/json' --header 'Content-Type: application/json' \
    ${body:+--data "$body"} --write-out '\n%{http_code}')
  STATUS=${output##*$'\n'}
  BODY=${output%$'\n'*}
}

# Like request, but any non-2xx answer ends the script with the API's error list.
api() {
  request "$@"
  if (( STATUS < 200 || STATUS >= 300 )); then
    echo "HTTP $STATUS: $BODY" >&2
    exit 1
  fi
}

# "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
slot() { jq -r '"\(.booked_for) \(.start_time[11:16])-\(.end_time[11:16])"' <<<"$1"; }

# Local calendar date N days from today as YYYY-MM-DD (GNU date, then BSD/macOS date).
date_in() { date -d "+$1 days" +%F 2>/dev/null || date -v "+$1d" +%F; }

# 1. Check the connection and the key.
api GET ''
echo "1. API is up ($(jq -r .version <<<"$BODY"))"

# 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
api GET /symptoms;     symptom_id=$(jq '.symptoms[]     | select(.code == "without_complications") | .id' <<<"$BODY")
api GET /entry_types;  type_id=$(jq    '.entry_types[]  | select(.code == "prevention")            | .id' <<<"$BODY")
api GET /entry_states; state_id=$(jq   '.entry_states[] | select(.code == "reserved")              | .id' <<<"$BODY")
echo '2. Catalogs loaded: symptom without_complications, type prevention, state reserved'

# 3. Create a patient.
api POST /patients '{"patient":{"first_name":"Jan","last_name":"Ukázkový","phone_number":"+420777111222","email":"jan.ukazkovy@example.com"}}'
patient_id=$(jq .patient.id <<<"$BODY")
echo "3. Patient created: $(jq -r '.patient | "\(.first_name) \(.last_name)"' <<<"$BODY")"

# 4. Ask for free 30-minute slots in the next 30 days.
api GET "/vacancies?from=$(date_in 1)&to=$(date_in 31)&duration=30"
first=$(jq -c '.vacancies[0] // empty' <<<"$BODY")
second=$(jq -c '.vacancies[1] // empty' <<<"$BODY")
[[ -n $second ]] || { echo 'the practice has fewer than two free slots in the next 30 days' >&2; exit 1; }
echo "4. Free slots found: $(slot "$first") and $(slot "$second")"

# 5. Book the first one.
booking=$(jq -c --argjson type "$type_id" --argjson state "$state_id" --argjson patient "$patient_id" --argjson symptom "$symptom_id" \
  '{entry: ({booked_for, start_time, end_time} + {entry_type_id: $type, entry_state_id: $state, note: "Booked by the API example",
    patient_symptoms_attributes: [{patient_id: $patient, symptom_id: $symptom}]})}' <<<"$first")
api POST /entries "$booking"
entry_id=$(jq .entry.id <<<"$BODY")
echo "5. Appointment booked: $(slot "$(jq -c .entry <<<"$BODY")")"

# 6. Booking the same slot again is refused with 409 and its own error name, so code can react to it.
request POST /entries "$booking"
(( STATUS == 409 )) || { echo 'the API booked one slot twice' >&2; exit 1; }
echo "6. Same slot refused: HTTP $STATUS, $(jq -r '.errors[0].name' <<<"$BODY")"

# 7. Move the appointment to the second slot.
api PATCH "/entries/$entry_id" "$(jq -c '{entry: {booked_for, start_time, end_time}}' <<<"$second")"
echo "7. Appointment moved: $(slot "$(jq -c .entry <<<"$BODY")")"

# 8. Read it back: the detail carries the patient and the note.
api GET "/entries/$entry_id"
echo "8. Appointment read: $(jq -r '.entry | "\(.patient.last_name), note \"\(.note)\""' <<<"$BODY")"

# 9. Errors: a patient without a last name is refused with 422 and a list of reasons.
request POST /patients '{"patient":{"first_name":"Jan"}}'
(( STATUS == 422 )) || { echo 'the API accepted an invalid patient' >&2; exit 1; }
echo "9. Invalid patient refused: HTTP $STATUS, attribute $(jq -r '.errors[0].attribute' <<<"$BODY")"

# 10. Clean up: delete the appointment, deactivate the patient.
api DELETE "/entries/$entry_id"
api DELETE "/patients/$patient_id"
echo '10. Cleaned up'
