// Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
// Usage:  ZUBOKLIK_API_KEY=... cargo run --quiet --bin booking

use serde_json::{json, Value};
use std::env;
use time::{Duration, OffsetDateTime};

/// Returned for every non-2xx answer. `errors` is the parsed "errors" array of the response.
#[derive(Debug)]
struct ApiError {
    status: u16,
    errors: Vec<Value>,
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
                let errors = parse(response)["errors"].as_array().cloned().unwrap_or_default();
                Err(ApiError { status, errors })
            }
            Err(error) => panic!("connection failed: {error}"),
        }
    }
}

fn find_by_code(items: &Value, code: &str) -> Value {
    let found = items.as_array().and_then(|list| list.iter().find(|item| item["code"] == code));
    found.unwrap_or_else(|| panic!("code {code} not found")).clone()
}

fn text<'a>(item: &'a Value, key: &str) -> &'a str {
    item[key].as_str().unwrap_or("")
}

/// "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
fn slot(item: &Value) -> String {
    format!("{} {}-{}", text(item, "booked_for"), &text(item, "start_time")[11..16], &text(item, "end_time")[11..16])
}

fn main() -> Result<(), ApiError> {
    let api = Api {
        url: env::var("ZUBOKLIK_API_URL").unwrap_or_else(|_| "https://zuboklik.cz/api/v1".into()),
        key: env::var("ZUBOKLIK_API_KEY").expect("set ZUBOKLIK_API_KEY"),
    };

    // 1. Check the connection and the key.
    println!("1. API is up ({})", text(&api.call("GET", "", None)?, "version"));

    // 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
    let symptom = find_by_code(&api.call("GET", "/symptoms", None)?["symptoms"], "without_complications");
    let entry_type = find_by_code(&api.call("GET", "/entry_types", None)?["entry_types"], "prevention");
    let state = find_by_code(&api.call("GET", "/entry_states", None)?["entry_states"], "reserved");
    println!(
        "2. Catalogs loaded: symptom {}, type {}, state {}",
        text(&symptom, "code"), text(&entry_type, "code"), text(&state, "code")
    );

    // 3. Create a patient.
    let patient = api.call("POST", "/patients", Some(json!({ "patient": {
        "first_name": "Jan", "last_name": "Ukázkový", "phone_number": "+420777111222", "email": "jan.ukazkovy@example.com"
    } })))?["patient"].clone();
    println!("3. Patient created: {} {}", text(&patient, "first_name"), text(&patient, "last_name"));

    // 4. Ask for free 30-minute slots in the week starting 30 days from tomorrow (UTC date; close enough for a search window).
    let from = OffsetDateTime::now_utc().date() + Duration::days(1);
    let query = format!("/vacancies?from={}&to={}&duration=30", from, from + Duration::days(30));
    let vacancies = api.call("GET", &query, None)?["vacancies"].as_array().cloned().unwrap_or_default();
    let [first, second, ..] = vacancies.as_slice() else { panic!("the practice has fewer than two free slots in the next 30 days") };
    println!("4. Free slots found: {} and {}", slot(first), slot(second));

    // 5. Book the first one.
    let mut entry = api.call("POST", "/entries", Some(json!({ "entry": {
        "entry_type_id": entry_type["id"], "entry_state_id": state["id"],
        "booked_for": first["booked_for"], "start_time": first["start_time"], "end_time": first["end_time"],
        "note": "Booked by the API example",
        "patient_symptoms_attributes": [{ "patient_id": patient["id"], "symptom_id": symptom["id"] }]
    } })))?["entry"].clone();
    println!("5. Appointment booked: {}", slot(&entry));

    // 6. Move it to the second one.
    entry = api.call("PATCH", &format!("/entries/{}", entry["id"]), Some(json!({ "entry": {
        "booked_for": second["booked_for"], "start_time": second["start_time"], "end_time": second["end_time"]
    } })))?["entry"].clone();
    println!("6. Appointment moved: {}", slot(&entry));

    // 7. Errors: a patient without a last name is refused with 422 and a list of reasons.
    match api.call("POST", "/patients", Some(json!({ "patient": { "first_name": "Jan" } }))) {
        Ok(_) => panic!("the API accepted an invalid patient"),
        Err(error) => println!("7. Invalid patient refused: HTTP {}, attribute {}", error.status, text(&error.errors[0], "attribute")),
    }

    // 8. Clean up: delete the appointment, deactivate the patient.
    api.call("DELETE", &format!("/entries/{}", entry["id"]), None)?;
    api.call("DELETE", &format!("/patients/{}", patient["id"]), None)?;
    println!("8. Cleaned up");
    Ok(())
}
