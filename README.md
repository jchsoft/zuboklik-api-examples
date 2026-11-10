# Zuboklik API examples

Runnable examples for the [Zuboklik](https://zuboklik.cz) partner API – online appointment booking for dental practices.
Every language does **exactly the same thing**, step by step, so you can read the one you know and compare it with any other.

🇨🇿 Hotové ukázky volání Zuboklik API. Všechny jazyky dělají přesně totéž: založí pacienta, najdou volný termín, objednají ho,
přesunou a uklidí po sobě. Druhá ukázka ověřuje podpis webhooku. Dokumentace API: <https://zuboklik.cz/api-dokumentace>.

| Language | Booking scenario | Webhook signature | Needs |
|---|---|---|---|
| curl | [`curl/booking.sh`](curl/booking.sh) | – | curl, jq |
| Ruby | [`ruby/booking.rb`](ruby/booking.rb) | [`ruby/verify_webhook.rb`](ruby/verify_webhook.rb) | Ruby 3, no gems |
| PHP | [`php/booking.php`](php/booking.php) | [`php/verify_webhook.php`](php/verify_webhook.php) | PHP 8.1 + curl extension |
| Python | [`python/booking.py`](python/booking.py) | [`python/verify_webhook.py`](python/verify_webhook.py) | Python 3.9, no packages |
| JavaScript | [`javascript/booking.mjs`](javascript/booking.mjs) | [`javascript/verify_webhook.mjs`](javascript/verify_webhook.mjs) | Node.js 18, no packages |
| C# | [`csharp/Booking.cs`](csharp/Booking.cs) | [`csharp/VerifyWebhook.cs`](csharp/VerifyWebhook.cs) | .NET 10, no packages |
| Java | [`java/…/Booking.java`](java/src/main/java/Booking.java) | [`java/…/VerifyWebhook.java`](java/src/main/java/VerifyWebhook.java) | JDK 17, Maven (Gson) |
| Kotlin | [`kotlin/booking.main.kts`](kotlin/booking.main.kts) | [`kotlin/verify_webhook.main.kts`](kotlin/verify_webhook.main.kts) | Kotlin 1.9, JDK 17 (Gson) |
| Go | [`go/booking/main.go`](go/booking/main.go) | [`go/verify_webhook/main.go`](go/verify_webhook/main.go) | Go 1.21, standard library |
| Swift | [`swift/booking.swift`](swift/booking.swift) | [`swift/verify_webhook.swift`](swift/verify_webhook.swift) | Swift 5.9 (webhook example: macOS) |
| Rust | [`rust/src/bin/booking.rs`](rust/src/bin/booking.rs) | [`rust/src/bin/verify_webhook.rs`](rust/src/bin/verify_webhook.rs) | Cargo (ureq, serde_json, hmac, sha2) |
| C++ | [`cpp/booking.cpp`](cpp/booking.cpp) | [`cpp/verify_webhook.cpp`](cpp/verify_webhook.cpp) | C++17, CMake, libcurl, OpenSSL, nlohmann/json |

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

Try the examples against a test practice, not a live one: they create the patient "Jan Ukázkový" and an appointment, and remove both at the end.
If a run stops halfway, the patient stays – discard him in the practice's card index.

## 2. The booking scenario

| Step | Request | What it shows |
|---|---|---|
| 1 | `GET /api/v1` | the connection and the key work |
| 2 | `GET /symptoms`, `/entry_types`, `/entry_states` | catalogs – an appointment refers to them by `id`; look the ids up by `code` |
| 3 | `POST /patients` | create a patient |
| 4 | `GET /vacancies?from=…&to=…&duration=30` | free slots of the practice in the next 30 days |
| 5 | `POST /entries` | book the first free slot for the patient |
| 6 | `PATCH /entries/:id` | move the appointment to the second free slot |
| 7 | `POST /patients` (invalid) | error handling: HTTP 422 and the `errors` array |
| 8 | `DELETE /entries/:id`, `DELETE /patients/:id` | clean up (a deleted patient is deactivated, not erased) |

Every example prints the same eight lines:

```text
1. API is up (v1)
2. Catalogs loaded: symptom without_complications, type prevention, state reserved
3. Patient created: Jan Ukázkový
4. Free slots found: 2026-11-24 09:00-09:30 and 2026-11-24 09:30-10:00
5. Appointment booked: 2026-11-24 09:00-09:30
6. Appointment moved: 2026-11-24 09:30-10:00
7. Invalid patient refused: HTTP 422, attribute last_name
8. Cleaned up
```

Run one from its own directory:

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

`ZUBOKLIK_API_URL` overrides the address (default `https://zuboklik.cz/api/v1`).

### Things worth knowing

- **Errors** always look the same: `{"errors": [{"name": "...", "message": ["..."], "attribute": "..."}]}`. Branch on `name` and the HTTP status,
  show `message` to people. `attribute` is present for validation errors.
- **A taken slot** answers `409` with `name: "slot_taken"`. Ask `/vacancies` again and offer another time.
- **Ids** are the practice's own numbers. The `id` you get from `/patients` is the one you send as `patient_id` when booking.
- **Times** come back with a UTC offset. Send back what `/vacancies` gave you; a time without an offset is read as the practice's local time.
- **Rate limit**: 600 requests per minute per connected system, then `429` with a `Retry-After` header.

## 3. Verifying a webhook

Register a URL with `POST /api/v1/webhooks` and Zuboklik will POST to it whenever a patient or an appointment of the practice changes.
The response to the registration contains a `secret` – once. Each delivery is signed with it:

```text
X-Zuboklik-Timestamp: 1752670800
X-Zuboklik-Signature: sha256=<hex of HMAC-SHA256(secret, timestamp + "." + raw body)>
```

To verify a delivery:

1. take the **raw** request body – do not parse and re-serialize the JSON;
2. compute HMAC-SHA256 of `timestamp + "." + body` with your secret, hex-encode it and prefix it with `sha256=`;
3. compare it with the header in constant time;
4. refuse deliveries whose timestamp is more than five minutes off (replay protection).

The `verify_webhook` example in each language does this against a fixed vector, [`test-vectors/webhook.json`](test-vectors/webhook.json),
so it runs offline and you can check your own implementation with the same data. Every one prints:

```text
valid signature accepted: true
tampered body rejected: true
stale timestamp rejected: true
```

## Found a problem?

Open an issue here, or write to technicka@zuboklik.cz. The full reference is at <https://zuboklik.cz/api-dokumentace>.

## License

[MIT](LICENSE). It covers the code in this repository; use of the API itself is governed by the Zuboklik terms.
