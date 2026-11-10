# frozen_string_literal: true

# Zuboklik API example: verify the signature of an incoming webhook.
# Runs on plain Ruby 3.x, no gems.  Usage:  ruby verify_webhook.rb

require 'json'
require 'openssl'

MAX_AGE = 300 # seconds; older deliveries are refused (replay protection)

# secret    - the secret returned once by POST /api/v1/webhooks
# timestamp - the X-Zuboklik-Timestamp header
# body      - the raw request body, exactly as received (do not re-serialize the JSON)
# signature - the X-Zuboklik-Signature header, "sha256=<hex>"
def valid_webhook?(secret, timestamp, body, signature, now: Time.now.to_i)
  return false if (now - timestamp.to_i).abs > MAX_AGE

  expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{body}")}"
  OpenSSL.secure_compare(expected, signature)
end

vector = JSON.parse(File.read(File.join(__dir__, '..', 'test-vectors', 'webhook.json')))
secret, timestamp, body, signature = vector.values_at('secret', 'timestamp', 'body', 'signature')
now = timestamp.to_i + 10

puts "valid signature accepted: #{valid_webhook?(secret, timestamp, body, signature, now: now)}"
puts "tampered body rejected: #{!valid_webhook?(secret, timestamp, body.sub('4711', '4712'), signature, now: now)}"
puts "stale timestamp rejected: #{!valid_webhook?(secret, timestamp, body, signature, now: now + 3600)}"
