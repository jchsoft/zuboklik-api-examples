// Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
// Runs on plain Go 1.21+, standard library only.  Usage:  ZUBOKLIK_API_KEY=... go run ./booking
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
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

func findByCode(items []object, code string) object {
	for _, item := range items {
		if item["code"] == code {
			return item
		}
	}
	panic("code " + code + " not found")
}

// slot formats "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
func slot(item object) string {
	return fmt.Sprintf("%s %s-%s", item["booked_for"], item["start_time"].(string)[11:16], item["end_time"].(string)[11:16])
}

func times(item object) object {
	return object{"booked_for": item["booked_for"], "start_time": item["start_time"], "end_time": item["end_time"]}
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

	// 1. Check the connection and the key.
	fmt.Printf("1. API is up (%s)\n", must("GET", "", nil)["version"])

	// 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
	symptom := findByCode(list(must("GET", "/symptoms", nil)["symptoms"]), "without_complications")
	entryType := findByCode(list(must("GET", "/entry_types", nil)["entry_types"]), "prevention")
	state := findByCode(list(must("GET", "/entry_states", nil)["entry_states"]), "reserved")
	fmt.Printf("2. Catalogs loaded: symptom %s, type %s, state %s\n", symptom["code"], entryType["code"], state["code"])

	// 3. Create a patient.
	patient := must("POST", "/patients", object{"patient": object{
		"first_name": "Jan", "last_name": "Ukázkový", "phone_number": "+420777111222", "email": "jan.ukazkovy@example.com",
	}})["patient"].(object)
	fmt.Printf("3. Patient created: %s %s\n", patient["first_name"], patient["last_name"])

	// 4. Ask for free 30-minute slots in the next 30 days.
	from := time.Now().AddDate(0, 0, 1)
	query := fmt.Sprintf("/vacancies?from=%s&to=%s&duration=30", from.Format(time.DateOnly), from.AddDate(0, 0, 30).Format(time.DateOnly))
	vacancies := list(must("GET", query, nil)["vacancies"])
	if len(vacancies) < 2 {
		fmt.Fprintln(os.Stderr, "the practice has fewer than two free slots in the next 30 days")
		os.Exit(1)
	}
	first, second := vacancies[0], vacancies[1]
	fmt.Printf("4. Free slots found: %s and %s\n", slot(first), slot(second))

	// 5. Book the first one.
	booking := times(first)
	booking["entry_type_id"] = entryType["id"]
	booking["entry_state_id"] = state["id"]
	booking["note"] = "Booked by the API example"
	booking["patient_symptoms_attributes"] = []object{{"patient_id": patient["id"], "symptom_id": symptom["id"]}}
	entry := must("POST", "/entries", object{"entry": booking})["entry"].(object)
	fmt.Printf("5. Appointment booked: %s\n", slot(entry))

	// 6. Move it to the second one.
	entry = must("PATCH", fmt.Sprintf("/entries/%d", id(entry)), object{"entry": times(second)})["entry"].(object)
	fmt.Printf("6. Appointment moved: %s\n", slot(entry))

	// 7. Errors: a patient without a last name is refused with 422 and a list of reasons.
	_, err := api("POST", "/patients", object{"patient": object{"first_name": "Jan"}})
	var apiError *APIError
	if !errors.As(err, &apiError) {
		fmt.Fprintln(os.Stderr, "the API accepted an invalid patient")
		os.Exit(1)
	}
	fmt.Printf("7. Invalid patient refused: HTTP %d, attribute %s\n", apiError.Status, apiError.Errors[0]["attribute"])

	// 8. Clean up: delete the appointment, deactivate the patient.
	must("DELETE", fmt.Sprintf("/entries/%d", id(entry)), nil)
	must("DELETE", fmt.Sprintf("/patients/%d", id(patient)), nil)
	fmt.Println("8. Cleaned up")
}
