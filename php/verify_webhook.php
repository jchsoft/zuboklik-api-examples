<?php
// Zuboklik API example: verify the signature of an incoming webhook.
// Runs on plain PHP 8.1+, no packages.  Usage:  php verify_webhook.php

declare(strict_types=1);

const MAX_AGE = 300; // seconds; older deliveries are refused (replay protection)

// $secret    - the secret returned once by POST /api/v1/webhooks
// $timestamp - the X-Zuboklik-Timestamp header
// $body      - the raw request body, exactly as received (do not re-serialize the JSON)
// $signature - the X-Zuboklik-Signature header, "sha256=<hex>"
function valid_webhook(string $secret, string $timestamp, string $body, string $signature, ?int $now = null): bool
{
    $now ??= time();
    if (abs($now - (int) $timestamp) > MAX_AGE) {
        return false;
    }

    return hash_equals('sha256=' . hash_hmac('sha256', "$timestamp.$body", $secret), $signature);
}

$vector = json_decode(file_get_contents(__DIR__ . '/../test-vectors/webhook.json'), true, flags: JSON_THROW_ON_ERROR);
['secret' => $secret, 'timestamp' => $timestamp, 'body' => $body, 'signature' => $signature] = $vector;
$now = (int) $timestamp + 10;

$show = fn (bool $value): string => $value ? 'true' : 'false';

echo 'valid signature accepted: ', $show(valid_webhook($secret, $timestamp, $body, $signature, $now)), "\n";
echo 'tampered body rejected: ', $show(!valid_webhook($secret, $timestamp, str_replace('4711', '4712', $body), $signature, $now)), "\n";
echo 'stale timestamp rejected: ', $show(!valid_webhook($secret, $timestamp, $body, $signature, $now + 3600)), "\n";
