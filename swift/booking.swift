// Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
// Runs on Swift 5.9+, Foundation only.  Usage:  ZUBOKLIK_API_KEY=... swift booking.swift

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

func findByCode(_ items: Any?, _ code: String) -> JSON {
    guard let found = (items as? [JSON])?.first(where: { $0["code"] as? String == code }) else { fatalError("code \(code) not found") }
    return found
}

func text(_ item: JSON, _ key: String) -> String { item[key] as? String ?? "" }

// "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
func slot(_ item: JSON) -> String {
    func hour(_ key: String) -> Substring { text(item, key).dropFirst(11).prefix(5) }
    return "\(text(item, "booked_for")) \(hour("start_time"))-\(hour("end_time"))"
}

func times(_ item: JSON) -> JSON {
    ["booked_for": text(item, "booked_for"), "start_time": text(item, "start_time"), "end_time": text(item, "end_time")]
}

// Local calendar date `days` from today as YYYY-MM-DD.
func dateIn(days: Int) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Calendar.current.date(byAdding: .day, value: days, to: Date())!)
}

// 1. Check the connection and the key.
print("1. API is up (\(text(try await api("GET", ""), "version")))")

// 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
let symptom = findByCode(try await api("GET", "/symptoms")["symptoms"], "without_complications")
let type = findByCode(try await api("GET", "/entry_types")["entry_types"], "prevention")
let state = findByCode(try await api("GET", "/entry_states")["entry_states"], "reserved")
print("2. Catalogs loaded: symptom \(text(symptom, "code")), type \(text(type, "code")), state \(text(state, "code"))")

// 3. Create a patient.
let patient = try await api("POST", "/patients", ["patient": [
    "first_name": "Jan", "last_name": "Ukázkový", "phone_number": "+420777111222", "email": "jan.ukazkovy@example.com",
]])["patient"] as! JSON
print("3. Patient created: \(text(patient, "first_name")) \(text(patient, "last_name"))")

// 4. Ask for free 30-minute slots in the next 30 days.
let vacancies = try await api("GET", "/vacancies?from=\(dateIn(days: 1))&to=\(dateIn(days: 31))&duration=30")["vacancies"] as? [JSON] ?? []
guard vacancies.count >= 2 else { fatalError("the practice has fewer than two free slots in the next 30 days") }
let (first, second) = (vacancies[0], vacancies[1])
print("4. Free slots found: \(slot(first)) and \(slot(second))")

// 5. Book the first one.
var booking = times(first)
booking["entry_type_id"] = type["id"]
booking["entry_state_id"] = state["id"]
booking["note"] = "Booked by the API example"
booking["patient_symptoms_attributes"] = [["patient_id": patient["id"]!, "symptom_id": symptom["id"]!]]
var entry = try await api("POST", "/entries", ["entry": booking])["entry"] as! JSON
print("5. Appointment booked: \(slot(entry))")

// 6. Move it to the second one.
entry = try await api("PATCH", "/entries/\(entry["id"]!)", ["entry": times(second)])["entry"] as! JSON
print("6. Appointment moved: \(slot(entry))")

// 7. Errors: a patient without a last name is refused with 422 and a list of reasons.
do {
    _ = try await api("POST", "/patients", ["patient": ["first_name": "Jan"]])
    fatalError("the API accepted an invalid patient")
} catch let error as ApiError {
    print("7. Invalid patient refused: HTTP \(error.status), attribute \(text(error.errors[0], "attribute"))")
}

// 8. Clean up: delete the appointment, deactivate the patient.
_ = try await api("DELETE", "/entries/\(entry["id"]!)")
_ = try await api("DELETE", "/patients/\(patient["id"]!)")
print("8. Cleaned up")
