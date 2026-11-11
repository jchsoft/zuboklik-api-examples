// Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
// survive a repeated request, and read "what changed since last time" (deletions included).
// Runs on Swift 5.9+, Foundation only.  Usage:  ZUBOKLIK_API_KEY=... swift sync.swift

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

typealias JSON = [String: Any]

let environment = ProcessInfo.processInfo.environment
let apiURL = environment["ZUBOKLIK_API_URL"] ?? "https://zuboklik.cz/api/v1"
guard let apiKey = environment["ZUBOKLIK_API_KEY"] else { fatalError("set ZUBOKLIK_API_KEY") }
// Where to start reading changes. A real integration stores the cursor of the last change it processed
// and never needs this; the example starts "now" unless told otherwise.
let since = environment["ZUBOKLIK_SYNC_SINCE"] ?? ISO8601DateFormatter().string(from: Date())
let externalId = "example-patient-1" // the id of this patient in YOUR system

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array, `body` the whole parsed response.
struct ApiError: Error {
    let status: Int
    let errors: [JSON]
    let body: JSON
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
    guard (200..<300).contains(status) else { throw ApiError(status: status, errors: parsed["errors"] as? [JSON] ?? [], body: parsed) }
    return parsed
}

func text(_ item: JSON, _ key: String) -> String { item[key] as? String ?? "" }

// What your system does with one change. A webhook delivery has the same fields, so the same code handles both.
// Returns a line describing what was done.
func apply(_ change: JSON) async throws -> String {
    let event = text(change, "event")
    let collection = text(change, "resource_type") == "Patient" ? "patients" : "entries"
    if text(change, "action") == "destroy" { return "\(event): removed from our system" }
    do {
        _ = try await api("GET", "/\(collection)/\(change["resource_id"]!)") // the current state of the record; save it on your side
        return "\(event): saved to our system"
    } catch let error as ApiError where error.status == 404 {
        return "\(event): already gone, removed from our system" // deleted again before we asked
    }
}

let newPatient: JSON = ["patient": ["first_name": "Eva", "last_name": "Ukázková", "phone_number": "+420777111222", "external_id": externalId]]

// 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
//    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
var found = try await api("GET", "/patients?external_id=\(externalId)")["patients"] as! [JSON]
let patient: JSON
if let first = found.first {
    patient = first
} else {
    patient = try await api("POST", "/patients", newPatient)["patient"] as! JSON
}
print("1. Patient paired: \(text(patient, "first_name")) \(text(patient, "last_name")), external_id \(text(patient, "external_id"))")

// 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
do {
    _ = try await api("POST", "/patients", newPatient)
    fatalError("the API created the same patient twice")
} catch let error as ApiError {
    let same = (error.body["patient"] as? JSON)?["id"] as? Int == patient["id"] as? Int
    print("2. Repeated request created nothing: HTTP \(error.status), \(text(error.errors[0], "name")), same patient: \(same)")
}

// 3. From now on find the record by your own id.
found = try await api("GET", "/patients?external_id=\(externalId)")["patients"] as! [JSON]
print("3. Found by external_id: \(found.count) patient(s)")

// 4. What changed in the practice since last time? Page by cursor until `more` is false.
//    Changes made by this key are left out; you see what the staff, the patients and other systems did.
var applied: [String] = []
var query = "since=\(since.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
while true {
    let page = try await api("GET", "/changes?\(query)")
    for change in page["changes"] as! [JSON] { applied.append(try await apply(change)) }
    let meta = page["meta"] as! JSON
    if !(meta["more"] as! Bool) { break }
    query = "after=\(meta["next_cursor"]!)" // store this cursor; next time start from it
}
print("4. Changes from the practice: \(applied.count)")
for line in applied { print("   \(line)") }

// 5. Clean up: give the external_id back, then deactivate the patient.
_ = try await api("PATCH", "/patients/\(patient["id"]!)", ["patient": ["external_id": NSNull()]])
_ = try await api("DELETE", "/patients/\(patient["id"]!)")
print("5. Cleaned up")
