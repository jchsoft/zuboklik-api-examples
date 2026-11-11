// Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
// survive a repeated request, and read "what changed since last time" (deletions included).
// Usage:  ZUBOKLIK_API_KEY=... cargo run --quiet --bin sync

use serde_json::{json, Value};
use std::env;
use time::OffsetDateTime;

const EXTERNAL_ID: &str = "example-patient-1"; // the id of this patient in YOUR system

/// Returned for every non-2xx answer. `errors` is the parsed "errors" array, `body` the whole parsed response.
#[derive(Debug)]
struct ApiError {
    status: u16,
    errors: Vec<Value>,
    body: Value,
}

struct Api {
    url: String,
    key: String,
}

impl Api {
    /// One request. Returns the parsed JSON body (`Value::Null` for 204 No Content).
    fn call(&self, method: &str, path: &str, body: Option<Value>) -> Result<Value, ApiError> {
        let request = ureq::request(method, &format!("{}{}", self.url, path))
            .set("Authorization", &format!("Bearer {}", self.key))
            .set("Accept", "application/json")
            .set("Content-Type", "application/json");
        let result = match body {
            Some(body) => request.send_string(&body.to_string()),
            None => request.call(),
        };

        let parse = |response: ureq::Response| -> Value {
            let text = response.into_string().expect("readable response body");
            if text.is_empty() { Value::Null } else { serde_json::from_str(&text).expect("JSON response") }
        };
        match result {
            Ok(response) => Ok(parse(response)),
            Err(ureq::Error::Status(status, response)) => {
                let body = parse(response);
                let errors = body["errors"].as_array().cloned().unwrap_or_default();
                Err(ApiError { status, errors, body })
            }
            Err(error) => panic!("connection failed: {error}"),
        }
    }
}

fn text<'a>(item: &'a Value, key: &str) -> &'a str {
    item[key].as_str().unwrap_or("")
}

/// The current UTC time as ISO 8601, e.g. 2026-11-10T21:42:25Z.
fn now_iso8601() -> String {
    let now = OffsetDateTime::now_utc();
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        now.year(), u8::from(now.month()), now.day(), now.hour(), now.minute(), now.second()
    )
}

/// Percent-encodes a value for the query string.
fn url_encode(value: &str) -> String {
    value.bytes().map(|byte| match byte {
        b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (byte as char).to_string(),
        _ => format!("%{byte:02X}"),
    }).collect()
}

/// What your system does with one change. A webhook delivery has the same fields, so the same code handles both.
/// Returns a line describing what was done.
fn apply(api: &Api, change: &Value) -> Result<String, ApiError> {
    let collection = if change["resource_type"] == "Patient" { "patients" } else { "entries" };
    let event = text(change, "event");
    if change["action"] == "destroy" {
        return Ok(format!("{event}: removed from our system"));
    }
    // the current state of the record; save it on your side
    match api.call("GET", &format!("/{collection}/{}", change["resource_id"]), None) {
        Ok(_) => Ok(format!("{event}: saved to our system")),
        Err(error) if error.status == 404 => Ok(format!("{event}: already gone, removed from our system")), // deleted again before we asked
        Err(error) => Err(error),
    }
}

fn main() -> Result<(), ApiError> {
    let api = Api {
        url: env::var("ZUBOKLIK_API_URL").unwrap_or_else(|_| "https://zuboklik.cz/api/v1".into()),
        key: env::var("ZUBOKLIK_API_KEY").expect("set ZUBOKLIK_API_KEY"),
    };
    // Where to start reading changes. A real integration stores the cursor of the last change it processed
    // and never needs this; the example starts "now" unless told otherwise.
    let since = env::var("ZUBOKLIK_SYNC_SINCE").unwrap_or_else(|_| now_iso8601());

    let new_patient = json!({ "patient": {
        "first_name": "Eva", "last_name": "Ukázková", "phone_number": "+420777111222", "external_id": EXTERNAL_ID
    } });

    // 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
    //    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
    let found = api.call("GET", &format!("/patients?external_id={EXTERNAL_ID}"), None)?["patients"].clone();
    let patient = match found.get(0) {
        Some(patient) => patient.clone(),
        None => api.call("POST", "/patients", Some(new_patient.clone()))?["patient"].clone(),
    };
    println!(
        "1. Patient paired: {} {}, external_id {}",
        text(&patient, "first_name"), text(&patient, "last_name"), text(&patient, "external_id")
    );

    // 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
    match api.call("POST", "/patients", Some(new_patient)) {
        Ok(_) => panic!("the API created the same patient twice"),
        Err(error) => {
            let same = error.body["patient"]["id"] == patient["id"];
            println!(
                "2. Repeated request created nothing: HTTP {}, {}, same patient: {}",
                error.status, text(&error.errors[0], "name"), same
            );
        }
    }

    // 3. From now on find the record by your own id.
    let found = api.call("GET", &format!("/patients?external_id={EXTERNAL_ID}"), None)?["patients"].clone();
    println!("3. Found by external_id: {} patient(s)", found.as_array().map_or(0, Vec::len));

    // 4. What changed in the practice since last time? Page by cursor until `more` is false.
    //    Changes made by this key are left out; you see what the staff, the patients and other systems did.
    let mut applied: Vec<String> = Vec::new();
    let mut query = format!("since={}", url_encode(&since));
    loop {
        let page = api.call("GET", &format!("/changes?{query}"), None)?;
        for change in page["changes"].as_array().expect("changes") {
            applied.push(apply(&api, change)?);
        }
        if !page["meta"]["more"].as_bool().expect("meta.more") {
            break;
        }
        query = format!("after={}", text(&page["meta"], "next_cursor")); // store this cursor; next time start from it
    }
    println!("4. Changes from the practice: {}", applied.len());
    for line in &applied {
        println!("   {line}");
    }

    // 5. Clean up: give the external_id back, then deactivate the patient.
    api.call("PATCH", &format!("/patients/{}", patient["id"]), Some(json!({ "patient": { "external_id": null } })))?;
    api.call("DELETE", &format!("/patients/{}", patient["id"]), None)?;
    println!("5. Cleaned up");
    Ok(())
}
