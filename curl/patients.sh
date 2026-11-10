#!/usr/bin/env bash
# Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
# Needs curl and jq.  Usage:  ZUBOKLIK_API_KEY=... ./patients.sh

set -euo pipefail

API_URL="${ZUBOKLIK_API_URL:-https://zuboklik.cz/api/v1}"
: "${ZUBOKLIK_API_KEY:?set ZUBOKLIK_API_KEY}"

# One request: request METHOD PATH [JSON_BODY]. Leaves the HTTP status in $STATUS and the response body in $BODY.
# Set KEY for one call to send another key than ZUBOKLIK_API_KEY.
request() {
  local method=$1 path=$2 body=${3:-} output
  output=$(curl --silent --show-error --request "$method" "$API_URL$path" \
    --header "Authorization: Bearer ${KEY:-$ZUBOKLIK_API_KEY}" \
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

name() { jq -r '.patient | "\(.first_name) \(.last_name)"' <<<"$1"; }

# 1. Create two patients.
api POST /patients '{"patient":{"first_name":"Jana","last_name":"Ukázková","phone_number":"+420777111222"}}'
jana_id=$(jq .patient.id <<<"$BODY"); jana=$(name "$BODY")
api POST /patients '{"patient":{"first_name":"Petr","last_name":"Ukázkový","email":"petr.ukazkovy@example.com"}}'
petr_id=$(jq .patient.id <<<"$BODY"); petr=$(name "$BODY")
echo "1. Patients created: $jana and $petr"

# 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
total=0 ours=0 page=1
while true; do
  api GET "/patients?page=$page&per_page=100"
  total=$(( total + $(jq '.patients | length' <<<"$BODY") ))
  ours=$(( ours + $(jq --argjson jana "$jana_id" --argjson petr "$petr_id" '[.patients[] | select(.id == $jana or .id == $petr)] | length' <<<"$BODY") ))
  (( page < $(jq .meta.total_pages <<<"$BODY") )) || break
  page=$(( page + 1 ))
done
echo "2. Patients listed: $total on $page page(s), ours among them: $ours"

# 3. Read one patient.
api GET "/patients/$jana_id"
echo "3. Patient read: $(name "$BODY")"

# 4. Update: only the attributes you send change.
api PATCH "/patients/$jana_id" '{"patient":{"email":"jana.ukazkova@example.com"}}'
echo "4. Patient updated: $(jq -r '.patient | "\(.email), still \(.last_name)"' <<<"$BODY")"

# 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
api DELETE "/patients/$jana_id"
api DELETE "/patients/$petr_id"
echo '5. Patients deactivated'

# 6. A deactivated (or unknown) patient answers 404.
request GET "/patients/$jana_id"
(( STATUS == 404 )) || { echo 'the API still returns a deactivated patient' >&2; exit 1; }
echo "6. Deactivated patient not found: HTTP $STATUS, $(jq -r '.errors[0].name' <<<"$BODY")"

# 7. A wrong key answers 401.
KEY=not-a-valid-key request GET /patients
(( STATUS == 401 )) || { echo 'the API accepted a wrong key' >&2; exit 1; }
echo "7. Wrong key refused: HTTP $STATUS, $(jq -r '.errors[0].name' <<<"$BODY")"
