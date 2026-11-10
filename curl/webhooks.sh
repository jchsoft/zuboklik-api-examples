#!/usr/bin/env bash
# Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
# Needs curl and jq.  Usage:  ZUBOKLIK_API_KEY=... ./webhooks.sh
# curl only sends requests; how to verify what the webhook then receives: verify_webhook in any other language.

set -euo pipefail

API_URL="${ZUBOKLIK_API_URL:-https://zuboklik.cz/api/v1}"
: "${ZUBOKLIK_API_KEY:?set ZUBOKLIK_API_KEY}"
WEBHOOK_URL='https://example.com/zuboklik-webhook' # your endpoint; must be https and publicly reachable

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

# Leaves the number of active webhooks in $ACTIVE.
count_active() {
  api GET /webhooks
  ACTIVE=$(jq '[.webhooks[] | select(.status == "active")] | length' <<<"$BODY")
}

# 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
api POST /webhooks "$(jq -c --null-input --arg url "$WEBHOOK_URL" '{webhook: {url: $url}}')"
webhook_id=$(jq .webhook.id <<<"$BODY")
echo "1. Webhook registered: $(jq -r '"\(.webhook.url) (\(.webhook.status), secret of \(.secret | length) characters)"' <<<"$BODY")"

# 2. List the webhooks of this connected system.
count_active
echo "2. Webhooks listed: $ACTIVE active"

# 3. A URL that is not https (or points to a private address) is refused with 422.
request POST /webhooks '{"webhook":{"url":"http://example.com/zuboklik-webhook"}}'
(( STATUS == 422 )) || { echo 'the API accepted a plain http URL' >&2; exit 1; }
echo "3. Plain http refused: HTTP $STATUS, attribute $(jq -r '.errors[0].attribute' <<<"$BODY")"

# 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
api DELETE "/webhooks/$webhook_id"
count_active
echo "4. Webhook switched off, $ACTIVE active"
