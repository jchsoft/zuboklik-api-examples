// Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
// survive a repeated request, and read "what changed since last time" (deletions included).
// Runs as a Kotlin script (Kotlin 1.9+, JDK 17+).  Usage:  ZUBOKLIK_API_KEY=... kotlin sync.main.kts

@file:DependsOn("com.google.code.gson:gson:2.11.0")

import com.google.gson.GsonBuilder
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Instant
import java.time.temporal.ChronoUnit

val apiUrl = System.getenv("ZUBOKLIK_API_URL") ?: "https://zuboklik.cz/api/v1"
val apiKey = System.getenv("ZUBOKLIK_API_KEY") ?: error("set ZUBOKLIK_API_KEY")
// Where to start reading changes. A real integration stores the cursor of the last change it processed
// and never needs this; the example starts "now" unless told otherwise.
val since = System.getenv("ZUBOKLIK_SYNC_SINCE") ?: Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()
val externalId = "example-patient-1" // the id of this patient in YOUR system
val http: HttpClient = HttpClient.newHttpClient()
val gson = GsonBuilder().serializeNulls().create() // step 5 sends a JSON null, which a plain Gson() would leave out

// Thrown for every non-2xx answer. `errors` is the parsed "errors" array, `body` the whole parsed response.
class ApiError(val status: Int, val body: JsonObject) : RuntimeException("HTTP $status: ${body.getAsJsonArray("errors") ?: JsonArray()}") {
    val errors: JsonArray = body.getAsJsonArray("errors") ?: JsonArray()
}

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
    if (response.statusCode() !in 200..299) throw ApiError(response.statusCode(), parsed ?: JsonObject())
    return parsed
}

// What your system does with one change. A webhook delivery has the same fields, so the same code handles both.
// Returns a line describing what was done.
fun apply(change: JsonObject): String {
    val event = change["event"].asString
    val collection = if (change["resource_type"].asString == "Patient") "patients" else "entries"
    if (change["action"].asString == "destroy") return "$event: removed from our system"

    return try {
        api("GET", "/$collection/${change["resource_id"].asString}") // the current state of the record; save it on your side
        "$event: saved to our system"
    } catch (e: ApiError) {
        if (e.status != 404) throw e

        "$event: already gone, removed from our system" // deleted again before we asked
    }
}

val newPatient = mapOf("patient" to mapOf(
    "first_name" to "Eva", "last_name" to "Ukázková", "phone_number" to "+420777111222", "external_id" to externalId,
))

// 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
//    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
var found = api("GET", "/patients?external_id=$externalId")!!.getAsJsonArray("patients")
val patient = found.firstOrNull()?.asJsonObject ?: api("POST", "/patients", newPatient)!!.getAsJsonObject("patient")
println("1. Patient paired: ${patient["first_name"].asString} ${patient["last_name"].asString}, external_id ${patient["external_id"].asString}")
val patientId = patient["id"].asInt

// 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
try {
    api("POST", "/patients", newPatient)
    error("the API created the same patient twice")
} catch (e: ApiError) {
    val same = e.body.getAsJsonObject("patient")?.get("id")?.asInt == patientId
    println("2. Repeated request created nothing: HTTP ${e.status}, ${e.errors[0].asJsonObject["name"].asString}, same patient: $same")
}

// 3. From now on find the record by your own id.
found = api("GET", "/patients?external_id=$externalId")!!.getAsJsonArray("patients")
println("3. Found by external_id: ${found.size()} patient(s)")

// 4. What changed in the practice since last time? Page by cursor until `more` is false.
//    Changes made by this key are left out; you see what the staff, the patients and other systems did.
val applied = mutableListOf<String>()
var query = "since=${URLEncoder.encode(since, Charsets.UTF_8)}"
while (true) {
    val page = api("GET", "/changes?$query")!!
    page.getAsJsonArray("changes").forEach { applied += apply(it.asJsonObject) }
    val meta = page.getAsJsonObject("meta")
    if (!meta["more"].asBoolean) break

    query = "after=${meta["next_cursor"].asString}" // store this cursor; next time start from it
}
println("4. Changes from the practice: ${applied.size}")
applied.forEach { println("   $it") }

// 5. Clean up: give the external_id back, then deactivate the patient.
api("PATCH", "/patients/$patientId", mapOf("patient" to mapOf("external_id" to null)))
api("DELETE", "/patients/$patientId")
println("5. Cleaned up")
