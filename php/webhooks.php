<?php
// Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
// Runs on plain PHP 8.1+ with the curl extension.  Usage:  ZUBOKLIK_API_KEY=... php webhooks.php
// How to verify what the webhook then receives: verify_webhook.php.

declare(strict_types=1);

$apiUrl = getenv('ZUBOKLIK_API_URL') ?: 'https://zuboklik.cz/api/v1';
$apiKey = getenv('ZUBOKLIK_API_KEY') ?: exit("set ZUBOKLIK_API_KEY\n");
const WEBHOOK_URL = 'https://example.com/zuboklik-webhook'; // your endpoint; must be https and publicly reachable

// Thrown for every non-2xx answer. $errors is the parsed "errors" array of the response.
class ApiError extends Exception
{
    public function __construct(public int $status, public array $errors)
    {
        parent::__construct("HTTP $status: " . json_encode($errors, JSON_UNESCAPED_UNICODE));
    }
}

// One request. Returns the parsed JSON body (null for 204 No Content).
function api(string $method, string $path, ?array $body = null): ?array
{
    global $apiUrl, $apiKey;

    $curl = curl_init($apiUrl . $path);
    curl_setopt_array($curl, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => ["Authorization: Bearer $apiKey", 'Accept: application/json', 'Content-Type: application/json'],
    ]);
    if ($body !== null) {
        curl_setopt($curl, CURLOPT_POSTFIELDS, json_encode($body));
    }
    $text = curl_exec($curl);
    if ($text === false) {
        throw new RuntimeException(curl_error($curl));
    }
    $status = curl_getinfo($curl, CURLINFO_RESPONSE_CODE);

    $parsed = $text === '' ? null : json_decode($text, true, flags: JSON_THROW_ON_ERROR);
    if ($status < 200 || $status >= 300) {
        throw new ApiError($status, $parsed['errors'] ?? []);
    }
    return $parsed;
}

function active_count(): int
{
    return count(array_filter(api('GET', '/webhooks')['webhooks'], fn (array $webhook) => $webhook['status'] === 'active'));
}

// 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
$registered = api('POST', '/webhooks', ['webhook' => ['url' => WEBHOOK_URL]]);
$webhook = $registered['webhook'];
echo "1. Webhook registered: {$webhook['url']} ({$webhook['status']}, secret of ", strlen($registered['secret']), " characters)\n";

// 2. List the webhooks of this connected system.
echo '2. Webhooks listed: ', active_count(), " active\n";

// 3. A URL that is not https (or points to a private address) is refused with 422.
try {
    api('POST', '/webhooks', ['webhook' => ['url' => 'http://example.com/zuboklik-webhook']]);
    exit("the API accepted a plain http URL\n");
} catch (ApiError $error) {
    echo "3. Plain http refused: HTTP {$error->status}, attribute {$error->errors[0]['attribute']}\n";
}

// 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
api('DELETE', "/webhooks/{$webhook['id']}");
echo '4. Webhook switched off, ', active_count(), " active\n";
