# frozen_string_literal: true

# Zuboklik API example: create patients, page through the list, read, update and deactivate one, see 404 and 401.
# Runs on plain Ruby 3.x, no gems.  Usage:  ZUBOKLIK_API_KEY=... ruby patients.rb

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
def api(method, path, body = nil, key: API_KEY)
  uri = URI("#{API_URL}#{path}")
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request['Authorization'] = "Bearer #{key}"
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

# 1. Create two patients.
jana = api(:post, '/patients', { patient: { first_name: 'Jana', last_name: 'Ukázková', phone_number: '+420777111222' } }).fetch('patient')
petr = api(:post, '/patients', { patient: { first_name: 'Petr', last_name: 'Ukázkový', email: 'petr.ukazkovy@example.com' } }).fetch('patient')
puts "1. Patients created: #{jana['first_name']} #{jana['last_name']} and #{petr['first_name']} #{petr['last_name']}"

# 2. Page through the whole list, 100 patients per request (the maximum). `meta` says how many pages there are.
patients = []
page = 1
loop do
  list = api(:get, "/patients?page=#{page}&per_page=100")
  patients.concat(list.fetch('patients'))
  break if page >= list.fetch('meta').fetch('total_pages')

  page += 1
end
ours = patients.count { |patient| [jana['id'], petr['id']].include?(patient['id']) }
puts "2. Patients listed: #{patients.size} on #{page} page(s), ours among them: #{ours}"

# 3. Read one patient.
detail = api(:get, "/patients/#{jana['id']}").fetch('patient')
puts "3. Patient read: #{detail['first_name']} #{detail['last_name']}"

# 4. Update: only the attributes you send change.
updated = api(:patch, "/patients/#{jana['id']}", { patient: { email: 'jana.ukazkova@example.com' } }).fetch('patient')
puts "4. Patient updated: #{updated['email']}, still #{updated['last_name']}"

# 5. Deactivate both. The record stays in the practice's card index, the API no longer returns it.
api(:delete, "/patients/#{jana['id']}")
api(:delete, "/patients/#{petr['id']}")
puts '5. Patients deactivated'

# 6. A deactivated (or unknown) patient answers 404.
begin
  api(:get, "/patients/#{jana['id']}")
  raise 'the API still returns a deactivated patient'
rescue ApiError => e
  puts "6. Deactivated patient not found: HTTP #{e.status}, #{e.errors.first['name']}"
end

# 7. A wrong key answers 401.
begin
  api(:get, '/patients', key: 'not-a-valid-key')
  raise 'the API accepted a wrong key'
rescue ApiError => e
  puts "7. Wrong key refused: HTTP #{e.status}, #{e.errors.first['name']}"
end
