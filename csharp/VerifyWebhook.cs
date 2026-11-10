// Zuboklik API example: verify the signature of an incoming webhook.
// Runs on .NET 10+, no packages.  Usage:  dotnet run VerifyWebhook.cs

using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

const int MaxAge = 300; // seconds; older deliveries are refused (replay protection)

// secret    - the secret returned once by POST /api/v1/webhooks
// timestamp - the X-Zuboklik-Timestamp header
// body      - the raw request body, exactly as received (do not re-serialize the JSON)
// signature - the X-Zuboklik-Signature header, "sha256=<hex>"
static bool ValidWebhook(string secret, string timestamp, string body, string signature, long? now = null)
{
    now ??= DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    if (!long.TryParse(timestamp, out var sent) || Math.Abs(now.Value - sent) > MaxAge) return false;

    var digest = HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), Encoding.UTF8.GetBytes($"{timestamp}.{body}"));
    var expected = "sha256=" + Convert.ToHexStringLower(digest);
    return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(signature));
}

var vector = JsonNode.Parse(File.ReadAllText("../test-vectors/webhook.json"))!;
var (secret, timestamp, body, signature) = ((string)vector["secret"]!, (string)vector["timestamp"]!, (string)vector["body"]!, (string)vector["signature"]!);
var now = long.Parse(timestamp) + 10;

static string Show(bool value) => value ? "true" : "false";

Console.WriteLine($"valid signature accepted: {Show(ValidWebhook(secret, timestamp, body, signature, now))}");
Console.WriteLine($"tampered body rejected: {Show(!ValidWebhook(secret, timestamp, body.Replace("4711", "4712"), signature, now))}");
Console.WriteLine($"stale timestamp rejected: {Show(!ValidWebhook(secret, timestamp, body, signature, now + 3600))}");
