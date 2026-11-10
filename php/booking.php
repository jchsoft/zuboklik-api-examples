<?php
// Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
// Runs on plain PHP 8.1+ with the curl extension.  Usage:  ZUBOKLIK_API_KEY=... php booking.php

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

function find_by_code(array $items, string $code): array
{
    foreach ($items as $item) {
        if ($item['code'] === $code) {
            return $item;
        }
    }
    throw new RuntimeException("code $code not found");
}

// "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
function slot(array $item): string
{
    return sprintf('%s %s-%s', $item['booked_for'], substr($item['start_time'], 11, 5), substr($item['end_time'], 11, 5));
}

function times(array $item): array
{
    return ['booked_for' => $item['booked_for'], 'start_time' => $item['start_time'], 'end_time' => $item['end_time']];
}

// 1. Check the connection and the key.
echo '1. API is up (', api('GET', '')['version'], ")\n";

// 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
$symptom = find_by_code(api('GET', '/symptoms')['symptoms'], 'without_complications');
$type = find_by_code(api('GET', '/entry_types')['entry_types'], 'prevention');
$state = find_by_code(api('GET', '/entry_states')['entry_states'], 'reserved');
echo "2. Catalogs loaded: symptom {$symptom['code']}, type {$type['code']}, state {$state['code']}\n";

// 3. Create a patient.
$patient = api('POST', '/patients', ['patient' => [
    'first_name' => 'Jan', 'last_name' => 'Ukázkový', 'phone_number' => '+420777111222', 'email' => 'jan.ukazkovy@example.com',
]])['patient'];
echo "3. Patient created: {$patient['first_name']} {$patient['last_name']}\n";

// 4. Ask for free 30-minute slots in the next 30 days.
$from = date('Y-m-d', strtotime('+1 day'));
$to = date('Y-m-d', strtotime('+31 days'));
$vacancies = api('GET', "/vacancies?from=$from&to=$to&duration=30")['vacancies'];
if (count($vacancies) < 2) {
    exit("the practice has fewer than two free slots in the next 30 days\n");
}
[$first, $second] = $vacancies;
echo '4. Free slots found: ', slot($first), ' and ', slot($second), "\n";

// 5. Book the first one.
$booking = ['entry' => [
    'entry_type_id' => $type['id'], 'entry_state_id' => $state['id'],
    ...times($first),
    'note' => 'Booked by the API example',
    'patient_symptoms_attributes' => [['patient_id' => $patient['id'], 'symptom_id' => $symptom['id']]],
]];
$entry = api('POST', '/entries', $booking)['entry'];
echo '5. Appointment booked: ', slot($entry), "\n";

// 6. Booking the same slot again is refused with 409 and its own error name, so code can react to it.
try {
    api('POST', '/entries', $booking);
    exit("the API booked one slot twice\n");
} catch (ApiError $error) {
    echo "6. Same slot refused: HTTP {$error->status}, {$error->errors[0]['name']}\n";
}

// 7. Move the appointment to the second slot.
$entry = api('PATCH', "/entries/{$entry['id']}", ['entry' => times($second)])['entry'];
echo '7. Appointment moved: ', slot($entry), "\n";

// 8. Read it back: the detail carries the patient and the note.
$entry = api('GET', "/entries/{$entry['id']}")['entry'];
echo "8. Appointment read: {$entry['patient']['last_name']}, note \"{$entry['note']}\"\n";

// 9. Errors: a patient without a last name is refused with 422 and a list of reasons.
try {
    api('POST', '/patients', ['patient' => ['first_name' => 'Jan']]);
    exit("the API accepted an invalid patient\n");
} catch (ApiError $error) {
    echo "9. Invalid patient refused: HTTP {$error->status}, attribute {$error->errors[0]['attribute']}\n";
}

// 10. Clean up: delete the appointment, deactivate the patient.
api('DELETE', "/entries/{$entry['id']}");
api('DELETE', "/patients/{$patient['id']}");
echo "10. Cleaned up\n";
