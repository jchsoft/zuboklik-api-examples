// Zuboklik API example: verify the signature of an incoming webhook.
// Runs on plain Node.js 18+, no packages.  Usage:  node verify_webhook.mjs

import { createHmac, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';

const MAX_AGE = 300; // seconds; older deliveries are refused (replay protection)

// secret    - the secret returned once by POST /api/v1/webhooks
// timestamp - the X-Zuboklik-Timestamp header
// body      - the raw request body, exactly as received (do not re-serialize the JSON)
// signature - the X-Zuboklik-Signature header, "sha256=<hex>"
function validWebhook(secret, timestamp, body, signature, now = Math.floor(Date.now() / 1000)) {
  if (Math.abs(now - Number(timestamp)) > MAX_AGE) return false;

  const expected = Buffer.from(`sha256=${createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex')}`);
  const received = Buffer.from(signature);
  return expected.length === received.length && timingSafeEqual(expected, received);
}

const vector = JSON.parse(readFileSync(new URL('../test-vectors/webhook.json', import.meta.url), 'utf8'));
const { secret, timestamp, body, signature } = vector;
const now = Number(timestamp) + 10;

console.log(`valid signature accepted: ${validWebhook(secret, timestamp, body, signature, now)}`);
console.log(`tampered body rejected: ${!validWebhook(secret, timestamp, body.replace('4711', '4712'), signature, now)}`);
console.log(`stale timestamp rejected: ${!validWebhook(secret, timestamp, body, signature, now + 3600)}`);
