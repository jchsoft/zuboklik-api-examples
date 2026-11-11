// Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
// survive a repeated request, and read "what changed since last time" (deletions included).
// C++17 with libcurl and nlohmann/json.
// Usage:  cmake -B build && cmake --build build && ZUBOKLIK_API_KEY=... ./build/sync

#include <cstdlib>
#include <ctime>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include <curl/curl.h>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

static std::string env_or(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);
    return value && *value ? value : fallback;
}

// The current UTC time as ISO 8601, e.g. 2026-11-10T21:42:25Z.
static std::string now_iso8601() {
    const std::time_t now = std::time(nullptr);
    char buffer[21];
    std::strftime(buffer, sizeof buffer, "%Y-%m-%dT%H:%M:%SZ", std::gmtime(&now));
    return buffer;
}

static const std::string API_URL = env_or("ZUBOKLIK_API_URL", "https://zuboklik.cz/api/v1");
static const std::string API_KEY = env_or("ZUBOKLIK_API_KEY", "");
// Where to start reading changes. A real integration stores the cursor of the last change it processed
// and never needs this; the example starts "now" unless told otherwise.
static const std::string SINCE = env_or("ZUBOKLIK_SYNC_SINCE", now_iso8601());
static const std::string EXTERNAL_ID = "example-patient-1"; // the id of this patient in YOUR system

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array, `body` the whole parsed response.
struct ApiError : std::runtime_error {
    long status;
    json errors;
    json body;
    ApiError(long status, json body)
        : std::runtime_error("HTTP " + std::to_string(status) + ": " + body.dump()),
          status(status),
          errors(body.is_object() ? body.value("errors", json::array()) : json::array()),
          body(std::move(body)) {}
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
    if (status < 200 || status >= 300) throw ApiError(status, std::move(parsed));
    return parsed;
}

static std::string text_of(const json& item, const char* key) { return item[key].get<std::string>(); }

static std::string id_of(const json& item) { return std::to_string(item["id"].get<long>()); }

// Percent-encodes a value for the query string.
static std::string url_encode(const std::string& value) {
    char* escaped = curl_easy_escape(nullptr, value.c_str(), static_cast<int>(value.size()));
    if (!escaped) throw std::runtime_error("curl_easy_escape failed");
    const std::string encoded = escaped;
    curl_free(escaped);
    return encoded;
}

// What your system does with one change. A webhook delivery has the same fields, so the same code handles both.
// Returns a line describing what was done.
static std::string apply(const json& change) {
    const std::string collection = change["resource_type"] == "Patient" ? "patients" : "entries";
    const std::string event = text_of(change, "event");
    if (change["action"] == "destroy") return event + ": removed from our system";
    try {
        api("GET", "/" + collection + "/" + std::to_string(change["resource_id"].get<long>())); // the current state of the record; save it on your side
        return event + ": saved to our system";
    } catch (const ApiError& error) {
        if (error.status != 404) throw;
        return event + ": already gone, removed from our system"; // deleted again before we asked
    }
}

int main() try {
    if (API_KEY.empty()) throw std::runtime_error("set ZUBOKLIK_API_KEY");
    curl_global_init(CURL_GLOBAL_DEFAULT);

    const json new_patient = {{"patient", {
        {"first_name", "Eva"}, {"last_name", "Ukázková"}, {"phone_number", "+420777111222"}, {"external_id", EXTERNAL_ID},
    }}};

    // 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
    //    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
    json found = api("GET", "/patients?external_id=" + EXTERNAL_ID)["patients"];
    const json patient = found.empty() ? api("POST", "/patients", new_patient)["patient"] : found[0];
    std::cout << "1. Patient paired: " << text_of(patient, "first_name") << " " << text_of(patient, "last_name")
              << ", external_id " << text_of(patient, "external_id") << "\n";

    // 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
    try {
        api("POST", "/patients", new_patient);
        throw std::runtime_error("the API created the same patient twice");
    } catch (const ApiError& error) {
        const bool same = error.body.value("/patient/id"_json_pointer, json()) == patient["id"];
        std::cout << "2. Repeated request created nothing: HTTP " << error.status << ", " << text_of(error.errors[0], "name")
                  << ", same patient: " << (same ? "true" : "false") << "\n";
    }

    // 3. From now on find the record by your own id.
    found = api("GET", "/patients?external_id=" + EXTERNAL_ID)["patients"];
    std::cout << "3. Found by external_id: " << found.size() << " patient(s)\n";

    // 4. What changed in the practice since last time? Page by cursor until `more` is false.
    //    Changes made by this key are left out; you see what the staff, the patients and other systems did.
    std::vector<std::string> applied;
    std::string query = "since=" + url_encode(SINCE);
    for (;;) {
        const json page = api("GET", "/changes?" + query);
        for (const auto& change : page["changes"]) applied.push_back(apply(change));
        if (!page["meta"]["more"].get<bool>()) break;

        query = "after=" + text_of(page["meta"], "next_cursor"); // store this cursor; next time start from it
    }
    std::cout << "4. Changes from the practice: " << applied.size() << "\n";
    for (const auto& line : applied) std::cout << "   " << line << "\n";

    // 5. Clean up: give the external_id back, then deactivate the patient.
    api("PATCH", "/patients/" + id_of(patient), {{"patient", {{"external_id", nullptr}}}});
    api("DELETE", "/patients/" + id_of(patient));
    std::cout << "5. Cleaned up\n";

    curl_global_cleanup();
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    return 1;
}
