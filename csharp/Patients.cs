// Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
// Runs on .NET 10+, no packages.  Usage:  ZUBOKLIK_API_KEY=... dotnet run Patients.cs

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

var apiUrl = Environment.GetEnvironmentVariable("ZUBOKLIK_API_URL") ?? "https://zuboklik.cz/api/v1";
var apiKey = Environment.GetEnvironmentVariable("ZUBOKLIK_API_KEY") ?? throw new InvalidOperationException("set ZUBOKLIK_API_KEY");

using var http = new HttpClient();
http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));

// One request. Returns the parsed JSON body (null for 204 No Content).
async Task<JsonNode?> Api(HttpMethod method, string path, JsonNode? body = null, string? key = null)
{
    using var request = new HttpRequestMessage(method, apiUrl + path);
    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key ?? apiKey);
    if (body is not null) request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

    using var response = await http.SendAsync(request);
    var text = await response.Content.ReadAsStringAsync();
    var parsed = text.Length == 0 ? null : JsonNode.Parse(text);
    if (!response.IsSuccessStatusCode) throw new ApiError((int)response.StatusCode, parsed?["errors"]?.AsArray() ?? new JsonArray());
    return parsed;
}

// 1. Create two patients.
var jana = (await Api(HttpMethod.Post, "/patients", new JsonObject
{
    ["patient"] = new JsonObject { ["first_name"] = "Jana", ["last_name"] = "Ukázková", ["phone_number"] = "+420777111222" },
}))!["patient"]!;
var petr = (await Api(HttpMethod.Post, "/patients", new JsonObject
{
    ["patient"] = new JsonObject { ["first_name"] = "Petr", ["last_name"] = "Ukázkový", ["email"] = "petr.ukazkovy@example.com" },
}))!["patient"]!;
Console.WriteLine($"1. Patients created: {jana["first_name"]} {jana["last_name"]} and {petr["first_name"]} {petr["last_name"]}");

// 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
var patients = new List<JsonNode>();
var page = 1;
while (true)
{
    var list = (await Api(HttpMethod.Get, $"/patients?page={page}&per_page=100"))!;
    patients.AddRange(list["patients"]!.AsArray()!);
    if (page >= (int)list["meta"]!["total_pages"]!) break;
    page++;
}
var ours = patients.Count(patient => (int)patient["id"]! == (int)jana["id"]! || (int)patient["id"]! == (int)petr["id"]!);
Console.WriteLine($"2. Patients listed: {patients.Count} on {page} page(s), ours among them: {ours}");

// 3. Read one patient.
var detail = (await Api(HttpMethod.Get, $"/patients/{jana["id"]}"))!["patient"]!;
Console.WriteLine($"3. Patient read: {detail["first_name"]} {detail["last_name"]}");

// 4. Update: only the attributes you send change.
var updated = (await Api(HttpMethod.Patch, $"/patients/{jana["id"]}", new JsonObject
{
    ["patient"] = new JsonObject { ["email"] = "jana.ukazkova@example.com" },
}))!["patient"]!;
Console.WriteLine($"4. Patient updated: {updated["email"]}, still {updated["last_name"]}");

// 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
await Api(HttpMethod.Delete, $"/patients/{jana["id"]}");
await Api(HttpMethod.Delete, $"/patients/{petr["id"]}");
Console.WriteLine("5. Patients deactivated");

// 6. A deactivated (or unknown) patient answers 404.
try
{
    await Api(HttpMethod.Get, $"/patients/{jana["id"]}");
    throw new InvalidOperationException("the API still returns a deactivated patient");
}
catch (ApiError error)
{
    Console.WriteLine($"6. Deactivated patient not found: HTTP {error.Status}, {error.Errors[0]!["name"]}");
}

// 7. A wrong key answers 401.
try
{
    await Api(HttpMethod.Get, "/patients", key: "not-a-valid-key");
    throw new InvalidOperationException("the API accepted a wrong key");
}
catch (ApiError error)
{
    Console.WriteLine($"7. Wrong key refused: HTTP {error.Status}, {error.Errors[0]!["name"]}");
}

// Thrown for every non-2xx answer. Errors is the parsed "errors" array of the response.
class ApiError(int status, JsonArray errors) : Exception($"HTTP {status}: {errors.ToJsonString()}")
{
    public int Status { get; } = status;
    public JsonArray Errors { get; } = errors;
}
