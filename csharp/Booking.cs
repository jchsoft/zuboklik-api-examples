// Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
// Runs on .NET 10+, no packages.  Usage:  ZUBOKLIK_API_KEY=... dotnet run Booking.cs

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

var apiUrl = Environment.GetEnvironmentVariable("ZUBOKLIK_API_URL") ?? "https://zuboklik.cz/api/v1";
var apiKey = Environment.GetEnvironmentVariable("ZUBOKLIK_API_KEY") ?? throw new InvalidOperationException("set ZUBOKLIK_API_KEY");

using var http = new HttpClient();
http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

// One request. Returns the parsed JSON body (null for 204 No Content).
async Task<JsonNode?> Api(HttpMethod method, string path, JsonNode? body = null)
{
    using var request = new HttpRequestMessage(method, apiUrl + path);
    if (body is not null) request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

    using var response = await http.SendAsync(request);
    var text = await response.Content.ReadAsStringAsync();
    var parsed = text.Length == 0 ? null : JsonNode.Parse(text);
    if (!response.IsSuccessStatusCode) throw new ApiError((int)response.StatusCode, parsed?["errors"]?.AsArray() ?? new JsonArray());
    return parsed;
}

static JsonNode FindByCode(JsonNode items, string code) =>
    items.AsArray().First(item => (string)item!["code"]! == code)!;

// "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
static string Slot(JsonNode item) =>
    $"{item["booked_for"]} {((string)item["start_time"]!)[11..16]}-{((string)item["end_time"]!)[11..16]}";

static JsonObject Times(JsonNode item) => new()
{
    ["booked_for"] = (string)item["booked_for"]!,
    ["start_time"] = (string)item["start_time"]!,
    ["end_time"] = (string)item["end_time"]!,
};

// 1. Check the connection and the key.
Console.WriteLine($"1. API is up ({(await Api(HttpMethod.Get, ""))!["version"]})");

// 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
var symptom = FindByCode((await Api(HttpMethod.Get, "/symptoms"))!["symptoms"]!, "without_complications");
var type = FindByCode((await Api(HttpMethod.Get, "/entry_types"))!["entry_types"]!, "prevention");
var state = FindByCode((await Api(HttpMethod.Get, "/entry_states"))!["entry_states"]!, "reserved");
Console.WriteLine($"2. Catalogs loaded: symptom {symptom["code"]}, type {type["code"]}, state {state["code"]}");

// 3. Create a patient.
var patient = (await Api(HttpMethod.Post, "/patients", new JsonObject
{
    ["patient"] = new JsonObject
    {
        ["first_name"] = "Jan", ["last_name"] = "Ukázkový", ["phone_number"] = "+420777111222", ["email"] = "jan.ukazkovy@example.com",
    },
}))!["patient"]!;
Console.WriteLine($"3. Patient created: {patient["first_name"]} {patient["last_name"]}");

// 4. Ask for free 30-minute slots in the next 30 days.
var from = DateOnly.FromDateTime(DateTime.Today).AddDays(1);
var vacancies = (await Api(HttpMethod.Get, $"/vacancies?from={from:yyyy-MM-dd}&to={from.AddDays(30):yyyy-MM-dd}&duration=30"))!["vacancies"]!.AsArray();
if (vacancies.Count < 2) throw new InvalidOperationException("the practice has fewer than two free slots in the next 30 days");
var (first, second) = (vacancies[0]!, vacancies[1]!);
Console.WriteLine($"4. Free slots found: {Slot(first)} and {Slot(second)}");

// 5. Book the first one.
var entryAttributes = Times(first);
entryAttributes["entry_type_id"] = (int)type["id"]!;
entryAttributes["entry_state_id"] = (int)state["id"]!;
entryAttributes["note"] = "Booked by the API example";
entryAttributes["patient_symptoms_attributes"] = new JsonArray(new JsonObject { ["patient_id"] = (int)patient["id"]!, ["symptom_id"] = (int)symptom["id"]! });
var booking = new JsonObject { ["entry"] = entryAttributes };
var entry = (await Api(HttpMethod.Post, "/entries", booking))!["entry"]!;
Console.WriteLine($"5. Appointment booked: {Slot(entry)}");

// 6. Booking the same slot again is refused with 409 and its own error name, so code can react to it.
try
{
    await Api(HttpMethod.Post, "/entries", booking);
    throw new InvalidOperationException("the API booked one slot twice");
}
catch (ApiError error)
{
    Console.WriteLine($"6. Same slot refused: HTTP {error.Status}, {error.Errors[0]!["name"]}");
}

// 7. Move the appointment to the second slot.
entry = (await Api(HttpMethod.Patch, $"/entries/{entry["id"]}", new JsonObject { ["entry"] = Times(second) }))!["entry"]!;
Console.WriteLine($"7. Appointment moved: {Slot(entry)}");

// 8. Read it back: the detail carries the patient and the note.
entry = (await Api(HttpMethod.Get, $"/entries/{entry["id"]}"))!["entry"]!;
Console.WriteLine($"8. Appointment read: {entry["patient"]!["last_name"]}, note \"{entry["note"]}\"");

// 9. Errors: a patient without a last name is refused with 422 and a list of reasons.
try
{
    await Api(HttpMethod.Post, "/patients", new JsonObject { ["patient"] = new JsonObject { ["first_name"] = "Jan" } });
    throw new InvalidOperationException("the API accepted an invalid patient");
}
catch (ApiError error)
{
    Console.WriteLine($"9. Invalid patient refused: HTTP {error.Status}, attribute {error.Errors[0]!["attribute"]}");
}

// 10. Clean up: delete the appointment, deactivate the patient.
await Api(HttpMethod.Delete, $"/entries/{entry["id"]}");
await Api(HttpMethod.Delete, $"/patients/{patient["id"]}");
Console.WriteLine("10. Cleaned up");

// Thrown for every non-2xx answer. Errors is the parsed "errors" array of the response.
class ApiError(int status, JsonArray errors) : Exception($"HTTP {status}: {errors.ToJsonString()}")
{
    public int Status { get; } = status;
    public JsonArray Errors { get; } = errors;
}
