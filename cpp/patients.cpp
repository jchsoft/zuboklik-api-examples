// Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
// C++17 with libcurl and nlohmann/json.
// Usage:  cmake -B build && cmake --build build && ZUBOKLIK_API_KEY=... ./build/patients

#include <cstdlib>
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
static json api(const std::string& method, const std::string& path, const json& body = nullptr, const std::string& key = API_KEY) {
    CURL* curl = curl_easy_init();
    if (!curl) throw std::runtime_error("curl_easy_init failed");

    std::string text;
    const std::string url = API_URL + path;
    const std::string payload = body.is_null() ? "" : body.dump();
    curl_slist* headers = nullptr;
    headers = curl_slist_append(headers, ("Authorization: Bearer " + key).c_str());
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

static std::string text_of(const json& item, const char* key) { return item[key].get<std::string>(); }

static std::string id_of(const json& item) { return std::to_string(item["id"].get<long>()); }

int main() try {
    if (API_KEY.empty()) throw std::runtime_error("set ZUBOKLIK_API_KEY");
    curl_global_init(CURL_GLOBAL_DEFAULT);

    // 1. Create two patients.
    const json jana = api("POST", "/patients", {{"patient", {
        {"first_name", "Jana"}, {"last_name", "Ukázková"}, {"phone_number", "+420777111222"},
    }}})["patient"];
    const json petr = api("POST", "/patients", {{"patient", {
        {"first_name", "Petr"}, {"last_name", "Ukázkový"}, {"email", "petr.ukazkovy@example.com"},
    }}})["patient"];
    std::cout << "1. Patients created: " << text_of(jana, "first_name") << " " << text_of(jana, "last_name") << " and "
              << text_of(petr, "first_name") << " " << text_of(petr, "last_name") << "\n";

    // 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
    json patients = json::array();
    int page = 1;
    for (;; ++page) {
        const json list = api("GET", "/patients?page=" + std::to_string(page) + "&per_page=100");
        patients.insert(patients.end(), list["patients"].begin(), list["patients"].end());
        if (page >= list["meta"]["total_pages"].get<int>()) break;
    }
    int ours = 0;
    for (const auto& patient : patients)
        if (patient["id"] == jana["id"] || patient["id"] == petr["id"]) ++ours;
    std::cout << "2. Patients listed: " << patients.size() << " on " << page << " page(s), ours among them: " << ours << "\n";

    // 3. Read one patient.
    const json detail = api("GET", "/patients/" + id_of(jana))["patient"];
    std::cout << "3. Patient read: " << text_of(detail, "first_name") << " " << text_of(detail, "last_name") << "\n";

    // 4. Update: only the attributes you send change.
    const json updated = api("PATCH", "/patients/" + id_of(jana), {{"patient", {{"email", "jana.ukazkova@example.com"}}}})["patient"];
    std::cout << "4. Patient updated: " << text_of(updated, "email") << ", still " << text_of(updated, "last_name") << "\n";

    // 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
    api("DELETE", "/patients/" + id_of(jana));
    api("DELETE", "/patients/" + id_of(petr));
    std::cout << "5. Patients deactivated\n";

    // 6. A deactivated (or unknown) patient answers 404.
    try {
        api("GET", "/patients/" + id_of(jana));
        throw std::runtime_error("the API still returns a deactivated patient");
    } catch (const ApiError& error) {
        std::cout << "6. Deactivated patient not found: HTTP " << error.status << ", " << text_of(error.errors[0], "name") << "\n";
    }

    // 7. A wrong key answers 401.
    try {
        api("GET", "/patients", nullptr, "not-a-valid-key");
        throw std::runtime_error("the API accepted a wrong key");
    } catch (const ApiError& error) {
        std::cout << "7. Wrong key refused: HTTP " << error.status << ", " << text_of(error.errors[0], "name") << "\n";
    }

    curl_global_cleanup();
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    return 1;
}
