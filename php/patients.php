<?php
// Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
// Runs on plain PHP 8.1+ with the curl extension.  Usage:  ZUBOKLIK_API_KEY=... php patients.php

declare(strict_types=1);

$apiUrl = getenv('ZUBOKLIK_API_URL') ?: 'https://zuboklik.cz/api/v1';
$apiKey = getenv('ZUBOKLIK_API_KEY') ?: exit("set ZUBOKLIK_API_KEY\n");

// Thrown for every non-2xx answer. $errors is the parsed "errors" array of the response.
class ApiError extends Exception
{
    public function __construct(public int $status, public array $errors)
    {
        parent::__construct("HTTP $status: " . json_encode($errors, JSON_UNESCAPED_UNICODE));
    }
}

// One request. Returns the parsed JSON body (null for 204 No Content). $key replaces the configured key for this call.
function api(string $method, string $path, ?array $body = null, ?string $key = null): ?array
{
    global $apiUrl, $apiKey;

    $key ??= $apiKey;
    $curl = curl_init($apiUrl . $path);
    curl_setopt_array($curl, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => ["Authorization: Bearer $key", 'Accept: application/json', 'Content-Type: application/json'],
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

// 1. Create two patients.
$jana = api('POST', '/patients', ['patient' => ['first_name' => 'Jana', 'last_name' => 'Ukázková', 'phone_number' => '+420777111222']])['patient'];
$petr = api('POST', '/patients', ['patient' => ['first_name' => 'Petr', 'last_name' => 'Ukázkový', 'email' => 'petr.ukazkovy@example.com']])['patient'];
echo "1. Patients created: {$jana['first_name']} {$jana['last_name']} and {$petr['first_name']} {$petr['last_name']}\n";

// 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
$patients = [];
$page = 1;
while (true) {
    $list = api('GET', "/patients?page=$page&per_page=100");
    array_push($patients, ...$list['patients']);
    if ($page >= $list['meta']['total_pages']) {
        break;
    }
    $page++;
}
$ours = count(array_filter($patients, fn (array $patient) => in_array($patient['id'], [$jana['id'], $petr['id']], true)));
echo '2. Patients listed: ', count($patients), " on $page page(s), ours among them: $ours\n";

// 3. Read one patient.
$detail = api('GET', "/patients/{$jana['id']}")['patient'];
echo "3. Patient read: {$detail['first_name']} {$detail['last_name']}\n";

// 4. Update: only the attributes you send change.
$updated = api('PATCH', "/patients/{$jana['id']}", ['patient' => ['email' => 'jana.ukazkova@example.com']])['patient'];
echo "4. Patient updated: {$updated['email']}, still {$updated['last_name']}\n";

// 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
api('DELETE', "/patients/{$jana['id']}");
api('DELETE', "/patients/{$petr['id']}");
echo "5. Patients deactivated\n";

// 6. A deactivated (or unknown) patient answers 404.
try {
    api('GET', "/patients/{$jana['id']}");
    exit("the API still returns a deactivated patient\n");
} catch (ApiError $error) {
    echo "6. Deactivated patient not found: HTTP {$error->status}, {$error->errors[0]['name']}\n";
}

// 7. A wrong key answers 401.
try {
    api('GET', '/patients', key: 'not-a-valid-key');
    exit("the API accepted a wrong key\n");
} catch (ApiError $error) {
    echo "7. Wrong key refused: HTTP {$error->status}, {$error->errors[0]['name']}\n";
}
