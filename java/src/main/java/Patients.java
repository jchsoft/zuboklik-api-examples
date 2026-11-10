// Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
// Runs on Java 17+ with Maven.  Usage:  ZUBOKLIK_API_KEY=... mvn -q compile exec:java -Dexec.mainClass=Patients

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Optional;

public class Patients {
    static final String API_URL = Optional.ofNullable(System.getenv("ZUBOKLIK_API_URL")).orElse("https://zuboklik.cz/api/v1");
    static final String API_KEY = System.getenv("ZUBOKLIK_API_KEY");
    static final HttpClient HTTP = HttpClient.newHttpClient();

    // Thrown for every non-2xx answer. `errors` is the parsed "errors" array of the response.
    static class ApiError extends RuntimeException {
        final int status;
        final JsonArray errors;

        ApiError(int status, JsonArray errors) {
            super("HTTP " + status + ": " + errors);
            this.status = status;
            this.errors = errors;
        }
    }

    // One request. Returns the parsed JSON body (null for 204 No Content).
    static JsonObject api(String method, String path, JsonObject body) throws Exception {
        return api(method, path, body, API_KEY);
    }

    // The same with another key than the one from the environment.
    static JsonObject api(String method, String path, JsonObject body, String key) throws Exception {
        HttpRequest request = HttpRequest.newBuilder(URI.create(API_URL + path))
                .header("Authorization", "Bearer " + key)
                .header("Accept", "application/json")
                .header("Content-Type", "application/json")
                .method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body.toString()))
                .build();
        HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());

        JsonObject parsed = response.body().isEmpty() ? null : JsonParser.parseString(response.body()).getAsJsonObject();
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new ApiError(response.statusCode(), parsed != null && parsed.has("errors") ? parsed.getAsJsonArray("errors") : new JsonArray());
        }
        return parsed;
    }

    static JsonObject wrap(String key, JsonObject value) {
        JsonObject result = new JsonObject();
        result.add(key, value);
        return result;
    }

    static String text(JsonObject item, String key) {
        return item.get(key).getAsString();
    }

    public static void main(String[] args) throws Exception {
        if (API_KEY == null) throw new IllegalStateException("set ZUBOKLIK_API_KEY");

        // 1. Create two patients.
        JsonObject newJana = new JsonObject();
        newJana.addProperty("first_name", "Jana");
        newJana.addProperty("last_name", "Ukázková");
        newJana.addProperty("phone_number", "+420777111222");
        JsonObject jana = api("POST", "/patients", wrap("patient", newJana)).getAsJsonObject("patient");
        JsonObject newPetr = new JsonObject();
        newPetr.addProperty("first_name", "Petr");
        newPetr.addProperty("last_name", "Ukázkový");
        newPetr.addProperty("email", "petr.ukazkovy@example.com");
        JsonObject petr = api("POST", "/patients", wrap("patient", newPetr)).getAsJsonObject("patient");
        System.out.println("1. Patients created: " + text(jana, "first_name") + " " + text(jana, "last_name")
                + " and " + text(petr, "first_name") + " " + text(petr, "last_name"));
        int janaId = jana.get("id").getAsInt();
        int petrId = petr.get("id").getAsInt();

        // 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
        JsonArray patients = new JsonArray();
        int page = 1;
        while (true) {
            JsonObject list = api("GET", "/patients?page=" + page + "&per_page=100", null);
            patients.addAll(list.getAsJsonArray("patients"));
            if (page >= list.getAsJsonObject("meta").get("total_pages").getAsInt()) break;
            page++;
        }
        int ours = 0;
        for (JsonElement patient : patients) {
            int id = patient.getAsJsonObject().get("id").getAsInt();
            if (id == janaId || id == petrId) ours++;
        }
        System.out.println("2. Patients listed: " + patients.size() + " on " + page + " page(s), ours among them: " + ours);

        // 3. Read one patient.
        JsonObject detail = api("GET", "/patients/" + janaId, null).getAsJsonObject("patient");
        System.out.println("3. Patient read: " + text(detail, "first_name") + " " + text(detail, "last_name"));

        // 4. Update: only the attributes you send change.
        JsonObject changes = new JsonObject();
        changes.addProperty("email", "jana.ukazkova@example.com");
        JsonObject updated = api("PATCH", "/patients/" + janaId, wrap("patient", changes)).getAsJsonObject("patient");
        System.out.println("4. Patient updated: " + text(updated, "email") + ", still " + text(updated, "last_name"));

        // 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
        api("DELETE", "/patients/" + janaId, null);
        api("DELETE", "/patients/" + petrId, null);
        System.out.println("5. Patients deactivated");

        // 6. A deactivated (or unknown) patient answers 404.
        try {
            api("GET", "/patients/" + janaId, null);
            throw new IllegalStateException("the API still returns a deactivated patient");
        } catch (ApiError error) {
            System.out.println("6. Deactivated patient not found: HTTP " + error.status + ", " + text(error.errors.get(0).getAsJsonObject(), "name"));
        }

        // 7. A wrong key answers 401.
        try {
            api("GET", "/patients", null, "not-a-valid-key");
            throw new IllegalStateException("the API accepted a wrong key");
        } catch (ApiError error) {
            System.out.println("7. Wrong key refused: HTTP " + error.status + ", " + text(error.errors.get(0).getAsJsonObject(), "name"));
        }
    }
}
