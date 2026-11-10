// Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
// Runs as a Kotlin script (Kotlin 1.9+, JDK 17+).  Usage:  ZUBOKLIK_API_KEY=... kotlin patients.main.kts

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
val http: HttpClient = HttpClient.newHttpClient()
val gson = Gson()

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array of the response.
class ApiError(val status: Int, val errors: JsonArray) : RuntimeException("HTTP $status: $errors")

// One request. Returns the parsed JSON body (null for 204 No Content).
fun api(method: String, path: String, body: Map<String, Any?>? = null, key: String = apiKey): JsonObject? {
    val publisher = if (body == null) HttpRequest.BodyPublishers.noBody() else HttpRequest.BodyPublishers.ofString(gson.toJson(body))
    val request = HttpRequest.newBuilder(URI.create(apiUrl + path))
        .header("Authorization", "Bearer $key")
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .method(method, publisher)
        .build()
    val response = http.send(request, HttpResponse.BodyHandlers.ofString())

    val parsed = if (response.body().isEmpty()) null else JsonParser.parseString(response.body()).asJsonObject
    if (response.statusCode() !in 200..299) throw ApiError(response.statusCode(), parsed?.getAsJsonArray("errors") ?: JsonArray())
    return parsed
}

// 1. Create two patients.
val jana = api("POST", "/patients", mapOf("patient" to mapOf(
    "first_name" to "Jana", "last_name" to "Ukázková", "phone_number" to "+420777111222",
)))!!.getAsJsonObject("patient")
val petr = api("POST", "/patients", mapOf("patient" to mapOf(
    "first_name" to "Petr", "last_name" to "Ukázkový", "email" to "petr.ukazkovy@example.com",
)))!!.getAsJsonObject("patient")
println("1. Patients created: ${jana["first_name"].asString} ${jana["last_name"].asString} and ${petr["first_name"].asString} ${petr["last_name"].asString}")
val janaId = jana["id"].asInt
val petrId = petr["id"].asInt

// 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
val patients = mutableListOf<JsonObject>()
var page = 1
while (true) {
    val list = api("GET", "/patients?page=$page&per_page=100")!!
    patients += list.getAsJsonArray("patients").map { it.asJsonObject }
    if (page >= list.getAsJsonObject("meta")["total_pages"].asInt) break
    page++
}
val ours = patients.count { it["id"].asInt in listOf(janaId, petrId) }
println("2. Patients listed: ${patients.size} on $page page(s), ours among them: $ours")

// 3. Read one patient.
val detail = api("GET", "/patients/$janaId")!!.getAsJsonObject("patient")
println("3. Patient read: ${detail["first_name"].asString} ${detail["last_name"].asString}")

// 4. Update: only the attributes you send change.
val updated = api("PATCH", "/patients/$janaId", mapOf("patient" to mapOf("email" to "jana.ukazkova@example.com")))!!.getAsJsonObject("patient")
println("4. Patient updated: ${updated["email"].asString}, still ${updated["last_name"].asString}")

// 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
api("DELETE", "/patients/$janaId")
api("DELETE", "/patients/$petrId")
println("5. Patients deactivated")

// 6. A deactivated (or unknown) patient answers 404.
try {
    api("GET", "/patients/$janaId")
    error("the API still returns a deactivated patient")
} catch (e: ApiError) {
    println("6. Deactivated patient not found: HTTP ${e.status}, ${e.errors[0].asJsonObject["name"].asString}")
}

// 7. A wrong key answers 401.
try {
    api("GET", "/patients", key = "not-a-valid-key")
    error("the API accepted a wrong key")
} catch (e: ApiError) {
    println("7. Wrong key refused: HTTP ${e.status}, ${e.errors[0].asJsonObject["name"].asString}")
}
