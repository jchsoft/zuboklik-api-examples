// Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
// Runs on Java 17+ with Maven.  Usage:  ZUBOKLIK_API_KEY=... mvn -q compile exec:java -Dexec.mainClass=Webhooks
// How to verify what the webhook then receives: VerifyWebhook.java.

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Optional;

public class Webhooks {
    static final String API_URL = Optional.ofNullable(System.getenv("ZUBOKLIK_API_URL")).orElse("https://zuboklik.cz/api/v1");
    static final String API_KEY = System.getenv("ZUBOKLIK_API_KEY");
    static final String WEBHOOK_URL = "https://example.com/zuboklik-webhook"; // your endpoint; must be https and publicly reachable
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

    static int activeCount() throws Exception {
        int count = 0;
        for (JsonElement webhook : api("GET", "/webhooks", null).getAsJsonArray("webhooks")) {
            if (text(webhook.getAsJsonObject(), "status").equals("active")) count++;
        }
        return count;
    }

    // {"webhook": {"url": url}}
    static JsonObject webhookWith(String url) {
        JsonObject attributes = new JsonObject();
        attributes.addProperty("url", url);
        JsonObject result = new JsonObject();
        result.add("webhook", attributes);
        return result;
    }

    static String text(JsonObject item, String key) {
        return item.get(key).getAsString();
    }

    public static void main(String[] args) throws Exception {
        if (API_KEY == null) throw new IllegalStateException("set ZUBOKLIK_API_KEY");

        // 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
        JsonObject registered = api("POST", "/webhooks", webhookWith(WEBHOOK_URL));
        JsonObject webhook = registered.getAsJsonObject("webhook");
        System.out.println("1. Webhook registered: " + text(webhook, "url") + " (" + text(webhook, "status")
                + ", secret of " + text(registered, "secret").length() + " characters)");

        // 2. List the webhooks of this connected system.
        System.out.println("2. Webhooks listed: " + activeCount() + " active");

        // 3. A URL that is not https (or points to a private address) is refused with 422.
        try {
            api("POST", "/webhooks", webhookWith("http://example.com/zuboklik-webhook"));
            throw new IllegalStateException("the API accepted a plain http URL");
        } catch (ApiError error) {
            System.out.println("3. Plain http refused: HTTP " + error.status + ", attribute " + text(error.errors.get(0).getAsJsonObject(), "attribute"));
        }

        // 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
        api("DELETE", "/webhooks/" + webhook.get("id").getAsInt(), null);
        System.out.println("4. Webhook switched off, " + activeCount() + " active");
    }
}
