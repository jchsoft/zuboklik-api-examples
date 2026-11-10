// Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
// Runs as a Kotlin script (Kotlin 1.9+, JDK 17+).  Usage:  ZUBOKLIK_API_KEY=... kotlin webhooks.main.kts
// How to verify what the webhook then receives: verify_webhook.main.kts.

@file:DependsOn("com.google.code.gson:gson:2.11.0")

import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse

val apiUrl = System.getenv("ZUBOKLIK_API_URL") ?: "https://zuboklik.cz/api/v1"
val apiKey = System.getenv("ZUBOKLIK_API_KEY") ?: error("set ZUBOKLIK_API_KEY")
val webhookUrl = "https://example.com/zuboklik-webhook" // your endpoint; must be https and publicly reachable
val http: HttpClient = HttpClient.newHttpClient()
val gson = Gson()

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array of the response.
class ApiError(val status: Int, val errors: JsonArray) : RuntimeException("HTTP $status: $errors")

// One request. Returns the parsed JSON body (null for 204 No Content).
fun api(method: String, path: String, body: Map<String, Any?>? = null): JsonObject? {
    val publisher = if (body == null) HttpRequest.BodyPublishers.noBody() else HttpRequest.BodyPublishers.ofString(gson.toJson(body))
    val request = HttpRequest.newBuilder(URI.create(apiUrl + path))
        .header("Authorization", "Bearer $apiKey")
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .method(method, publisher)
        .build()
    val response = http.send(request, HttpResponse.BodyHandlers.ofString())

    val parsed = if (response.body().isEmpty()) null else JsonParser.parseString(response.body()).asJsonObject
    if (response.statusCode() !in 200..299) throw ApiError(response.statusCode(), parsed?.getAsJsonArray("errors") ?: JsonArray())
    return parsed
}

fun activeCount() = api("GET", "/webhooks")!!.getAsJsonArray("webhooks").count { it.asJsonObject["status"].asString == "active" }

// 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
val registered = api("POST", "/webhooks", mapOf("webhook" to mapOf("url" to webhookUrl)))!!
val webhook = registered.getAsJsonObject("webhook")
println("1. Webhook registered: ${webhook["url"].asString} (${webhook["status"].asString}, secret of ${registered["secret"].asString.length} characters)")

// 2. List the webhooks of this connected system.
println("2. Webhooks listed: ${activeCount()} active")

// 3. A URL that is not https (or points to a private address) is refused with 422.
try {
    api("POST", "/webhooks", mapOf("webhook" to mapOf("url" to "http://example.com/zuboklik-webhook")))
    error("the API accepted a plain http URL")
} catch (e: ApiError) {
    println("3. Plain http refused: HTTP ${e.status}, attribute ${e.errors[0].asJsonObject["attribute"].asString}")
}

// 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
api("DELETE", "/webhooks/${webhook["id"].asInt}")
println("4. Webhook switched off, ${activeCount()} active")
