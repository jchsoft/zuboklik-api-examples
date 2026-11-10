// Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
// Runs on plain Go 1.21+, standard library only.  Usage:  ZUBOKLIK_API_KEY=... go run ./webhooks
// How to verify what the webhook then receives: verify_webhook/main.go.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
)

const webhookURL = "https://example.com/zuboklik-webhook" // your endpoint; must be https and publicly reachable

var (
	apiURL = envOr("ZUBOKLIK_API_URL", "https://zuboklik.cz/api/v1")
	apiKey = os.Getenv("ZUBOKLIK_API_KEY")
)

type object = map[string]any

// APIError is returned for every non-2xx answer. Errors is the parsed "errors" array of the response.
type APIError struct {
	Status int
	Errors []object
}

func (e *APIError) Error() string { return fmt.Sprintf("HTTP %d: %v", e.Status, e.Errors) }

// api sends one request and returns the parsed JSON body (nil for 204 No Content).
func api(method, path string, body any) (object, error) {
	var payload io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		payload = bytes.NewReader(encoded)
	}
	request, err := http.NewRequest(method, apiURL+path, payload)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/json")

	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	text, err := io.ReadAll(response.Body)
	if err != nil {
		return nil, err
	}

	var parsed object
	if len(text) > 0 {
		if err := json.Unmarshal(text, &parsed); err != nil {
			return nil, err
		}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, &APIError{Status: response.StatusCode, Errors: list(parsed["errors"])}
	}
	return parsed, nil
}

// must is api for the steps where any failure ends the example.
func must(method, path string, body any) object {
	parsed, err := api(method, path, body)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	return parsed
}

func list(value any) []object {
	items, _ := value.([]any)
	result := make([]object, 0, len(items))
	for _, item := range items {
		result = append(result, item.(object))
	}
	return result
}

func id(item object) int { return int(item["id"].(float64)) }

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func activeCount() int {
	count := 0
	for _, webhook := range list(must("GET", "/webhooks", nil)["webhooks"]) {
		if webhook["status"] == "active" {
			count++
		}
	}
	return count
}

func main() {
	if apiKey == "" {
		fmt.Fprintln(os.Stderr, "set ZUBOKLIK_API_KEY")
		os.Exit(1)
	}

	// 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
	registered := must("POST", "/webhooks", object{"webhook": object{"url": webhookURL}})
	webhook := registered["webhook"].(object)
	fmt.Printf("1. Webhook registered: %s (%s, secret of %d characters)\n", webhook["url"], webhook["status"], len(registered["secret"].(string)))

	// 2. List the webhooks of this connected system.
	fmt.Printf("2. Webhooks listed: %d active\n", activeCount())

	// 3. A URL that is not https (or points to a private address) is refused with 422.
	var apiError *APIError
	if _, err := api("POST", "/webhooks", object{"webhook": object{"url": "http://example.com/zuboklik-webhook"}}); !errors.As(err, &apiError) {
		fmt.Fprintln(os.Stderr, "the API accepted a plain http URL")
		os.Exit(1)
	}
	fmt.Printf("3. Plain http refused: HTTP %d, attribute %s\n", apiError.Status, apiError.Errors[0]["attribute"])

	// 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
	must("DELETE", fmt.Sprintf("/webhooks/%d", id(webhook)), nil)
	fmt.Printf("4. Webhook switched off, %d active\n", activeCount())
}
