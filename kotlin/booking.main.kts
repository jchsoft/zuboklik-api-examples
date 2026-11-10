// Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
// Runs as a Kotlin script (Kotlin 1.9+, JDK 17+).  Usage:  ZUBOKLIK_API_KEY=... kotlin booking.main.kts

@file:DependsOn("com.google.code.gson:gson:2.11.0")

import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.LocalDate

val apiUrl = System.getenv("ZUBOKLIK_API_URL") ?: "https://zuboklik.cz/api/v1"
val apiKey = System.getenv("ZUBOKLIK_API_KEY") ?: error("set ZUBOKLIK_API_KEY")
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

fun findByCode(items: JsonArray, code: String): JsonObject =
    items.map { it.asJsonObject }.first { it["code"].asString == code }

// "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
fun slot(item: JsonObject) =
    "${item["booked_for"].asString} ${item["start_time"].asString.substring(11, 16)}-${item["end_time"].asString.substring(11, 16)}"

fun times(item: JsonObject) = listOf("booked_for", "start_time", "end_time").associateWith { item[it].asString }

// 1. Check the connection and the key.
println("1. API is up (${api("GET", "")!!["version"].asString})")

// 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
val symptom = findByCode(api("GET", "/symptoms")!!.getAsJsonArray("symptoms"), "without_complications")
val type = findByCode(api("GET", "/entry_types")!!.getAsJsonArray("entry_types"), "prevention")
val state = findByCode(api("GET", "/entry_states")!!.getAsJsonArray("entry_states"), "reserved")
println("2. Catalogs loaded: symptom ${symptom["code"].asString}, type ${type["code"].asString}, state ${state["code"].asString}")

// 3. Create a patient.
val patient = api("POST", "/patients", mapOf("patient" to mapOf(
    "first_name" to "Jan", "last_name" to "Ukázkový", "phone_number" to "+420777111222", "email" to "jan.ukazkovy@example.com",
)))!!.getAsJsonObject("patient")
println("3. Patient created: ${patient["first_name"].asString} ${patient["last_name"].asString}")

// 4. Ask for free 30-minute slots in the next 30 days.
val from: LocalDate = LocalDate.now().plusDays(1)
val vacancies = api("GET", "/vacancies?from=$from&to=${from.plusDays(30)}&duration=30")!!.getAsJsonArray("vacancies")
check(vacancies.size() >= 2) { "the practice has fewer than two free slots in the next 30 days" }
val first = vacancies[0].asJsonObject
val second = vacancies[1].asJsonObject
println("4. Free slots found: ${slot(first)} and ${slot(second)}")

// 5. Book the first one.
var entry = api("POST", "/entries", mapOf("entry" to times(first) + mapOf(
    "entry_type_id" to type["id"].asInt,
    "entry_state_id" to state["id"].asInt,
    "note" to "Booked by the API example",
    "patient_symptoms_attributes" to listOf(mapOf("patient_id" to patient["id"].asInt, "symptom_id" to symptom["id"].asInt)),
)))!!.getAsJsonObject("entry")
println("5. Appointment booked: ${slot(entry)}")

// 6. Move it to the second one.
entry = api("PATCH", "/entries/${entry["id"].asInt}", mapOf("entry" to times(second)))!!.getAsJsonObject("entry")
println("6. Appointment moved: ${slot(entry)}")

// 7. Errors: a patient without a last name is refused with 422 and a list of reasons.
try {
    api("POST", "/patients", mapOf("patient" to mapOf("first_name" to "Jan")))
    error("the API accepted an invalid patient")
} catch (e: ApiError) {
    println("7. Invalid patient refused: HTTP ${e.status}, attribute ${e.errors[0].asJsonObject["attribute"].asString}")
}

// 8. Clean up: delete the appointment, deactivate the patient.
api("DELETE", "/entries/${entry["id"].asInt}")
api("DELETE", "/patients/${patient["id"].asInt}")
println("8. Cleaned up")
