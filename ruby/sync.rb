# frozen_string_literal: true

# Zuboklik API example: keep your own system in step with a practice - pair a record with your own id,
# survive a repeated request, and read "what changed since last time" (deletions included).
# Runs on plain Ruby 3.x, no gems.  Usage:  ZUBOKLIK_API_KEY=... ruby sync.rb

require 'json'
require 'net/http'
require 'time'

API_URL = ENV.fetch('ZUBOKLIK_API_URL', 'https://zuboklik.cz/api/v1')
API_KEY = ENV.fetch('ZUBOKLIK_API_KEY')
# Where to start reading changes. A real integration stores the cursor of the last change it processed
# and never needs this; the example starts "now" unless told otherwise.
SINCE = ENV.fetch('ZUBOKLIK_SYNC_SINCE') { Time.now.utc.iso8601 }
EXTERNAL_ID = 'example-patient-1' # the id of this patient in YOUR system

# Raised for every non-2xx answer. `errors` is the parsed "errors" array, `body` the whole parsed response.
class ApiError < StandardError
  attr_reader :status, :errors, :body

  def initialize(status, body)
    @status = status
    @body = body || {}
    @errors = @body.fetch('errors', [])
    super("HTTP #{status}: #{@errors.map { |e| [e['attribute'], *e['message']].compact.join(' ') }.join('; ')}")
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
  raise ApiError.new(response.code.to_i, parsed) unless response.is_a?(Net::HTTPSuccess)

  parsed
end

# What your system does with one change. A webhook delivery has the same fields, so the same code handles both.
# Returns a line describing what was done.
def apply(change)
  collection = change['resource_type'] == 'Patient' ? 'patients' : 'entries'
  if change['action'] == 'destroy'
    "#{change['event']}: removed from our system"
  else
    api(:get, "/#{collection}/#{change['resource_id']}") # the current state of the record; save it on your side
    "#{change['event']}: saved to our system"
  end
rescue ApiError => e
  raise unless e.status == 404

  "#{change['event']}: already gone, removed from our system" # deleted again before we asked
end

new_patient = { patient: { first_name: 'Eva', last_name: 'Ukázková', phone_number: '+420777111222', external_id: EXTERNAL_ID } }

# 1. Pairing: is this patient of ours already in the practice? Ask by our own id; create only when not found.
#    (For the very first pairing of existing patients ask by birth number: GET /patients?pin=...)
found = api(:get, "/patients?external_id=#{EXTERNAL_ID}").fetch('patients')
patient = found.first || api(:post, '/patients', new_patient).fetch('patient')
puts "1. Patient paired: #{patient['first_name']} #{patient['last_name']}, external_id #{patient['external_id']}"

# 2. A repeated request (say, after a timeout) creates nothing: 409 and the existing record comes back.
begin
  api(:post, '/patients', new_patient)
  raise 'the API created the same patient twice'
rescue ApiError => e
  same = e.body.dig('patient', 'id') == patient['id']
  puts "2. Repeated request created nothing: HTTP #{e.status}, #{e.errors.first['name']}, same patient: #{same}"
end

# 3. From now on find the record by your own id.
found = api(:get, "/patients?external_id=#{EXTERNAL_ID}").fetch('patients')
puts "3. Found by external_id: #{found.size} patient(s)"

# 4. What changed in the practice since last time? Page by cursor until `more` is false.
#    Changes made by this key are left out; you see what the staff, the patients and other systems did.
applied = []
query = "since=#{URI.encode_www_form_component(SINCE)}"
loop do
  page = api(:get, "/changes?#{query}")
  page.fetch('changes').each { |change| applied << apply(change) }
  break unless page.fetch('meta').fetch('more')

  query = "after=#{page.fetch('meta').fetch('next_cursor')}" # store this cursor; next time start from it
end
puts "4. Changes from the practice: #{applied.size}"
applied.each { |line| puts "   #{line}" }

# 5. Clean up: give the external_id back, then deactivate the patient.
api(:patch, "/patients/#{patient['id']}", { patient: { external_id: nil } })
api(:delete, "/patients/#{patient['id']}")
puts '5. Cleaned up'
