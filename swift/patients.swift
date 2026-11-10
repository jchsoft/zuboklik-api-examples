// Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
// Runs on Swift 5.9+, Foundation only.  Usage:  ZUBOKLIK_API_KEY=... swift patients.swift

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

typealias JSON = [String: Any]

let environment = ProcessInfo.processInfo.environment
let apiURL = environment["ZUBOKLIK_API_URL"] ?? "https://zuboklik.cz/api/v1"
guard let apiKey = environment["ZUBOKLIK_API_KEY"] else { fatalError("set ZUBOKLIK_API_KEY") }

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array of the response.
struct ApiError: Error {
    let status: Int
    let errors: [JSON]
}

// One request. Returns the parsed JSON body (empty for 204 No Content).
func api(_ method: String, _ path: String, _ body: JSON? = nil, key: String = apiKey) async throws -> JSON {
    var request = URLRequest(url: URL(string: apiURL + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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

// 1. Create two patients.
let jana = try await api("POST", "/patients", ["patient": ["first_name": "Jana", "last_name": "Ukázková", "phone_number": "+420777111222"]])["patient"] as! JSON
let petr = try await api("POST", "/patients", ["patient": ["first_name": "Petr", "last_name": "Ukázkový", "email": "petr.ukazkovy@example.com"]])["patient"] as! JSON
print("1. Patients created: \(text(jana, "first_name")) \(text(jana, "last_name")) and \(text(petr, "first_name")) \(text(petr, "last_name"))")

// 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
var patients: [JSON] = []
var page = 1
while true {
    let list = try await api("GET", "/patients?page=\(page)&per_page=100")
    patients += list["patients"] as? [JSON] ?? []
    if page >= (list["meta"] as! JSON)["total_pages"] as! Int { break }
    page += 1
}
let ourIds = [jana["id"] as! Int, petr["id"] as! Int]
let ours = patients.filter { ourIds.contains($0["id"] as! Int) }.count
print("2. Patients listed: \(patients.count) on \(page) page(s), ours among them: \(ours)")

// 3. Read one patient.
let detail = try await api("GET", "/patients/\(jana["id"]!)")["patient"] as! JSON
print("3. Patient read: \(text(detail, "first_name")) \(text(detail, "last_name"))")

// 4. Update: only the attributes you send change.
let updated = try await api("PATCH", "/patients/\(jana["id"]!)", ["patient": ["email": "jana.ukazkova@example.com"]])["patient"] as! JSON
print("4. Patient updated: \(text(updated, "email")), still \(text(updated, "last_name"))")

// 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
_ = try await api("DELETE", "/patients/\(jana["id"]!)")
_ = try await api("DELETE", "/patients/\(petr["id"]!)")
print("5. Patients deactivated")

// 6. A deactivated (or unknown) patient answers 404.
do {
    _ = try await api("GET", "/patients/\(jana["id"]!)")
    fatalError("the API still returns a deactivated patient")
} catch let error as ApiError {
    print("6. Deactivated patient not found: HTTP \(error.status), \(text(error.errors[0], "name"))")
}

// 7. A wrong key answers 401.
do {
    _ = try await api("GET", "/patients", key: "not-a-valid-key")
    fatalError("the API accepted a wrong key")
} catch let error as ApiError {
    print("7. Wrong key refused: HTTP \(error.status), \(text(error.errors[0], "name"))")
}
