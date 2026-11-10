# frozen_string_literal: true

# Zuboklik API example: register a webhook, list webhooks, see a refused URL, switch the webhook off.
# Runs on plain Ruby 3.x, no gems.  Usage:  ZUBOKLIK_API_KEY=... ruby webhooks.rb
# How to verify what the webhook then receives: verify_webhook.rb.

require 'json'
require 'net/http'

API_URL = ENV.fetch('ZUBOKLIK_API_URL', 'https://zuboklik.cz/api/v1')
API_KEY = ENV.fetch('ZUBOKLIK_API_KEY')
WEBHOOK_URL = 'https://example.com/zuboklik-webhook' # your endpoint; must be https and publicly reachable

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

def active_count
  api(:get, '/webhooks').fetch('webhooks').count { |webhook| webhook['status'] == 'active' }
end

# 1. Register the URL. The secret for verifying deliveries comes back only now - store it.
registered = api(:post, '/webhooks', { webhook: { url: WEBHOOK_URL } })
webhook = registered.fetch('webhook')
puts "1. Webhook registered: #{webhook['url']} (#{webhook['status']}, secret of #{registered.fetch('secret').length} characters)"

# 2. List the webhooks of this connected system.
puts "2. Webhooks listed: #{active_count} active"

# 3. A URL that is not https (or points to a private address) is refused with 422.
begin
  api(:post, '/webhooks', { webhook: { url: 'http://example.com/zuboklik-webhook' } })
  raise 'the API accepted a plain http URL'
rescue ApiError => e
  puts "3. Plain http refused: HTTP #{e.status}, attribute #{e.errors.first['attribute']}"
end

# 4. Switch the webhook off. Registering the same URL again switches it back on with a new secret.
api(:delete, "/webhooks/#{webhook['id']}")
puts "4. Webhook switched off, #{active_count} active"
