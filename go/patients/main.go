// Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
// Runs on plain Go 1.21+, standard library only.  Usage:  ZUBOKLIK_API_KEY=... go run ./patients
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
	return apiWithKey(apiKey, method, path, body)
}

// apiWithKey is api with another key than the one from the environment.
func apiWithKey(key, method, path string, body any) (object, error) {
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
	request.Header.Set("Authorization", "Bearer "+key)
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

func main() {
	if apiKey == "" {
		fmt.Fprintln(os.Stderr, "set ZUBOKLIK_API_KEY")
		os.Exit(1)
	}

	// 1. Create two patients.
	jana := must("POST", "/patients", object{"patient": object{"first_name": "Jana", "last_name": "Ukázková", "phone_number": "+420777111222"}})["patient"].(object)
	petr := must("POST", "/patients", object{"patient": object{"first_name": "Petr", "last_name": "Ukázkový", "email": "petr.ukazkovy@example.com"}})["patient"].(object)
	fmt.Printf("1. Patients created: %s %s and %s %s\n", jana["first_name"], jana["last_name"], petr["first_name"], petr["last_name"])

	// 2. Page through the whole list, 100 patients per request (the maximum). "meta" says how many pages there are.
	var patients []object
	page := 1
	for {
		listing := must("GET", fmt.Sprintf("/patients?page=%d&per_page=100", page), nil)
		patients = append(patients, list(listing["patients"])...)
		if page >= int(listing["meta"].(object)["total_pages"].(float64)) {
			break
		}
		page++
	}
	ours := 0
	for _, patient := range patients {
		if id(patient) == id(jana) || id(patient) == id(petr) {
			ours++
		}
	}
	fmt.Printf("2. Patients listed: %d on %d page(s), ours among them: %d\n", len(patients), page, ours)

	// 3. Read one patient.
	detail := must("GET", fmt.Sprintf("/patients/%d", id(jana)), nil)["patient"].(object)
	fmt.Printf("3. Patient read: %s %s\n", detail["first_name"], detail["last_name"])

	// 4. Update: only the attributes you send change.
	updated := must("PATCH", fmt.Sprintf("/patients/%d", id(jana)), object{"patient": object{"email": "jana.ukazkova@example.com"}})["patient"].(object)
	fmt.Printf("4. Patient updated: %s, still %s\n", updated["email"], updated["last_name"])

	// 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
	must("DELETE", fmt.Sprintf("/patients/%d", id(jana)), nil)
	must("DELETE", fmt.Sprintf("/patients/%d", id(petr)), nil)
	fmt.Println("5. Patients deactivated")

	// 6. A deactivated (or unknown) patient answers 404.
	var apiError *APIError
	if _, err := api("GET", fmt.Sprintf("/patients/%d", id(jana)), nil); !errors.As(err, &apiError) {
		fmt.Fprintln(os.Stderr, "the API still returns a deactivated patient")
		os.Exit(1)
	}
	fmt.Printf("6. Deactivated patient not found: HTTP %d, %s\n", apiError.Status, apiError.Errors[0]["name"])

	// 7. A wrong key answers 401.
	if _, err := apiWithKey("not-a-valid-key", "GET", "/patients", nil); !errors.As(err, &apiError) {
		fmt.Fprintln(os.Stderr, "the API accepted a wrong key")
		os.Exit(1)
	}
	fmt.Printf("7. Wrong key refused: HTTP %d, %s\n", apiError.Status, apiError.Errors[0]["name"])
}
