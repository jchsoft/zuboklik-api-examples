// Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
// Runs on Java 17+ with Maven.  Usage:  ZUBOKLIK_API_KEY=... mvn -q compile exec:java -Dexec.mainClass=Booking

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.LocalDate;
import java.util.Optional;

public class Booking {
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
        HttpRequest request = HttpRequest.newBuilder(URI.create(API_URL + path))
                .header("Authorization", "Bearer " + API_KEY)
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

    static JsonObject findByCode(JsonArray items, String code) {
        for (JsonElement item : items) {
            if (item.getAsJsonObject().get("code").getAsString().equals(code)) return item.getAsJsonObject();
        }
        throw new IllegalStateException("code " + code + " not found");
    }

    // "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
    static String slot(JsonObject item) {
        return item.get("booked_for").getAsString() + " " + item.get("start_time").getAsString().substring(11, 16)
                + "-" + item.get("end_time").getAsString().substring(11, 16);
    }

    static JsonObject times(JsonObject item) {
        JsonObject result = new JsonObject();
        for (String key : new String[] {"booked_for", "start_time", "end_time"}) result.add(key, item.get(key));
        return result;
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

        // 1. Check the connection and the key.
        System.out.println("1. API is up (" + text(api("GET", "", null), "version") + ")");

        // 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
        JsonObject symptom = findByCode(api("GET", "/symptoms", null).getAsJsonArray("symptoms"), "without_complications");
        JsonObject type = findByCode(api("GET", "/entry_types", null).getAsJsonArray("entry_types"), "prevention");
        JsonObject state = findByCode(api("GET", "/entry_states", null).getAsJsonArray("entry_states"), "reserved");
        System.out.println("2. Catalogs loaded: symptom " + text(symptom, "code") + ", type " + text(type, "code") + ", state " + text(state, "code"));

        // 3. Create a patient.
        JsonObject newPatient = new JsonObject();
        newPatient.addProperty("first_name", "Jan");
        newPatient.addProperty("last_name", "Ukázkový");
        newPatient.addProperty("phone_number", "+420777111222");
        newPatient.addProperty("email", "jan.ukazkovy@example.com");
        JsonObject patient = api("POST", "/patients", wrap("patient", newPatient)).getAsJsonObject("patient");
        System.out.println("3. Patient created: " + text(patient, "first_name") + " " + text(patient, "last_name"));

        // 4. Ask for free 30-minute slots in the next 30 days.
        LocalDate from = LocalDate.now().plusDays(1);
        JsonArray vacancies = api("GET", "/vacancies?from=" + from + "&to=" + from.plusDays(30) + "&duration=30", null).getAsJsonArray("vacancies");
        if (vacancies.size() < 2) throw new IllegalStateException("the practice has fewer than two free slots in the next 30 days");
        JsonObject first = vacancies.get(0).getAsJsonObject();
        JsonObject second = vacancies.get(1).getAsJsonObject();
        System.out.println("4. Free slots found: " + slot(first) + " and " + slot(second));

        // 5. Book the first one.
        JsonObject patientSymptom = new JsonObject();
        patientSymptom.add("patient_id", patient.get("id"));
        patientSymptom.add("symptom_id", symptom.get("id"));
        JsonArray patientSymptoms = new JsonArray();
        patientSymptoms.add(patientSymptom);

        JsonObject booking = times(first);
        booking.add("entry_type_id", type.get("id"));
        booking.add("entry_state_id", state.get("id"));
        booking.addProperty("note", "Booked by the API example");
        booking.add("patient_symptoms_attributes", patientSymptoms);
        JsonObject entry = api("POST", "/entries", wrap("entry", booking)).getAsJsonObject("entry");
        System.out.println("5. Appointment booked: " + slot(entry));

        // 6. Move it to the second one.
        entry = api("PATCH", "/entries/" + entry.get("id").getAsInt(), wrap("entry", times(second))).getAsJsonObject("entry");
        System.out.println("6. Appointment moved: " + slot(entry));

        // 7. Errors: a patient without a last name is refused with 422 and a list of reasons.
        JsonObject invalid = new JsonObject();
        invalid.addProperty("first_name", "Jan");
        try {
            api("POST", "/patients", wrap("patient", invalid));
            throw new IllegalStateException("the API accepted an invalid patient");
        } catch (ApiError error) {
            System.out.println("7. Invalid patient refused: HTTP " + error.status + ", attribute " + text(error.errors.get(0).getAsJsonObject(), "attribute"));
        }

        // 8. Clean up: delete the appointment, deactivate the patient.
        api("DELETE", "/entries/" + entry.get("id").getAsInt(), null);
        api("DELETE", "/patients/" + patient.get("id").getAsInt(), null);
        System.out.println("8. Cleaned up");
    }
}
