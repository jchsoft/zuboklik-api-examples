// Zuboklik API example: verify the signature of an incoming webhook.
// Runs on Java 17+ with Maven.  Usage:  mvn -q compile exec:java -Dexec.mainClass=VerifyWebhook

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public class VerifyWebhook {
    static final long MAX_AGE = 300; // seconds; older deliveries are refused (replay protection)

    // secret    - the secret returned once by POST /api/v1/webhooks
    // timestamp - the X-Zuboklik-Timestamp header
    // body      - the raw request body, exactly as received (do not re-serialize the JSON)
    // signature - the X-Zuboklik-Signature header, "sha256=<hex>"
    static boolean validWebhook(String secret, String timestamp, String body, String signature, long now) throws Exception {
        if (Math.abs(now - Long.parseLong(timestamp)) > MAX_AGE) return false;

        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        String expected = "sha256=" + HexFormat.of().formatHex(mac.doFinal((timestamp + "." + body).getBytes(StandardCharsets.UTF_8)));
        // MessageDigest.isEqual compares in constant time.
        return MessageDigest.isEqual(expected.getBytes(StandardCharsets.UTF_8), signature.getBytes(StandardCharsets.UTF_8));
    }

    public static void main(String[] args) throws Exception {
        JsonObject vector = JsonParser.parseString(Files.readString(Path.of("../test-vectors/webhook.json"))).getAsJsonObject();
        String secret = vector.get("secret").getAsString();
        String timestamp = vector.get("timestamp").getAsString();
        String body = vector.get("body").getAsString();
        String signature = vector.get("signature").getAsString();
        long now = Long.parseLong(timestamp) + 10; // in a real handler pass Instant.now().getEpochSecond()

        System.out.println("valid signature accepted: " + validWebhook(secret, timestamp, body, signature, now));
        System.out.println("tampered body rejected: " + !validWebhook(secret, timestamp, body.replace("4711", "4712"), signature, now));
        System.out.println("stale timestamp rejected: " + !validWebhook(secret, timestamp, body, signature, now + 3600));
    }
}
