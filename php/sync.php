<?php
// Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
// survive a repeated request, and read "what changed since last time" (deletions included).
// Runs on plain PHP 8.1+ with the curl extension.  Usage:  ZUBOKLIK_API_KEY=... php sync.php

declare(strict_types=1);

$apiUrl = getenv('ZUBOKLIK_API_URL') ?: 'https://zuboklik.cz/api/v1';
$apiKey = getenv('ZUBOKLIK_API_KEY') ?: exit("set ZUBOKLIK_API_KEY\n");
// Where to start reading changes. A real integration stores the cursor of the last change it processed
// and never needs this; the example starts "now" unless told otherwise.
$since = getenv('ZUBOKLIK_SYNC_SINCE') ?: gmdate('Y-m-d\TH:i:s\Z');
const EXTERNAL_ID = 'example-patient-1'; // the id of this patient in YOUR system

// Thrown for every non-2xx answer. $errors is the parsed "errors" array, $body the whole parsed response.
class ApiError extends Exception
{
    public array $body;
    public array $errors;

    public function __construct(public int $status, ?array $body)
    {
        $this->body = $body ?? [];
        $this->errors = $this->body['errors'] ?? [];
        parent::__construct("HTTP $status: " . json_encode($this->errors, JSON_UNESCAPED_UNICODE));
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
        throw new ApiError($status, $parsed);
    }
    return $parsed;
}

// What your system does with one change. A webhook delivery has the same fields, so the same code handles both.
// Returns a line describing what was done.
function apply(array $change): string
{
    $collection = $change['resource_type'] === 'Patient' ? 'patients' : 'entries';
    if ($change['action'] === 'destroy') {
        return "{$change['event']}: removed from our system";
    }
    try {
        api('GET', "/$collection/{$change['resource_id']}"); // the current state of the record; save it on your side
        return "{$change['event']}: saved to our system";
    } catch (ApiError $error) {
        if ($error->status !== 404) {
            throw $error;
        }
        return "{$change['event']}: already gone, removed from our system"; // deleted again before we asked
    }
}

$newPatient = ['patient' => ['first_name' => 'Eva', 'last_name' => 'Ukázková', 'phone_number' => '+420777111222', 'external_id' => EXTERNAL_ID]];

// 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
//    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
$found = api('GET', '/patients?external_id=' . EXTERNAL_ID)['patients'];
$patient = $found[0] ?? api('POST', '/patients', $newPatient)['patient'];
echo "1. Patient paired: {$patient['first_name']} {$patient['last_name']}, external_id {$patient['external_id']}\n";

// 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
try {
    api('POST', '/patients', $newPatient);
    exit("the API created the same patient twice\n");
} catch (ApiError $error) {
    $same = ($error->body['patient']['id'] ?? null) === $patient['id'] ? 'true' : 'false';
    echo "2. Repeated request created nothing: HTTP {$error->status}, {$error->errors[0]['name']}, same patient: $same\n";
}

// 3. From now on find the record by your own id.
$found = api('GET', '/patients?external_id=' . EXTERNAL_ID)['patients'];
echo '3. Found by external_id: ', count($found), " patient(s)\n";

// 4. What changed in the practice since last time? Page by cursor until `more` is false.
//    Changes made by this key are left out; you see what the staff, the patients and other systems did.
$applied = [];
$query = 'since=' . rawurlencode($since);
while (true) {
    $page = api('GET', "/changes?$query");
    foreach ($page['changes'] as $change) {
        $applied[] = apply($change);
    }
    if (!$page['meta']['more']) {
        break;
    }
    $query = "after={$page['meta']['next_cursor']}"; // store this cursor; next time start from it
}
echo '4. Changes from the practice: ', count($applied), "\n";
foreach ($applied as $line) {
    echo "   $line\n";
}

// 5. Clean up: give the external_id back, then deactivate the patient.
api('PATCH', "/patients/{$patient['id']}", ['patient' => ['external_id' => null]]);
api('DELETE', "/patients/{$patient['id']}");
echo "5. Cleaned up\n";
