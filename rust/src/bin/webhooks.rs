// Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
// Usage:  ZUBOKLIK_API_KEY=... cargo run --quiet --bin webhooks
// How to verify what the webhook then receives: verify_webhook.rs.

use serde_json::{json, Value};
use std::env;

const WEBHOOK_URL: &str = "https://example.com/zuboklik-webhook"; // your endpoint; must be https and publicly reachable

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

fn text<'a>(item: &'a Value, key: &str) -> &'a str {
    item[key].as_str().unwrap_or("")
}

fn active_count(api: &Api) -> Result<usize, ApiError> {
    let webhooks = api.call("GET", "/webhooks", None)?["webhooks"].as_array().cloned().unwrap_or_default();
    Ok(webhooks.iter().filter(|webhook| webhook["status"] == "active").count())
}

fn main() -> Result<(), ApiError> {
    let api = Api {
        url: env::var("ZUBOKLIK_API_URL").unwrap_or_else(|_| "https://zuboklik.cz/api/v1".into()),
        key: env::var("ZUBOKLIK_API_KEY").expect("set ZUBOKLIK_API_KEY"),
    };

    // 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
    let registered = api.call("POST", "/webhooks", Some(json!({ "webhook": { "url": WEBHOOK_URL } })))?;
    let webhook = &registered["webhook"];
    println!(
        "1. Webhook registered: {} ({}, secret of {} characters)",
        text(webhook, "url"), text(webhook, "status"), text(&registered, "secret").chars().count()
    );

    // 2. List the webhooks of this connected system.
    println!("2. Webhooks listed: {} active", active_count(&api)?);

    // 3. A URL that is not https (or points to a private address) is refused with 422.
    match api.call("POST", "/webhooks", Some(json!({ "webhook": { "url": "http://example.com/zuboklik-webhook" } }))) {
        Ok(_) => panic!("the API accepted a plain http URL"),
        Err(error) => println!("3. Plain http refused: HTTP {}, attribute {}", error.status, text(&error.errors[0], "attribute")),
    }

    // 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
    api.call("DELETE", &format!("/webhooks/{}", webhook["id"]), None)?;
    println!("4. Webhook switched off, {} active", active_count(&api)?);
    Ok(())
}
