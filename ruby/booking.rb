# frozen_string_literal: true

# Zuboklik API example: create a patient, find a free slot, book a preventive check-up, move it, clean up.
# Runs on plain Ruby 3.x, no gems.  Usage:  ZUBOKLIK_API_KEY=... ruby booking.rb

require 'date'
require 'json'
require 'net/http'

API_URL = ENV.fetch('ZUBOKLIK_API_URL', 'https://zuboklik.cz/api/v1')
API_KEY = ENV.fetch('ZUBOKLIK_API_KEY')

# Raised for every non-2xx answer. `errors` is the parsed "errors" array of the response.
class ApiError < StandardError
  attr_reader :status, :errors

  def initialize(status, errors)
    @status = status
    @errors = errors
    super("HTTP #{status}: #{errors.map { |e| [e['attribute'], *e['message']].compact.join(' ') }.join('; ')}")
  end
end

# One request. Returns the parsed JSON body (nil for 204 No Content).
def api(method, path, body = nil)
  uri = URI("#{API_URL}#{path}")
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request['Authorization'] = "Bearer #{API_KEY}"
  request['Accept'] = 'application/json'
  if body
    request['Content-Type'] = 'application/json'
    request.body = JSON.generate(body)
  end

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(request) }
  parsed = response.body.to_s.empty? ? nil : JSON.parse(response.body)
  raise ApiError.new(response.code.to_i, parsed ? parsed.fetch('errors', []) : []) unless response.is_a?(Net::HTTPSuccess)

  parsed
end

# "2026-11-24 09:00-09:30" from anything that has booked_for, start_time and end_time.
def slot(item)
  "#{item['booked_for']} #{item['start_time'][11, 5]}-#{item['end_time'][11, 5]}"
end

def find_by_code(items, code)
  items.find { |item| item['code'] == code } or raise "code #{code} not found"
end

# 1. Check the connection and the key.
puts "1. API is up (#{api(:get, '').fetch('version')})"

# 2. Catalogs: an appointment needs a symptom, an entry type and an entry state.
symptom = find_by_code(api(:get, '/symptoms').fetch('symptoms'), 'without_complications')
type = find_by_code(api(:get, '/entry_types').fetch('entry_types'), 'prevention')
state = find_by_code(api(:get, '/entry_states').fetch('entry_states'), 'reserved')
puts "2. Catalogs loaded: symptom #{symptom['code']}, type #{type['code']}, state #{state['code']}"

# 3. Create a patient.
patient = api(:post, '/patients', { patient: {
  first_name: 'Jan', last_name: 'Ukázkový', phone_number: '+420777111222', email: 'jan.ukazkovy@example.com'
} }).fetch('patient')
puts "3. Patient created: #{patient['first_name']} #{patient['last_name']}"

# 4. Ask for free 30-minute slots in the next 30 days.
from = Date.today + 1
first, second = api(:get, "/vacancies?from=#{from}&to=#{from + 30}&duration=30").fetch('vacancies')
raise 'the practice has fewer than two free slots in the next 30 days' unless second

puts "4. Free slots found: #{slot(first)} and #{slot(second)}"

# 5. Book the first one.
booking = { entry: {
  entry_type_id: type['id'], entry_state_id: state['id'],
  **first.slice('booked_for', 'start_time', 'end_time'),
  note: 'Booked by the API example',
  patient_symptoms_attributes: [{ patient_id: patient['id'], symptom_id: symptom['id'] }]
} }
entry = api(:post, '/entries', booking).fetch('entry')
puts "5. Appointment booked: #{slot(entry)}"

# 6. Booking the same slot again is refused with 409 and its own error name, so code can react to it.
begin
  api(:post, '/entries', booking)
  raise 'the API booked one slot twice'
rescue ApiError => e
  puts "6. Same slot refused: HTTP #{e.status}, #{e.errors.first['name']}"
end

# 7. Move the appointment to the second slot.
entry = api(:patch, "/entries/#{entry['id']}", { entry: second.slice('booked_for', 'start_time', 'end_time') }).fetch('entry')
puts "7. Appointment moved: #{slot(entry)}"

# 8. Read it back: the detail carries the patient and the note.
entry = api(:get, "/entries/#{entry['id']}").fetch('entry')
puts "8. Appointment read: #{entry['patient']['last_name']}, note \"#{entry['note']}\""

# 9. Errors: a patient without a last name is refused with 422 and a list of reasons.
begin
  api(:post, '/patients', { patient: { first_name: 'Jan' } })
  raise 'the API accepted an invalid patient'
rescue ApiError => e
  puts "9. Invalid patient refused: HTTP #{e.status}, attribute #{e.errors.first['attribute']}"
end

# 10. Clean up: delete the appointment, deactivate the patient.
api(:delete, "/entries/#{entry['id']}")
api(:delete, "/patients/#{patient['id']}")
puts '10. Cleaned up'
