// Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
// C++17 with libcurl and nlohmann/json.
// Usage:  cmake -B build && cmake --build build && ZUBOKLIK_API_KEY=... ./build/webhooks
// How to verify what the webhook then receives: verify_webhook.cpp.

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
static const std::string WEBHOOK_URL = "https://example.com/zuboklik-webhook"; // your endpoint; must be https and publicly reachable

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

static std::string text_of(const json& item, const char* key) { return item[key].get<std::string>(); }

static std::string id_of(const json& item) { return std::to_string(item["id"].get<long>()); }

static int active_count() {
    const json webhooks = api("GET", "/webhooks")["webhooks"];
    int count = 0;
    for (const auto& webhook : webhooks)
        if (webhook["status"] == "active") ++count;
    return count;
}

int main() try {
    if (API_KEY.empty()) throw std::runtime_error("set ZUBOKLIK_API_KEY");
    curl_global_init(CURL_GLOBAL_DEFAULT);

    // 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
    const json registered = api("POST", "/webhooks", {{"webhook", {{"url", WEBHOOK_URL}}}});
    const json webhook = registered["webhook"];
    std::cout << "1. Webhook registered: " << text_of(webhook, "url") << " (" << text_of(webhook, "status") << ", secret of "
              << text_of(registered, "secret").size() << " characters)\n";

    // 2. List the webhooks of this connected system.
    std::cout << "2. Webhooks listed: " << active_count() << " active\n";

    // 3. A URL that is not https (or points to a private address) is refused with 422.
    try {
        api("POST", "/webhooks", {{"webhook", {{"url", "http://example.com/zuboklik-webhook"}}}});
        throw std::runtime_error("the API accepted a plain http URL");
    } catch (const ApiError& error) {
        std::cout << "3. Plain http refused: HTTP " << error.status << ", attribute " << text_of(error.errors[0], "attribute") << "\n";
    }

    // 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
    api("DELETE", "/webhooks/" + id_of(webhook));
    std::cout << "4. Webhook switched off, " << active_count() << " active\n";

    curl_global_cleanup();
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << "\n";
    return 1;
}
