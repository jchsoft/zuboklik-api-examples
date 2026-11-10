// Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
// Usage:  ZUBOKLIK_API_KEY=... cargo run --quiet --bin patients

use serde_json::{json, Value};
use std::env;

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
        self.call_with_key(&self.key, method, path, body)
    }

    /// The same request with another key than the configured one.
    fn call_with_key(&self, key: &str, method: &str, path: &str, body: Option<Value>) -> Result<Value, ApiError> {
        let request = ureq::request(method, &format!("{}{}", self.url, path))
            .set("Authorization", &format!("Bearer {key}"))
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

fn text<'a>(item: &'a Value, key: &str) -> &'a str {
    item[key].as_str().unwrap_or("")
}

fn main() -> Result<(), ApiError> {
    let api = Api {
        url: env::var("ZUBOKLIK_API_URL").unwrap_or_else(|_| "https://zuboklik.cz/api/v1".into()),
        key: env::var("ZUBOKLIK_API_KEY").expect("set ZUBOKLIK_API_KEY"),
    };

    // 1. Create two patients.
    let jana = api.call("POST", "/patients", Some(json!({ "patient": {
        "first_name": "Jana", "last_name": "Ukázková", "phone_number": "+420777111222"
    } })))?["patient"].clone();
    let petr = api.call("POST", "/patients", Some(json!({ "patient": {
        "first_name": "Petr", "last_name": "Ukázkový", "email": "petr.ukazkovy@example.com"
    } })))?["patient"].clone();
    println!(
        "1. Patients created: {} {} and {} {}",
        text(&jana, "first_name"), text(&jana, "last_name"), text(&petr, "first_name"), text(&petr, "last_name")
    );

    // 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
    let mut patients: Vec<Value> = Vec::new();
    let mut page = 1;
    loop {
        let list = api.call("GET", &format!("/patients?page={page}&per_page=100"), None)?;
        patients.extend(list["patients"].as_array().cloned().unwrap_or_default());
        if page >= list["meta"]["total_pages"].as_i64().expect("meta.total_pages") {
            break;
        }
        page += 1;
    }
    let ours = patients.iter().filter(|patient| patient["id"] == jana["id"] || patient["id"] == petr["id"]).count();
    println!("2. Patients listed: {} on {} page(s), ours among them: {}", patients.len(), page, ours);

    // 3. Read one patient.
    let detail = api.call("GET", &format!("/patients/{}", jana["id"]), None)?["patient"].clone();
    println!("3. Patient read: {} {}", text(&detail, "first_name"), text(&detail, "last_name"));

    // 4. Update: only the attributes you send change.
    let updated = api.call("PATCH", &format!("/patients/{}", jana["id"]), Some(json!({ "patient": {
        "email": "jana.ukazkova@example.com"
    } })))?["patient"].clone();
    println!("4. Patient updated: {}, still {}", text(&updated, "email"), text(&updated, "last_name"));

    // 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
    api.call("DELETE", &format!("/patients/{}", jana["id"]), None)?;
    api.call("DELETE", &format!("/patients/{}", petr["id"]), None)?;
    println!("5. Patients deactivated");

    // 6. A deactivated (or unknown) patient answers 404.
    match api.call("GET", &format!("/patients/{}", jana["id"]), None) {
        Ok(_) => panic!("the API still returns a deactivated patient"),
        Err(error) => println!("6. Deactivated patient not found: HTTP {}, {}", error.status, text(&error.errors[0], "name")),
    }

    // 7. A wrong key answers 401.
    match api.call_with_key("not-a-valid-key", "GET", "/patients", None) {
        Ok(_) => panic!("the API accepted a wrong key"),
        Err(error) => println!("7. Wrong key refused: HTTP {}, {}", error.status, text(&error.errors[0], "name")),
    }
    Ok(())
}
