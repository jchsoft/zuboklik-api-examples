// Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
// Runs on plain Node.js 18+, no packages.  Usage:  ZUBOKLIK_API_KEY=... node webhooks.mjs
// How to verify what the webhook then receives: verify_webhook.mjs.

const API_URL = process.env.ZUBOKLIK_API_URL ?? 'https://zuboklik.cz/api/v1';
const API_KEY = process.env.ZUBOKLIK_API_KEY;
if (!API_KEY) throw new Error('set ZUBOKLIK_API_KEY');
const WEBHOOK_URL = 'https://example.com/zuboklik-webhook'; // your endpoint; must be https and publicly reachable

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array of the response.
class ApiError extends Error {
  constructor(status, errors) {
    super(`HTTP ${status}: ${JSON.stringify(errors)}`);
    this.status = status;
    this.errors = errors;
  }
}

// One request. Returns the parsed JSON body (null for 204 No Content).
async function api(method, path, body) {
  const response = await fetch(API_URL + path, {
    method,
    headers: { Authorization: `Bearer ${API_KEY}`, Accept: 'application/json', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  const parsed = text ? JSON.parse(text) : null;
  if (!response.ok) throw new ApiError(response.status, parsed?.errors ?? []);
  return parsed;
}

const activeCount = async () => (await api('GET', '/webhooks')).webhooks.filter((webhook) => webhook.status === 'active').length;

// 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
const { webhook, secret } = await api('POST', '/webhooks', { webhook: { url: WEBHOOK_URL } });
console.log(`1. Webhook registered: ${webhook.url} (${webhook.status}, secret of ${secret.length} characters)`);

// 2. List the webhooks of this connected system.
console.log(`2. Webhooks listed: ${await activeCount()} active`);

// 3. A URL that is not https (or points to a private address) is refused with 422.
try {
  await api('POST', '/webhooks', { webhook: { url: 'http://example.com/zuboklik-webhook' } });
  throw new Error('the API accepted a plain http URL');
} catch (error) {
  if (!(error instanceof ApiError)) throw error;
  console.log(`3. Plain http refused: HTTP ${error.status}, attribute ${error.errors[0].attribute}`);
}

// 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
await api('DELETE', `/webhooks/${webhook.id}`);
console.log(`4. Webhook switched off, ${await activeCount()} active`);
