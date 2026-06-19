# frozen_string_literal: true

# Zoho Mail REST API client for fetching email content.
# Used when webhook payloads don't include the body (which is most of the time).
#
# Requires zoho.json to have:
#   "api": {
#     "client_id": "...",
#     "client_secret": "...",
#     "refresh_token": "...",
#     "account_id": "..."
#   }

ZOHO_TOKEN_URL = "https://accounts.zoho.com/oauth/v2/token"
ZOHO_MAIL_API_BASE = "https://mail.zoho.com/api/accounts"

# In-memory cache for access token (expires after ~55 min to be safe)
@zoho_access_token = nil
@zoho_token_expires_at = Time.at(0)

def zoho_api_configured?
  api = ZOHO_CONFIG["api"]
  api && api["client_id"] && api["client_secret"] && api["refresh_token"] && api["account_id"]
end

def zoho_refresh_access_token!
  api = ZOHO_CONFIG["api"]
  uri = URI(ZOHO_TOKEN_URL)
  res = Net::HTTP.post_form(uri, {
                              "grant_type" => "refresh_token",
                              "client_id" => api["client_id"],
                              "client_secret" => api["client_secret"],
                              "refresh_token" => api["refresh_token"]
                            })

  data = JSON.parse(res.body)
  if data["access_token"]
    @zoho_access_token = data["access_token"]
    @zoho_token_expires_at = Time.now + 3300 # ~55 min
    LOG.info "[Zoho:API] Refreshed access token"
    @zoho_access_token
  else
    LOG.error "[Zoho:API] Token refresh failed: #{data["error"]}"
    nil
  end
rescue StandardError => e
  LOG.error "[Zoho:API] Token refresh error: #{e.message}"
  nil
end

def zoho_access_token
  return @zoho_access_token if @zoho_access_token && Time.now < @zoho_token_expires_at

  zoho_refresh_access_token!
end

# Fetch email content by messageId using the "original message" endpoint.
# This endpoint doesn't require a folder ID — just accountId + messageId.
# Returns plain-text body extracted from the MIME content, or nil.
def fetch_zoho_email_content(message_id)
  return nil unless zoho_api_configured?

  token = zoho_access_token
  return nil unless token

  account_id = ZOHO_CONFIG.dig("api", "account_id")
  uri = URI("#{ZOHO_MAIL_API_BASE}/#{account_id}/messages/#{message_id}/originalmessage")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Zoho-oauthtoken #{token}"
  req["Accept"] = "application/json"

  res = http.request(req)
  data = JSON.parse(res.body)

  if data.dig("status", "code") == 200
    raw_mime = data.dig("data", "content").to_s
    text = extract_text_from_mime(raw_mime)
    LOG.info "[Zoho:API] Fetched content for message #{message_id} (#{text.length} chars)"
    text
  else
    LOG.warn "[Zoho:API] Failed to fetch content: #{data.dig("status", "description")}"
    nil
  end
rescue StandardError => e
  LOG.error "[Zoho:API] Error fetching content: #{e.message}"
  nil
end

# Extract readable text from raw MIME content.
# Prefers text/plain part; falls back to stripping HTML from text/html part.
def extract_text_from_mime(mime)
  # Try to find text/plain part
  if mime =~ %r{Content-Type: text/plain[^\r\n]*\r?\n(?:Content-Transfer-Encoding:[^\r\n]*\r?\n)?(?:\r?\n)(.*?)(?:\r?\n------=_Part|\z)}mi
    return Regexp.last_match(1).gsub("\r\n", "\n").strip
  end

  # Fallback: extract text/html part and strip tags
  if mime =~ %r{Content-Type: text/html[^\r\n]*\r?\n(?:Content-Transfer-Encoding:[^\r\n]*\r?\n)?(?:\r?\n)(.*?)(?:\r?\n------=_Part|\z)}mi
    html = Regexp.last_match(1).gsub("\r\n", "\n")
    return html.gsub(/<[^>]+>/, " ").gsub(/&nbsp;/i, " ").gsub(/&amp;/i, "&")
               .gsub(/&lt;/i, "<").gsub(/&gt;/i, ">").gsub(/\s+/, " ").strip
  end

  # Last resort: strip all HTML-ish content from the whole thing
  mime.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
end
