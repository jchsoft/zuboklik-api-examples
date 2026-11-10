// Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
// C++17 with libcurl and nlohmann/json.
// Usage:  cmake -B build && cmake --build build && ZUBOKLIK_API_KEY=... ./build/booking

#include <cstdlib>
#include <ctime>
#include <iostream>
#include <stdexcept>
#include <string>

#include <curl/curl.h>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

static std::string env_or(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);
    return value && *value ? value : fallback;
}

static const std::string API_URL = env_or("ZUBOKLIK_API_URL", "https://zuboklik.cz/api/v1");
static const std::string API_KEY = env_or("ZUBOKLIK_API_KEY", "");

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array of the response.
struct ApiError : std::runtime_error {
    long status;
    json errors;
    ApiError(long status, json errors)
        : std::runtime_error("HTTP " + std::to_string(status) + ": " + errors.dump()), status(status), errors(std::move(errors)) {}
};

static size_t collect(char* data, size_t size, size_t count, void* target) {
    static_cast<std::string*>(target)->append(data, size * count);
    return size * count;
}

// One request. Returns the parsed JSON body (null for 204 No Content).
static json api(const std::string& method, const std::string& path, const json& body = nullptr) {
    CURL* curl = curl_easy_init();
    if (!curl) throw std::runtime_error("curl_easy_init failed");

    std::string text;
    const std::string url = API_URL + path;
    const std::string payload = body.is_null() ? "" : body.dump();
    curl_slist* headers = nullptr;
    headers = curl_slist_append(headers, ("Authorization: Bearer " + API_KEY).c_str());
    headers = curl_slist_append(headers, "Accept: application/json");
    headers = curl_slist_append(headers, "Content-Type: application/json");

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, collect);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &text);
    if (!body.is_null()) curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload.c_str());

    const CURLcode result = curl_easy_perform(curl);
    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    if (result != CURLE_OK) throw std::runtime_error(curl_easy_strerror(result));

    json parsed = text.empty() ? json(nullptr) : json::parse(text);
    if (status < 200 || status >= 300) throw ApiError(status, parsed.is_object() ? parsed.value("errors", json::array()) : json::array());
    return parsed;
}

static json find_by_code(const json& items, const std::string& code) {
    for (const auto& item : items)
        if (item["code"] == code) return item;
    throw std::runtime_error("code " + code + " not found");
}

static std::string text_of(const json& item, const char* key) { return item[key].get<std::string>(); }

// "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
static std::string slot(const json& item) {
    return text_of(item, "booked_for") + " " + text_of(item, "start_time").substr(11, 5) + "-" + text_of(item, "end_time").substr(11, 5);
}

static json times(const json& item) {
    return {{"booked_for", item["booked_for"]}, {"start_time", item["start_time"]}, {"end_time", item["end_time"]}};
}

// Local calendar date `days` from today as YYYY-MM-DD.
static std::string date_in(int days) {
    std::time_t now = std::time(nullptr);
    std::tm day = *std::localtime(&now);
    day.tm_mday += days;
    std::mktime(&day); // normalizes the overflowed day of month
    char buffer[11];
    std::strftime(buffer, sizeof buffer, "%Y-%m-%d", &day);
    return buffer;
}

static std::string id_of(const json& item) { return std::to_string(item["id"].get<long>()); }

int main() try {
    if (API_KEY.empty()) throw std::runtime_error("set ZUBOKLIK_API_KEY");
    curl_global_init(CURL_GLOBAL_DEFAULT);

    // 1. Check the connection and the key.
    std::cout << "1. API is up (" << text_of(api("GET", ""), "version") << ")\n";

    // 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
    const json symptom = find_by_code(api("GET", "/symptoms")["symptoms"], "without_complications");
    const json type = find_by_code(api("GET", "/entry_types")["entry_types"], "prevention");
    const json state = find_by_code(api("GET", "/entry_states")["entry_states"], "reserved");
    std::cout << "2. Catalogs loaded: symptom " << text_of(symptom, "code") << ", type " << text_of(type, "code")
              << ", state " << text_of(state, "code") << "\n";

    // 3. Create a patient.
    const json patient = api("POST", "/patients", {{"patient", {
        {"first_name", "Jan"}, {"last_name", "Ukázkový"}, {"phone_number", "+420777111222"}, {"email", "jan.ukazkovy@example.com"},
    }}})["patient"];
    std::cout << "3. Patient created: " << text_of(patient, "first_name") << " " << text_of(patient, "last_name") << "\n";

    // 4. Ask for free 30-minute slots in the next 30 days.
    const json vacancies = api("GET", "/vacancies?from=" + date_in(1) + "&to=" + date_in(31) + "&duration=30")["vacancies"];
    if (vacancies.size() < 2) throw std::runtime_error("the practice has fewer than two free slots in the next 30 days");
    const json first = vacancies[0], second = vacancies[1];
    std::cout << "4. Free slots found: " << slot(first) << " and " << slot(second) << "\n";

    // 5. Book the first one.
    json booking = times(first);
    booking["entry_type_id"] = type["id"];
    booking["entry_state_id"] = state["id"];
    booking["note"] = "Booked by the API example";
    booking["patient_symptoms_attributes"] = json::array({{{"patient_id", patient["id"]}, {"symptom_id", symptom["id"]}}});
    json entry = api("POST", "/entries", {{"entry", booking}})["entry"];
    std::cout << "5. Appointment booked: " << slot(entry) << "\n";

    // 6. Booking the same slot again is refused with 409 and its own error name, so code can react to it.
    try {
        api("POST", "/entries", {{"entry", booking}});
        throw std::runtime_error("the API booked one slot twice");
    } catch (const ApiError& error) {
        std::cout << "6. Same slot refused: HTTP " << error.status << ", " << text_of(error.errors[0], "name") << "\n";
    }

    // 7. Move the appointment to the second slot.
    entry = api("PATCH", "/entries/" + id_of(entry), {{"entry", times(second)}})["entry"];
    std::cout << "7. Appointment moved: " << slot(entry) << "\n";

    // 8. Read it back: the detail carries the patient and the note.
    entry = api("GET", "/entries/" + id_of(entry))["entry"];
    std::cout << "8. Appointment read: " << text_of(entry["patient"], "last_name") << ", note \"" << text_of(entry, "note") << "\"\n";

    // 9. Errors: a patient without a last name is refused with 422 and a list of reasons.
    try {
        api("POST", "/patients", {{"patient", {{"first_name", "Jan"}}}});
        throw std::runtime_error("the API accepted an invalid patient");
    } catch (const ApiError& error) {
        std::cout << "9. Invalid patient refused: HTTP " << error.status << ", attribute " << text_of(error.errors[0], "attribute") << "\n";
    }

    // 10. Clean up: delete the appointment, deactivate the patient.
    api("DELETE", "/entries/" + id_of(entry));
    api("DELETE", "/patients/" + id_of(patient));
    std::cout << "10. Cleaned up\n";

    curl_global_cleanup();
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    return 1;
}
