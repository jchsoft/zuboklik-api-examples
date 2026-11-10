// Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
// Runs on Swift 5.9+, Foundation only.  Usage:  ZUBOKLIK_API_KEY=... swift webhooks.swift
// How to verify what the webhook then receives: verify_webhook.swift.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

typealias JSON = [String: Any]

let environment = ProcessInfo.processInfo.environment
let apiURL = environment["ZUBOKLIK_API_URL"] ?? "https://zuboklik.cz/api/v1"
guard let apiKey = environment["ZUBOKLIK_API_KEY"] else { fatalError("set ZUBOKLIK_API_KEY") }
let webhookURL = "https://example.com/zuboklik-webhook" // your endpoint; must be https and publicly reachable

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array of the response.
struct ApiError: Error {
    let status: Int
    let errors: [JSON]
}

// One request. Returns the parsed JSON body (empty for 204 No Content).
func api(_ method: String, _ path: String, _ body: JSON? = nil) async throws -> JSON {
    var request = URLRequest(url: URL(string: apiURL + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

    let (data, response) = try await URLSession.shared.data(for: request)
    let parsed = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? JSON ?? [:])
    let status = (response as! HTTPURLResponse).statusCode
    guard (200..<300).contains(status) else { throw ApiError(status: status, errors: parsed["errors"] as? [JSON] ?? []) }
    return parsed
}

func text(_ item: JSON, _ key: String) -> String { item[key] as? String ?? "" }

func activeCount() async throws -> Int {
    let webhooks = try await api("GET", "/webhooks")["webhooks"] as? [JSON] ?? []
    return webhooks.filter { text($0, "status") == "active" }.count
}

// 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
let registered = try await api("POST", "/webhooks", ["webhook": ["url": webhookURL]])
let webhook = registered["webhook"] as! JSON
print("1. Webhook registered: \(text(webhook, "url")) (\(text(webhook, "status")), secret of \(text(registered, "secret").count) characters)")

// 2. List the webhooks of this connected system.
print("2. Webhooks listed: \(try await activeCount()) active")

// 3. A URL that is not https (or points to a private address) is refused with 422.
do {
    _ = try await api("POST", "/webhooks", ["webhook": ["url": "http://example.com/zuboklik-webhook"]])
    fatalError("the API accepted a plain http URL")
} catch let error as ApiError {
    print("3. Plain http refused: HTTP \(error.status), attribute \(text(error.errors[0], "attribute"))")
}

// 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
_ = try await api("DELETE", "/webhooks/\(webhook["id"]!)")
print("4. Webhook switched off, \(try await activeCount()) active")
