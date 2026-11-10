// Zuboklik API example: verify the signature of an incoming webhook.
// Runs on plain Go 1.21+, standard library only.  Usage:  go run ./verify_webhook
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
)

const maxAge = 300 // seconds; older deliveries are refused (replay protection)

// validWebhook checks one delivery.
//
//	secret    - the secret returned once by POST /api/v1/webhooks
//	timestamp - the X-Zuboklik-Timestamp header
//	body      - the raw request body, exactly as received (do not re-serialize the JSON)
//	signature - the X-Zuboklik-Signature header, "sha256=<hex>"
func validWebhook(secret, timestamp, body, signature string, now int64) bool {
	sent, err := strconv.ParseInt(timestamp, 10, 64)
	if err != nil || now-sent > maxAge || sent-now > maxAge {
		return false
	}

	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(timestamp + "." + body))
	expected := "sha256=" + hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(expected), []byte(signature))
}

func main() {
	raw, err := os.ReadFile("../test-vectors/webhook.json")
	if err != nil {
		panic(err)
	}
	var v struct{ Secret, Timestamp, Body, Signature string }
	if err := json.Unmarshal(raw, &v); err != nil {
		panic(err)
	}
	sent, _ := strconv.ParseInt(v.Timestamp, 10, 64)
	now := sent + 10 // in a real handler pass time.Now().Unix()

	fmt.Printf("valid signature accepted: %t\n", validWebhook(v.Secret, v.Timestamp, v.Body, v.Signature, now))
	fmt.Printf("tampered body rejected: %t\n", !validWebhook(v.Secret, v.Timestamp, strings.Replace(v.Body, "4711", "4712", 1), v.Signature, now))
	fmt.Printf("stale timestamp rejected: %t\n", !validWebhook(v.Secret, v.Timestamp, v.Body, v.Signature, now+3600))
}
