# Zuboklik API examples

Runnable examples for the [Zuboklik](https://zuboklik.cz) partner API – online appointment booking for dental practices.
Every language does **exactly the same thing**, step by step, so you can read the one you know and compare it with any other.

🇨🇿 Hotové ukázky volání Zuboklik API ve dvanácti jazycích. Všechny dělají přesně totéž: objednání pacienta na volný termín,
práci s kartotékou pacientů, správu webhooků a ověření jejich podpisu. Dokumentace API: <https://zuboklik.cz/api-dokumentace>.

## The examples

| Example | What it shows | Endpoints |
|---|---|---|
| **booking** | find a free slot, book it, handle a taken slot, move the appointment, read it back | `/symptoms`, `/entry_types`, `/entry_states`, `/patients`, `/vacancies`, `/entries` |
| **patients** | create, page through the list, read, update, deactivate; 404 and 401 answers | `/patients` |
| **webhooks** | register a webhook, list, a refused URL, switch it off | `/webhooks` |
| **verify_webhook** | check the signature of a delivery your endpoint received (offline, no key) | – |

| Language | Directory | Files | Needs |
|---|---|---|---|
| curl | [`curl/`](curl) | `booking.sh`, `patients.sh`, `webhooks.sh` | bash, curl, jq |
| Ruby | [`ruby/`](ruby) | `booking.rb`, … | Ruby 3, no gems |
| PHP | [`php/`](php) | `booking.php`, … | PHP 8.1 + curl extension |
| Python | [`python/`](python) | `booking.py`, … | Python 3.9, no packages |
| JavaScript | [`javascript/`](javascript) | `booking.mjs`, … | Node.js 18, no packages |
| C# | [`csharp/`](csharp) | `Booking.cs`, … | .NET 10, no packages |
| Java | [`java/`](java/src/main/java) | `Booking.java`, … | JDK 17, Maven (Gson) |
| Kotlin | [`kotlin/`](kotlin) | `booking.main.kts`, … | Kotlin 1.9, JDK 17 (Gson) |
| Go | [`go/`](go) | `booking/main.go`, … | Go 1.21, standard library |
| Swift | [`swift/`](swift) | `booking.swift`, … | Swift 5.9 (`verify_webhook`: macOS) |
| Rust | [`rust/`](rust/src/bin) | `booking.rs`, … | Cargo (ureq, serde_json, hmac, sha2) |
| C++ | [`cpp/`](cpp) | `booking.cpp`, … | C++17, CMake, libcurl, OpenSSL, nlohmann/json |

Each file stands alone – copy one and you have everything it needs, including the small `api` helper.

## 1. Get a key

The API has two keys. Do not mix them up.

1. **Office API key** – the dentist generates it in Zuboklik: *Nastavení ordinace → Propojení → API klíč*. It proves the practice agreed to connect you.
   You use it once, to register your system.
2. **Bearer key of your connected system** – returned once by the registration call below. Every other request uses this key.

```bash
curl -X POST https://zuboklik.cz/api/v1/connected_systems \
  -H 'Authorization: ApiKey OFFICE_API_KEY' \
  -H 'Content-Type: application/json' \
  -d '{"name": "my-system"}'
```

```json
{
  "connected_system": { "id": 42, "name": "my-system", "status": "active", "office_code": "ABC123" },
  "api_key": "f7c3a1b9e2…",
  "message": "Napojený systém byl zaregistrován."
}
```

Store `api_key` safely – it is shown only this once – and export it for the examples:

```bash
export ZUBOKLIK_API_KEY=f7c3a1b9e2…
```

`ZUBOKLIK_API_URL` overrides the address (default `https://zuboklik.cz/api/v1`).

Try the examples against a test practice, not a live one: they create patients named "Ukázkový" / "Ukázková" and an appointment, and remove them at the end.
If a run stops halfway, they stay – discard them in the practice's card index.

To disconnect your system for good: `DELETE /api/v1/connected_systems` with both keys (`Authorization: Bearer …` and `X-Api-Key: OFFICE_API_KEY`).
Its Bearer key stops working immediately.

## 2. Run an example

From the language's own directory; replace `booking` with `patients`, `webhooks` or `verify_webhook`:

```bash
cd ruby       && ruby booking.rb
cd php        && php booking.php
cd python     && python3 booking.py
cd javascript && node booking.mjs
cd csharp     && dotnet run Booking.cs
cd java       && mvn -q compile exec:java -Dexec.mainClass=Booking
cd kotlin     && kotlin booking.main.kts
cd go         && go run ./booking
cd swift      && swift booking.swift
cd rust       && cargo run --quiet --bin booking
cd cpp        && cmake -B build && cmake --build build && ./build/booking
cd curl       && ./booking.sh
```

`bin/run-all booking` runs one example in every language and checks that they all print the same lines.

## 3. booking

| Step | Request | What it shows |
|---|---|---|
| 1 | `GET /api/v1` | the connection and the key work |
| 2 | `GET /symptoms`, `/entry_types`, `/entry_states` | catalogs – an appointment refers to them by `id`; look the ids up by `code` |
| 3 | `POST /patients` | create a patient |
| 4 | `GET /vacancies?from=…&to=…&duration=30` | free slots of the practice in the next 30 days |
| 5 | `POST /entries` | book the first free slot for the patient |
| 6 | `POST /entries` (same slot) | a taken slot: HTTP 409 with the error name `slot_taken` |
| 7 | `PATCH /entries/:id` | move the appointment to the second free slot |
| 8 | `GET /entries/:id` | read the appointment back with its patient and note |
| 9 | `POST /patients` (invalid) | validation errors: HTTP 422 and the `errors` array |
| 10 | `DELETE /entries/:id`, `DELETE /patients/:id` | clean up |

```text
1. API is up (v1)
2. Catalogs loaded: symptom without_complications, type prevention, state reserved
3. Patient created: Jan Ukázkový
4. Free slots found: 2026-11-16 07:30-08:00 and 2026-11-16 08:00-08:30
5. Appointment booked: 2026-11-16 07:30-08:00
6. Same slot refused: HTTP 409, slot_taken
7. Appointment moved: 2026-11-16 08:00-08:30
8. Appointment read: Ukázkový, note "Booked by the API example"
9. Invalid patient refused: HTTP 422, attribute last_name
10. Cleaned up
```

## 4. patients

| Step | Request | What it shows |
|---|---|---|
| 1 | `POST /patients` ×2 | create patients |
| 2 | `GET /patients?page=…&per_page=100` | paging: repeat until `meta.total_pages`; 100 per page is the maximum, 25 the default |
| 3 | `GET /patients/:id` | read one patient |
| 4 | `PATCH /patients/:id` | update – only the attributes you send change |
| 5 | `DELETE /patients/:id` | deactivate; the record stays in the practice's card index, the API stops returning it |
| 6 | `GET /patients/:id` | a deactivated or unknown patient: HTTP 404, `not_found` |
| 7 | `GET /patients` with a wrong key | HTTP 401, `invalid_api_key` |

```text
1. Patients created: Jana Ukázková and Petr Ukázkový
2. Patients listed: 4 on 1 page(s), ours among them: 2
3. Patient read: Jana Ukázková
4. Patient updated: jana.ukazkova@example.com, still Ukázková
5. Patients deactivated
6. Deactivated patient not found: HTTP 404, not_found
7. Wrong key refused: HTTP 401, invalid_api_key
```

`GET /entries` pages the same way (`page`, `per_page`, `meta`).

## 5. webhooks

Register a URL and Zuboklik will POST to it whenever a patient or an appointment of the practice changes.

| Step | Request | What it shows |
|---|---|---|
| 1 | `POST /webhooks` | register your URL; the `secret` for verifying deliveries is returned only now |
| 2 | `GET /webhooks` | list the webhooks of your connected system with their status |
| 3 | `POST /webhooks` (http) | the URL must be https and publicly reachable: HTTP 422 |
| 4 | `DELETE /webhooks/:id` | switch the webhook off |

```text
1. Webhook registered: https://example.com/zuboklik-webhook (active, secret of 64 characters)
2. Webhooks listed: 1 active
3. Plain http refused: HTTP 422, attribute url
4. Webhook switched off, 0 active
```

The example registers `https://example.com/zuboklik-webhook`; put your own endpoint there. A delivery looks like this – deliberately thin,
fetch the details with a `GET` on the resource:

```json
{ "event": "patient_created", "action": "create", "resource_type": "Patient", "resource_id": 4711, "office_code": "ABC123", "occurred_at": "2026-07-16T14:00:00.000+02:00" }
```

Answer with a 2xx within 10 seconds. After 10 failed deliveries in a row the webhook is switched off.

## 6. verify_webhook

Each delivery is signed with the secret from the registration:

```text
X-Zuboklik-Timestamp: 1752670800
X-Zuboklik-Signature: sha256=<hex of HMAC-SHA256(secret, timestamp + "." + raw body)>
```

To verify it:

1. take the **raw** request body – do not parse and re-serialize the JSON;
2. compute HMAC-SHA256 of `timestamp + "." + body` with your secret, hex-encode it and prefix it with `sha256=`;
3. compare it with the header in constant time;
4. refuse deliveries whose timestamp is more than five minutes off (replay protection).

The example in each language does this against a fixed vector, [`test-vectors/webhook.json`](test-vectors/webhook.json),
so it runs offline and you can check your own implementation with the same data:

```text
valid signature accepted: true
tampered body rejected: true
stale timestamp rejected: true
```

## Things worth knowing

- **Errors** always look the same: `{"errors": [{"name": "...", "message": ["..."], "attribute": "..."}]}`. Branch on `name` and the HTTP status,
  show `message` to people. `attribute` is present for validation errors.
- **Ids** are the practice's own numbers. The `id` you get from `/patients` is the one you send as `patient_id` when booking.
- **Times** come back with a UTC offset. Send back what `/vacancies` gave you; a time without an offset is read as the practice's local time.
- **Rate limit**: 600 requests per minute per connected system, then HTTP 429 with a `Retry-After` header. Wait and repeat the request.

## Found a problem?

Open an issue here, or write to technicka@zuboklik.cz. The full reference is at <https://zuboklik.cz/api-dokumentace>.

## License

[MIT](LICENSE). It covers the code in this repository; use of the API itself is governed by the Zuboklik terms.
