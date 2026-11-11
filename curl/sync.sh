#!/usr/bin/env bash
# Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
# survive a repeated request, and read "what changed since last time" (deletions included).
# Needs curl and jq.  Usage:  ZUBOKLIK_API_KEY=... ./sync.sh

set -euo pipefail

API_URL="${ZUBOKLIK_API_URL:-https://zuboklik.cz/api/v1}"
: "${ZUBOKLIK_API_KEY:?set ZUBOKLIK_API_KEY}"
# Where to start reading changes. A real integration stores the cursor of the last change it processed
# and never needs this; the example starts "now" unless told otherwise.
SINCE="${ZUBOKLIK_SYNC_SINCE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
EXTERNAL_ID=example-patient-1 # the id of this patient in YOUR system

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

# Ends the script with the API's error list.
fail() {
  echo "HTTP $STATUS: $BODY" >&2
  exit 1
}

# Like request, but any non-2xx answer ends the script.
api() {
  request "$@"
  (( STATUS >= 200 && STATUS < 300 )) || fail
}

# What your system does with one change. A webhook delivery has the same fields, so the same code handles both.
# Leaves a line describing what was done in $LINE.
apply() {
  local change=$1 event action collection id
  event=$(jq -r .event <<<"$change")
  action=$(jq -r .action <<<"$change")
  collection=$(jq -r 'if .resource_type == "Patient" then "patients" else "entries" end' <<<"$change")
  id=$(jq -r .resource_id <<<"$change")
  if [[ $action == destroy ]]; then
    LINE="$event: removed from our system"
    return
  fi

  request GET "/$collection/$id" # the current state of the record; save it on your side
  if (( STATUS == 404 )); then
    LINE="$event: already gone, removed from our system" # deleted again before we asked
  elif (( STATUS >= 200 && STATUS < 300 )); then
    LINE="$event: saved to our system"
  else
    fail
  fi
}

new_patient='{"patient":{"first_name":"Eva","last_name":"Ukázková","phone_number":"+420777111222","external_id":"'$EXTERNAL_ID'"}}'

# 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
#    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
api GET "/patients?external_id=$EXTERNAL_ID"
patient=$(jq -c '.patients[0] // empty' <<<"$BODY")
if [[ -z $patient ]]; then
  api POST /patients "$new_patient"
  patient=$(jq -c .patient <<<"$BODY")
fi
patient_id=$(jq .id <<<"$patient")
echo "1. Patient paired: $(jq -r '"\(.first_name) \(.last_name), external_id \(.external_id)"' <<<"$patient")"

# 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
request POST /patients "$new_patient"
(( STATUS < 200 || STATUS >= 300 )) || { echo 'the API created the same patient twice' >&2; exit 1; }
same=$(jq --argjson id "$patient_id" '.patient.id == $id' <<<"$BODY")
echo "2. Repeated request created nothing: HTTP $STATUS, $(jq -r '.errors[0].name' <<<"$BODY"), same patient: $same"

# 3. From now on find the record by your own id.
api GET "/patients?external_id=$EXTERNAL_ID"
echo "3. Found by external_id: $(jq '.patients | length' <<<"$BODY") patient(s)"

# 4. What changed in the practice since last time? Page by cursor until `more` is false.
#    Changes made by this key are left out; you see what the staff, the patients and other systems did.
count=0 applied=''
query="since=$(jq -rn --arg since "$SINCE" '$since | @uri')"
while true; do
  api GET "/changes?$query"
  page=$BODY
  while IFS= read -r change; do
    apply "$change"
    count=$(( count + 1 )) applied+="   $LINE"$'\n'
  done < <(jq -c '.changes[]' <<<"$page")
  [[ $(jq .meta.more <<<"$page") == true ]] || break

  query="after=$(jq -r .meta.next_cursor <<<"$page")" # store this cursor; next time start from it
done
echo "4. Changes from the practice: $count"
printf '%s' "$applied"

# 5. Clean up: give the external_id back, then deactivate the patient.
api PATCH "/patients/$patient_id" '{"patient":{"external_id":null}}'
api DELETE "/patients/$patient_id"
echo '5. Cleaned up'
