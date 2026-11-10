// Zuboklik API example: verify the signature of an incoming webhook.
// Runs as a Kotlin script (Kotlin 1.9+).  Usage:  kotlin verify_webhook.main.kts

@file:DependsOn("com.google.code.gson:gson:2.11.0")

import com.google.gson.JsonParser
import java.io.File
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.abs

val maxAge = 300L // seconds; older deliveries are refused (replay protection)

// secret    - the secret returned once by POST /api/v1/webhooks
// timestamp - the X-Zuboklik-Timestamp header
// body      - the raw request body, exactly as received (do not re-serialize the JSON)
// signature - the X-Zuboklik-Signature header, "sha256=<hex>"
fun validWebhook(secret: String, timestamp: String, body: String, signature: String, now: Long = System.currentTimeMillis() / 1000): Boolean {
    if (abs(now - timestamp.toLong()) > maxAge) return false

    val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(secret.toByteArray(), "HmacSHA256")) }
    val expected = "sha256=" + mac.doFinal("$timestamp.$body".toByteArray()).joinToString("") { "%02x".format(it) }
    // MessageDigest.isEqual compares in constant time.
    return MessageDigest.isEqual(expected.toByteArray(), signature.toByteArray())
}

val vector = JsonParser.parseString(File("../test-vectors/webhook.json").readText()).asJsonObject
val secret = vector["secret"].asString
val timestamp = vector["timestamp"].asString
val body = vector["body"].asString
val signature = vector["signature"].asString
val now = timestamp.toLong() + 10

println("valid signature accepted: ${validWebhook(secret, timestamp, body, signature, now)}")
println("tampered body rejected: ${!validWebhook(secret, timestamp, body.replace("4711", "4712"), signature, now)}")
println("stale timestamp rejected: ${!validWebhook(secret, timestamp, body, signature, now + 3600)}")
