// Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
// survive a repeated request, and read "what changed since last time" (deletions included).
// Runs on Java 17+ with Maven.  Usage:  ZUBOKLIK_API_KEY=... mvn -q compile exec:java -Dexec.mainClass=Sync

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

public class Sync {
    static final String API_URL = Optional.ofNullable(System.getenv("ZUBOKLIK_API_URL")).orElse("https://zuboklik.cz/api/v1");
    static final String API_KEY = System.getenv("ZUBOKLIK_API_KEY");
    // Where to start reading changes. A real integration stores the cursor of the last change it processed
    // and never needs this; the example starts "now" unless told otherwise.
    static final String SINCE = Optional.ofNullable(System.getenv("ZUBOKLIK_SYNC_SINCE")).orElseGet(() -> Instant.now().truncatedTo(ChronoUnit.SECONDS).toString());
    static final String EXTERNAL_ID = "example-patient-1"; // the id of this patient in YOUR system
    static final HttpClient HTTP = HttpClient.newHttpClient();

    // Thrown for every non-2xx answer. `errors` is the parsed "errors" array, `body` the whole parsed response.
    static class ApiError extends RuntimeException {
        final int status;
        final JsonArray errors;
        final JsonObject body;

        ApiError(int status, JsonObject body) {
            super("HTTP " + status + ": " + (body.has("errors") ? body.getAsJsonArray("errors") : new JsonArray()));
            this.status = status;
            this.body = body;
            this.errors = body.has("errors") ? body.getAsJsonArray("errors") : new JsonArray();
        }
    }

    // One request. Returns the parsed JSON body (null for 204 No Content).
    static JsonObject api(String method, String path, JsonObject body) throws Exception {
        HttpRequest request = HttpRequest.newBuilder(URI.create(API_URL + path))
                .header("Authorization", "Bearer " + API_KEY)
                .header("Accept", "application/json")
                .header("Content-Type", "application/json")
                .method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body.toString()))
                .build();
        HttpResponse<String> response = HTTP.send(request, HttpResponse.BodyHandlers.ofString());

        JsonObject parsed = response.body().isEmpty() ? null : JsonParser.parseString(response.body()).getAsJsonObject();
        if (response.statusCode() < 200 || response.statusCode() >= 300) {
            throw new ApiError(response.statusCode(), parsed != null ? parsed : new JsonObject());
        }
        return parsed;
    }

    // What your system does with one change. A webhook delivery has the same fields, so the same code handles both.
    // Returns a line describing what was done.
    static String apply(JsonObject change) throws Exception {
        String collection = text(change, "resource_type").equals("Patient") ? "patients" : "entries";
        if (text(change, "action").equals("destroy")) return text(change, "event") + ": removed from our system";

        try {
            api("GET", "/" + collection + "/" + text(change, "resource_id"), null); // the current state of the record; save it on your side
            return text(change, "event") + ": saved to our system";
        } catch (ApiError error) {
            if (error.status != 404) throw error;

            return text(change, "event") + ": already gone, removed from our system"; // deleted again before we asked
        }
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

        JsonObject eva = new JsonObject();
        eva.addProperty("first_name", "Eva");
        eva.addProperty("last_name", "Ukázková");
        eva.addProperty("phone_number", "+420777111222");
        eva.addProperty("external_id", EXTERNAL_ID);
        JsonObject newPatient = wrap("patient", eva);

        // 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
        //    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
        JsonArray found = api("GET", "/patients?external_id=" + EXTERNAL_ID, null).getAsJsonArray("patients");
        JsonObject patient = found.isEmpty() ? api("POST", "/patients", newPatient).getAsJsonObject("patient") : found.get(0).getAsJsonObject();
        System.out.println("1. Patient paired: " + text(patient, "first_name") + " " + text(patient, "last_name") + ", external_id " + text(patient, "external_id"));
        int patientId = patient.get("id").getAsInt();

        // 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
        try {
            api("POST", "/patients", newPatient);
            throw new IllegalStateException("the API created the same patient twice");
        } catch (ApiError error) {
            boolean same = error.body.has("patient") && error.body.getAsJsonObject("patient").get("id").getAsInt() == patientId;
            System.out.println("2. Repeated request created nothing: HTTP " + error.status + ", " + text(error.errors.get(0).getAsJsonObject(), "name") + ", same patient: " + same);
        }

        // 3. From now on find the record by your own id.
        found = api("GET", "/patients?external_id=" + EXTERNAL_ID, null).getAsJsonArray("patients");
        System.out.println("3. Found by external_id: " + found.size() + " patient(s)");

        // 4. What changed in the practice since last time? Page by cursor until `more` is false.
        //    Changes made by this key are left out; you see what the staff, the patients and other systems did.
        List<String> applied = new ArrayList<>();
        String query = "since=" + URLEncoder.encode(SINCE, StandardCharsets.UTF_8);
        while (true) {
            JsonObject page = api("GET", "/changes?" + query, null);
            for (JsonElement change : page.getAsJsonArray("changes")) applied.add(apply(change.getAsJsonObject()));
            if (!page.getAsJsonObject("meta").get("more").getAsBoolean()) break;

            query = "after=" + text(page.getAsJsonObject("meta"), "next_cursor"); // store this cursor; next time start from it
        }
        System.out.println("4. Changes from the practice: " + applied.size());
        for (String line : applied) System.out.println("   " + line);

        // 5. Clean up: give the external_id back, then deactivate the patient.
        JsonObject changes = new JsonObject();
        changes.add("external_id", JsonNull.INSTANCE);
        api("PATCH", "/patients/" + patientId, wrap("patient", changes));
        api("DELETE", "/patients/" + patientId, null);
        System.out.println("5. Cleaned up");
    }
}
