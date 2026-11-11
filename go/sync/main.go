// Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
// survive a repeated request, and read "what changed since last time" (deletions included).
// Runs on plain Go 1.21+, standard library only.  Usage:  ZUBOKLIK_API_KEY=... go run ./sync
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"
)

var (
	apiURL = envOr("ZUBOKLIK_API_URL", "https://zuboklik.cz/api/v1")
	apiKey = os.Getenv("ZUBOKLIK_API_KEY")
	// Where to start reading changes. A real integration stores the cursor of the last change it processed
	// and never needs this; the example starts "now" unless told otherwise.
	since = envOr("ZUBOKLIK_SYNC_SINCE", time.Now().UTC().Format(time.RFC3339))
)

const externalID = "example-patient-1" // the id of this patient in YOUR system

type object = map[string]any

// APIError is returned for every non-2xx answer. Errors is the parsed "errors" array, Body the whole parsed response.
type APIError struct {
	Status int
	Errors []object
	Body   object
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
		return nil, &APIError{Status: response.StatusCode, Errors: list(parsed["errors"]), Body: parsed}
	}
	return parsed, nil
}

// must is api for the steps where any failure ends the example.
func must(method, path string, body any) object {
	parsed, err := api(method, path, body)
	if err != nil {
		fail(err)
	}
	return parsed
}

func fail(message any) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
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

// apply is what your system does with one change. A webhook delivery has the same fields, so the same code handles both.
// It returns a line describing what was done.
func apply(change object) (string, error) {
	collection := "entries"
	if change["resource_type"] == "Patient" {
		collection = "patients"
	}
	if change["action"] == "destroy" {
		return fmt.Sprintf("%s: removed from our system", change["event"]), nil
	}
	// the current state of the record; save it on your side
	_, err := api("GET", fmt.Sprintf("/%s/%d", collection, int(change["resource_id"].(float64))), nil)
	var apiError *APIError
	if errors.As(err, &apiError) && apiError.Status == 404 {
		return fmt.Sprintf("%s: already gone, removed from our system", change["event"]), nil // deleted again before we asked
	}
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s: saved to our system", change["event"]), nil
}

func main() {
	if apiKey == "" {
		fail("set ZUBOKLIK_API_KEY")
	}

	newPatient := object{"patient": object{"first_name": "Eva", "last_name": "Ukázková", "phone_number": "+420777111222", "external_id": externalID}}

	// 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
	//    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
	found := list(must("GET", "/patients?external_id="+externalID, nil)["patients"])
	var patient object
	if len(found) > 0 {
		patient = found[0]
	} else {
		patient = must("POST", "/patients", newPatient)["patient"].(object)
	}
	fmt.Printf("1. Patient paired: %s %s, external_id %s\n", patient["first_name"], patient["last_name"], patient["external_id"])

	// 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
	var apiError *APIError
	if _, err := api("POST", "/patients", newPatient); err == nil {
		fail("the API created the same patient twice")
	} else if !errors.As(err, &apiError) {
		fail(err)
	}
	existing, _ := apiError.Body["patient"].(object)
	same := existing["id"] == patient["id"]
	fmt.Printf("2. Repeated request created nothing: HTTP %d, %s, same patient: %t\n", apiError.Status, apiError.Errors[0]["name"], same)

	// 3. From now on find the record by your own id.
	found = list(must("GET", "/patients?external_id="+externalID, nil)["patients"])
	fmt.Printf("3. Found by external_id: %d patient(s)\n", len(found))

	// 4. What changed in the practice since last time? Page by cursor until "more" is false.
	//    Changes made by this key are left out; you see what the staff, the patients and other systems did.
	var applied []string
	query := "since=" + url.QueryEscape(since)
	for {
		page := must("GET", "/changes?"+query, nil)
		for _, change := range list(page["changes"]) {
			line, err := apply(change)
			if err != nil {
				fail(err)
			}
			applied = append(applied, line)
		}
		meta := page["meta"].(object)
		if !meta["more"].(bool) {
			break
		}
		query = fmt.Sprintf("after=%v", meta["next_cursor"]) // store this cursor; next time start from it
	}
	fmt.Printf("4. Changes from the practice: %d\n", len(applied))
	for _, line := range applied {
		fmt.Printf("   %s\n", line)
	}

	// 5. Clean up: give the external_id back, then deactivate the patient.
	must("PATCH", fmt.Sprintf("/patients/%d", id(patient)), object{"patient": object{"external_id": nil}})
	must("DELETE", fmt.Sprintf("/patients/%d", id(patient)), nil)
	fmt.Println("5. Cleaned up")
}
