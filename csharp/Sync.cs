// Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
// survive a repeated request, and read "what changed since last time" (deletions included).
// Runs on .NET 10+, no packages.  Usage:  ZUBOKLIK_API_KEY=... dotnet run Sync.cs

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

var apiUrl = Environment.GetEnvironmentVariable("ZUBOKLIK_API_URL") ?? "https://zuboklik.cz/api/v1";
var apiKey = Environment.GetEnvironmentVariable("ZUBOKLIK_API_KEY") ?? throw new InvalidOperationException("set ZUBOKLIK_API_KEY");
// Where to start reading changes. A real integration stores the cursor of the last change it processed
// and never needs this; the example starts "now" unless told otherwise.
var since = Environment.GetEnvironmentVariable("ZUBOKLIK_SYNC_SINCE") ?? DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
const string externalId = "example-patient-1"; // the id of this patient in YOUR system

using var http = new HttpClient();
http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

// One request. Returns the parsed JSON body (null for 204 No Content).
async Task<JsonNode?> Api(HttpMethod method, string path, JsonNode? body = null)
{
    using var request = new HttpRequestMessage(method, apiUrl + path);
    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
    if (body is not null) request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

    using var response = await http.SendAsync(request);
    var text = await response.Content.ReadAsStringAsync();
    var parsed = text.Length == 0 ? null : JsonNode.Parse(text);
    if (!response.IsSuccessStatusCode) throw new ApiError((int)response.StatusCode, parsed as JsonObject ?? new JsonObject());
    return parsed;
}

// What your system does with one change. A webhook delivery has the same fields, so the same code handles both.
// Returns a line describing what was done.
async Task<string> Apply(JsonNode change)
{
    var collection = (string)change["resource_type"]! == "Patient" ? "patients" : "entries";
    if ((string)change["action"]! == "destroy") return $"{change["event"]}: removed from our system";

    try
    {
        await Api(HttpMethod.Get, $"/{collection}/{change["resource_id"]}"); // the current state of the record; save it on your side
        return $"{change["event"]}: saved to our system";
    }
    catch (ApiError error) when (error.Status == 404)
    {
        return $"{change["event"]}: already gone, removed from our system"; // deleted again before we asked
    }
}

JsonObject NewPatient() => new()
{
    ["patient"] = new JsonObject { ["first_name"] = "Eva", ["last_name"] = "Ukázková", ["phone_number"] = "+420777111222", ["external_id"] = externalId },
};

// 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
//    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
var found = (await Api(HttpMethod.Get, $"/patients?external_id={externalId}"))!["patients"]!.AsArray();
var patient = found.Count > 0 ? found[0]! : (await Api(HttpMethod.Post, "/patients", NewPatient()))!["patient"]!;
Console.WriteLine($"1. Patient paired: {patient["first_name"]} {patient["last_name"]}, external_id {patient["external_id"]}");

// 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
try
{
    await Api(HttpMethod.Post, "/patients", NewPatient());
    throw new InvalidOperationException("the API created the same patient twice");
}
catch (ApiError error)
{
    var same = (int?)error.Body["patient"]?["id"] == (int)patient["id"]!;
    Console.WriteLine($"2. Repeated request created nothing: HTTP {error.Status}, {error.Errors[0]!["name"]}, same patient: {(same ? "true" : "false")}");
}

// 3. From now on find the record by your own id.
found = (await Api(HttpMethod.Get, $"/patients?external_id={externalId}"))!["patients"]!.AsArray();
Console.WriteLine($"3. Found by external_id: {found.Count} patient(s)");

// 4. What changed in the practice since last time? Page by cursor until `more` is false.
//    Changes made by this key are left out; you see what the staff, the patients and other systems did.
var applied = new List<string>();
var query = $"since={Uri.EscapeDataString(since)}";
while (true)
{
    var page = (await Api(HttpMethod.Get, $"/changes?{query}"))!;
    foreach (var change in page["changes"]!.AsArray()) applied.Add(await Apply(change!));
    if (!(bool)page["meta"]!["more"]!) break;

    query = $"after={page["meta"]!["next_cursor"]}"; // store this cursor; next time start from it
}
Console.WriteLine($"4. Changes from the practice: {applied.Count}");
foreach (var line in applied) Console.WriteLine($"   {line}");

// 5. Clean up: give the external_id back, then deactivate the patient.
await Api(HttpMethod.Patch, $"/patients/{patient["id"]}", new JsonObject { ["patient"] = new JsonObject { ["external_id"] = null } });
await Api(HttpMethod.Delete, $"/patients/{patient["id"]}");
Console.WriteLine("5. Cleaned up");

// Thrown for every non-2xx answer. Errors is the parsed "errors" array, Body the whole parsed response.
class ApiError(int status, JsonObject body) : Exception($"HTTP {status}: {body["errors"]?.ToJsonString() ?? "[]"}")
{
    public int Status { get; } = status;
    public JsonObject Body { get; } = body;
    public JsonArray Errors { get; } = body["errors"]?.AsArray() ?? new JsonArray();
}
