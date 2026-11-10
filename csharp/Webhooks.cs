// Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
// Runs on .NET 10+, no packages.  Usage:  ZUBOKLIK_API_KEY=... dotnet run Webhooks.cs
// How to verify what the webhook then receives: VerifyWebhook.cs.

using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

var apiUrl = Environment.GetEnvironmentVariable("ZUBOKLIK_API_URL") ?? "https://zuboklik.cz/api/v1";
var apiKey = Environment.GetEnvironmentVariable("ZUBOKLIK_API_KEY") ?? throw new InvalidOperationException("set ZUBOKLIK_API_KEY");
const string webhookUrl = "https://example.com/zuboklik-webhook"; // your endpoint; must be https and publicly reachable

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

async Task<int> ActiveCount() =>
    (await Api(HttpMethod.Get, "/webhooks"))!["webhooks"]!.AsArray().Count(webhook => (string)webhook!["status"]! == "active");

// 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
var registered = (await Api(HttpMethod.Post, "/webhooks", new JsonObject { ["webhook"] = new JsonObject { ["url"] = webhookUrl } }))!;
var webhook = registered["webhook"]!;
Console.WriteLine($"1. Webhook registered: {webhook["url"]} ({webhook["status"]}, secret of {((string)registered["secret"]!).Length} characters)");

// 2. List the webhooks of this connected system.
Console.WriteLine($"2. Webhooks listed: {await ActiveCount()} active");

// 3. A URL that is not https (or points to a private address) is refused with 422.
try
{
    await Api(HttpMethod.Post, "/webhooks", new JsonObject { ["webhook"] = new JsonObject { ["url"] = "http://example.com/zuboklik-webhook" } });
    throw new InvalidOperationException("the API accepted a plain http URL");
}
catch (ApiError error)
{
    Console.WriteLine($"3. Plain http refused: HTTP {error.Status}, attribute {error.Errors[0]!["attribute"]}");
}

// 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
await Api(HttpMethod.Delete, $"/webhooks/{webhook["id"]}");
Console.WriteLine($"4. Webhook switched off, {await ActiveCount()} active");

// Thrown for every non-2xx answer. Errors is the parsed "errors" array of the response.
class ApiError(int status, JsonArray errors) : Exception($"HTTP {status}: {errors.ToJsonString()}")
{
    public int Status { get; } = status;
    public JsonArray Errors { get; } = errors;
}
