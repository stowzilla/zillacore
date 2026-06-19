# frozen_string_literal: true

# Zoho Mail outgoing webhook handler.
#
# Zoho Mail fires outgoing webhooks when emails match configured conditions.
# This handler receives those webhooks, verifies the HMAC-SHA256 signature,
# and dispatches notifications to Discord.
#
# Config: ~/.brainiac/zoho.json
# Docs: https://www.zoho.com/mail/help/dev-platform/webhook.html

require "English"
require_relative "../zoho_mail_api"

ZOHO_CONFIG_FILE = File.join(BRAINIAC_DIR, "zoho.json")

def load_zoho_config
  return {} unless File.exist?(ZOHO_CONFIG_FILE)

  JSON.parse(File.read(ZOHO_CONFIG_FILE))
rescue JSON::ParserError => e
  LOG.error "[Zoho] Failed to parse config: #{e.message}"
  {}
end

ZOHO_CONFIG = load_zoho_config

def reload_zoho_config!(force: false)
  return unless file_changed?(ZOHO_CONFIG_FILE, force: force)

  ZOHO_CONFIG.replace(load_zoho_config)
  LOG.info "[Zoho] Reloaded configuration"
end

def default_project_config
  key = default_project_key
  key ? PROJECTS[key] : PROJECTS.values.first
end

def zoho_triage_project_tags
  tags = ZOHO_CONFIG["triage_project_tags"]
  return "Use your best judgement to identify the relevant project." unless tags&.any?

  tags.map { |t| "  - `#{t["tag"]}` — #{t["description"]}" }.join("\n")
end

def zoho_triage_agent_assignment
  rules = ZOHO_CONFIG["triage_agent_assignment"]
  return "Assign to the default agent." unless rules&.any?

  rules.map { |r| "  - #{r}" }.join("\n")
end

# Zoho sends the signing secret in the X-Hook-Secret header on the very first
# request. We store it in the config file so subsequent requests can be verified.
# If the secret is already in the config, we use that.
def zoho_hook_secret
  ZOHO_CONFIG["hook_secret"]
end

def save_zoho_hook_secret(secret)
  ZOHO_CONFIG["hook_secret"] = secret
  File.write(ZOHO_CONFIG_FILE, JSON.pretty_generate(ZOHO_CONFIG))
  LOG.info "[Zoho] Saved hook_secret to #{ZOHO_CONFIG_FILE}"
end

# Verify the X-Hook-Signature header (base64 HMAC-SHA256 of the raw body).
def verify_zoho_signature!(request, payload_body)
  signature = request.env["HTTP_X_HOOK_SIGNATURE"]
  return unless signature # First request won't have a signature, just the secret

  secret = zoho_hook_secret
  halt 500, { error: "No hook_secret configured — waiting for initial Zoho handshake" }.to_json unless secret

  computed = Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", secret, payload_body))
  halt 403, { error: "Invalid Zoho signature" }.to_json unless Rack::Utils.secure_compare(signature, computed)
end

# Check if an email contains any of the exclude words (checked against subject, from, and body).
def zoho_email_excluded?(email, exclude_words)
  return false if exclude_words.nil? || exclude_words.empty?

  searchable = [email["subject"], email["fromAddress"], email["toAddress"], email["summary"], email["html"]].join(" ").downcase
  Array(exclude_words).any? { |word| searchable.include?(word.downcase) }
end

# Match an email against configured rules. Returns the first matching rule or nil.
# If no rules match, returns a fallback rule (if configured) so nothing is missed.
def match_zoho_rule(email)
  rules = ZOHO_CONFIG["rules"] || []
  rules.each do |rule|
    next if rule["enabled"] == false

    matches = true
    if rule["from_contains"] && !rule["from_contains"].empty? && !email["fromAddress"].to_s.downcase.include?(rule["from_contains"].downcase)
      matches = false
    end
    matches = false if rule["to_contains"] && !rule["to_contains"].empty? && !email["toAddress"].to_s.downcase.include?(rule["to_contains"].downcase)
    if rule["subject_contains"] && !rule["subject_contains"].empty? && !email["subject"].to_s.downcase.include?(rule["subject_contains"].downcase)
      matches = false
    end
    if rule["body_contains"] && !rule["body_contains"].empty?
      body = email["summary"].to_s + email["html"].to_s
      matches = false unless body.downcase.include?(rule["body_contains"].downcase)
    end
    matches = false if matches && zoho_email_excluded?(email, rule["exclude_words"])

    return rule if matches
  end

  # Fallback: post unmatched emails so nothing slips through
  fallback = zoho_fallback_rule
  return nil if fallback && zoho_email_excluded?(email, ZOHO_CONFIG.dig("fallback", "exclude_words"))

  fallback
end

# Returns the fallback rule config, or nil if not configured.
def zoho_fallback_rule
  fallback = ZOHO_CONFIG["fallback"]
  return nil unless fallback && fallback["enabled"] != false

  { "label" => fallback["label"] || "Unmatched Email",
    "emoji" => fallback["emoji"] || "📬",
    "discord_channel_id" => fallback["discord_channel_id"],
    "notify_as" => fallback["notify_as"] }
end

# Format a Discord notification for a matched email.
def format_zoho_notification(email, rule)
  label = rule["label"] || "Zoho Mail"
  emoji = rule["emoji"] || "📧"
  parts = ["#{emoji} **#{label}**"]
  parts << "**Subject:** #{email["subject"]}" if email["subject"]
  parts << "**From:** #{email["fromAddress"]}" if email["fromAddress"]
  parts << "**To:** #{email["toAddress"]}" if email["toAddress"]

  # Include body content — try webhook payload first, then fetch via API
  body_text = email["summary"].to_s.strip
  if body_text.empty?
    raw_html = (email["html"] || email["content"] || email["body"] || "").to_s
    body_text = raw_html.gsub(/<[^>]+>/, " ").gsub(/&nbsp;/i, " ").gsub(/\s+/, " ").strip
  end

  # If still empty and show_body requested, fetch via Zoho Mail API
  body_text = fetch_zoho_email_content(email["messageId"]).to_s if body_text.empty? && rule["show_body"] && email["messageId"]

  if !body_text.empty? && rule["show_body"]
    body_text = "#{body_text[0..1800]}..." if body_text.length > 1800
    parts << "```\n#{body_text}\n```"
  elsif !body_text.empty?
    body_text = "#{body_text[0..500]}..." if body_text.length > 500
    parts << "```\n#{body_text}\n```"
  end

  parts.join("\n")
end

# Send the notification to the configured Discord channel.
def notify_zoho_match(email, rule)
  channel_id = rule["discord_channel_id"] || ZOHO_CONFIG["default_discord_channel_id"]
  unless channel_id
    LOG.warn "[Zoho] No discord_channel_id configured for rule '#{rule["label"]}' and no default set"
    return
  end

  message = format_zoho_notification(email, rule)

  tokens = discord_bot_tokens
  bot_name = rule["notify_as"] || ZOHO_CONFIG["notify_as"] || tokens.keys.first
  token = tokens[bot_name&.downcase] || tokens.values.first

  unless token
    LOG.warn "[Zoho] No Discord bot token available to send notification"
    return
  end

  LOG.info "[Zoho] Sending notification to channel #{channel_id} (bot: #{bot_name})"
  send_discord_message(channel_id, message, token: token)
end

# ---------------------------------------------------------------------------
# Zoho Email Triage — dispatch an agent to decide if a support email needs a card
# ---------------------------------------------------------------------------

ZOHO_TRIAGE_DIR = File.join(BRAINIAC_DIR, "tmp", "zoho", "triage")
FileUtils.mkdir_p(ZOHO_TRIAGE_DIR)

ZOHO_TRIAGE_PROMPT = <<~PROMPT
  You are triaging a support email. Decide whether this email needs a Fizzy card or not.

  ## Email
  **From:** {{FROM}}
  **To:** {{TO}}
  **Subject:** {{SUBJECT}}
  **Body:**
  ```
  {{BODY}}
  ```

  ## Decision Criteria
  **Needs a card** (something is broken, a bug report, a feature request, a workflow issue):
  - Create a card with a clear title summarizing the issue
  - Tag with `support` plus a project tag if you can identify the relevant project
  - Assign to the appropriate agent

  **Does NOT need a card** (account questions, password resets, general inquiries, spam, marketing):
  - Just explain why briefly

  **Borderline** (you're not sure):
  - Mark as borderline and explain why — a human will decide

  ## Project Tags (use the tag name, not the ID)
  {{PROJECT_TAGS}}

  ## Agent Assignment
  {{AGENT_ASSIGNMENT}}

  ## Response Format
  Write ONLY valid JSON to stdout (no markdown, no explanation outside the JSON):

  For "needs a card":
  ```json
  {
    "decision": "create_card",
    "title": "Brief descriptive title for the card",
    "description": "HTML description with relevant details from the email",
    "project_tag": "project-tag-name or null",
    "assign_to": "Galen|Avon|Sheogorath"
  }
  ```

  For "does not need a card":
  ```json
  {
    "decision": "skip",
    "reason": "Brief explanation of why no card is needed"
  }
  ```

  For "borderline":
  ```json
  {
    "decision": "borderline",
    "reason": "Why you're unsure — what makes this ambiguous"
  }
  ```
PROMPT

# Dispatch an agent to triage a support email. The agent decides whether to create
# a Fizzy card or just notify Discord.
def dispatch_zoho_triage(email, rule)
  agent_name = rule["dispatch_agent"]
  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
  response_file = File.join(ZOHO_TRIAGE_DIR, "triage-#{timestamp}.json")
  log_file = File.join(ZOHO_TRIAGE_DIR, "triage-#{timestamp}.log")

  body = (email["summary"] || email["html"] || "").to_s.gsub(/\s+/, " ").strip
  body = body[0..2000] if body.length > 2000

  prompt = ZOHO_TRIAGE_PROMPT
           .gsub("{{FROM}}", email["fromAddress"].to_s)
           .gsub("{{TO}}", email["toAddress"].to_s)
           .gsub("{{SUBJECT}}", email["subject"].to_s)
           .gsub("{{BODY}}", body)
           .gsub("{{PROJECT_TAGS}}", zoho_triage_project_tags)
           .gsub("{{AGENT_ASSIGNMENT}}", zoho_triage_agent_assignment)

  prompt += "\n\nWrite your JSON response to: #{response_file}\n"

  prompt_file = File.join(ZOHO_TRIAGE_DIR, "triage-prompt-#{timestamp}.md")
  File.write(prompt_file, prompt)

  agent_key = agent_name.downcase.gsub(/[^a-z0-9-]/, "-")
  project_config = default_project_config

  resolved = project_config ? resolve_project_cli_config(project_config) : {}
  agent_cli = resolved["agent_cli"] || "kiro-cli"
  agent_cli_args = resolved["agent_cli_args"] || "chat --trust-all-tools --no-interactive"
  resolved["agent_model_flag"] || "--model"

  cmd = [agent_cli]
  cmd.push("--agent", agent_key)
  cmd.concat(agent_cli_args.split)
  add_trust_tools!(cmd, agent_cli_args)

  spawn_env = {}
  agent_env = agent_env_for(agent_name)
  spawn_env.merge!(agent_env) unless agent_env.empty?

  work_dir = project_config ? project_config["repo_path"] : Dir.pwd

  LOG.info "[Zoho:Triage] Dispatching #{agent_name} for: #{email["subject"]}"
  LOG.info "[Zoho:Triage] Command: #{cmd.join(" ")}"

  pid = spawn(spawn_env, *cmd,
              chdir: work_dir,
              in: prompt_file,
              out: [log_file, "w"],
              err: %i[child out])

  # Monitor in background — process the triage decision when agent finishes
  Thread.new do
    Process.wait(pid)
    exit_status = $CHILD_STATUS
    LOG.info "[Zoho:Triage] Agent finished (exit: #{exit_status.exitstatus})"

    decision = read_zoho_triage_response(response_file, log_file)
    if decision
      execute_zoho_triage_decision(decision, email, rule)
    else
      LOG.warn "[Zoho:Triage] No valid decision from agent — falling back to Discord notification"
      notify_zoho_match(email, rule)
    end

    # Cleanup prompt file after a delay
    Thread.new do
      sleep 300
      FileUtils.rm_f(prompt_file)
    end
  end

  pid
end

# Read the triage response — try the response file first, then extract from log
def read_zoho_triage_response(response_file, log_file)
  # Try response file
  if File.exist?(response_file) && !File.empty?(response_file)
    content = File.read(response_file).strip
    return parse_triage_json(content)
  end

  # Fallback: extract JSON from log output
  if File.exist?(log_file)
    log_content = File.read(log_file)
    # Look for JSON block in the log
    if (match = log_content.match(/\{[^{}]*"decision"\s*:\s*"[^"]+?"[^{}]*\}/m))
      return parse_triage_json(match[0])
    end
  end

  nil
end

def parse_triage_json(content)
  # Strip markdown code fences if present
  content = content.gsub(/```json\s*/, "").gsub(/```\s*/, "").strip
  JSON.parse(content)
rescue JSON::ParserError => e
  LOG.warn "[Zoho:Triage] Failed to parse response JSON: #{e.message}"
  nil
end

# Act on the triage decision
def execute_zoho_triage_decision(decision, email, rule)
  channel_id = rule["discord_channel_id"] || ZOHO_CONFIG["default_discord_channel_id"]
  tokens = discord_bot_tokens
  bot_name = rule["notify_as"] || ZOHO_CONFIG["notify_as"] || tokens.keys.first
  token = tokens[bot_name&.downcase] || tokens.values.first

  case decision["decision"]
  when "create_card"
    create_zoho_triage_card(decision, email, channel_id, token)
  when "skip"
    msg = "📧 **Support Email — No Card Needed**\n"
    msg += "**Subject:** #{email["subject"]}\n"
    msg += "**From:** #{email["fromAddress"]}\n"
    msg += "**Reason:** #{decision["reason"]}"
    send_discord_message(channel_id, msg, token: token) if channel_id && token
    LOG.info "[Zoho:Triage] Skipped card: #{decision["reason"]}"
  when "borderline"
    msg = "⚠️ **Support Email — Needs Human Decision**\n"
    msg += "**Subject:** #{email["subject"]}\n"
    msg += "**From:** #{email["fromAddress"]}\n"
    msg += "**Why borderline:** #{decision["reason"]}\n"
    summary = (email["summary"] || "").to_s[0..300]
    msg += "```\n#{summary}\n```" unless summary.empty?
    send_discord_message(channel_id, msg, token: token) if channel_id && token
    LOG.info "[Zoho:Triage] Borderline — posted to Discord for human decision"
  else
    LOG.warn "[Zoho:Triage] Unknown decision: #{decision["decision"]}"
    notify_zoho_match(email, rule)
  end
end

# Create a Fizzy card from the triage decision
def create_zoho_triage_card(decision, email, channel_id, token)
  board_id = ZOHO_CONFIG["triage_board_id"]
  unless board_id
    LOG.error "[Zoho:Triage] No triage_board_id configured in zoho.json"
    return
  end
  title = decision["title"] || email["subject"]
  description = decision["description"] || "<p>Support email from #{email["fromAddress"]}: #{email["subject"]}</p>"

  # Build tag list — always include 'support', plus project tag if identified
  tags = ["support"]
  tags << decision["project_tag"] if decision["project_tag"]

  # Resolve tag IDs
  tag_ids = resolve_zoho_triage_tags(tags)

  # Create the card
  cmd = ["fizzy", "card", "create", "--board", board_id, "--title", title, "--description", description]
  cmd.push("--tag-ids", tag_ids.join(",")) unless tag_ids.empty?

  # Use the triage agent's env for fizzy token
  agent_name = "Threepio"
  agent_env = agent_env_for(agent_name)
  spawn_env = agent_env.empty? ? {} : agent_env

  output, status = Open3.capture2e(spawn_env, *cmd)
  unless status.success?
    LOG.error "[Zoho:Triage] Failed to create card: #{output}"
    notify_zoho_match(email, { "label" => "Support Email (card creation failed)", "emoji" => "❌" }.merge(rule_defaults(nil)))
    return
  end

  # Parse card number from response
  card_data = JSON.parse(output)
  card_number = card_data.dig("data", "number")
  card_url = card_data.dig("data", "url")
  LOG.info "[Zoho:Triage] Created card ##{card_number}: #{title}"

  # Assign to the appropriate agent
  assign_zoho_triage_card(card_number, decision["assign_to"], spawn_env) if card_number && decision["assign_to"]

  # Notify Discord
  if channel_id && token
    msg = "🎫 **Support Card Created: [##{card_number}](#{card_url})**\n"
    msg += "**Title:** #{title}\n"
    msg += "**Assigned to:** #{decision["assign_to"] || "unassigned"}\n"
    msg += "**Tags:** #{tags.join(", ")}\n"
    msg += "**From:** #{email["fromAddress"]}"
    send_discord_message(channel_id, msg, token: token)
  end
rescue StandardError => e
  LOG.error "[Zoho:Triage] Error creating card: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
  notify_zoho_match(email, { "label" => "Support Email", "emoji" => "🆘" }.merge(rule_defaults(nil)))
end

# Resolve tag names to IDs by querying Fizzy
def resolve_zoho_triage_tags(tag_names)
  agent_env = agent_env_for("Threepio")
  spawn_env = agent_env.empty? ? {} : agent_env

  output, status = Open3.capture2e(spawn_env, "fizzy", "tag", "list", "--all")
  return [] unless status.success?

  all_tags = JSON.parse(output)["data"] || []
  tag_names.filter_map do |name|
    tag = all_tags.find { |t| t["title"].downcase == name.downcase }
    tag&.dig("id")
  end
rescue StandardError => e
  LOG.warn "[Zoho:Triage] Failed to resolve tags: #{e.message}"
  []
end

# Assign a card to the appropriate agent
def assign_zoho_triage_card(card_number, agent_name, spawn_env)
  # Map agent names to Fizzy user IDs
  agent_user_ids = {
    "Galen" => "03fja52opiykf0mua7aeqv8uk",
    "Avon" => "03fnwe6kl4g2t8xw0djbfkv96",
    "Sheogorath" => "03fnwjyt6gighy98ld46u2hni"
  }

  user_id = agent_user_ids[agent_name]
  unless user_id
    LOG.warn "[Zoho:Triage] Unknown agent for assignment: #{agent_name}"
    return
  end

  output, status = Open3.capture2e(spawn_env, "fizzy", "card", "assign", card_number.to_s, "--user", user_id)
  if status.success?
    LOG.info "[Zoho:Triage] Assigned card ##{card_number} to #{agent_name}"
  else
    LOG.warn "[Zoho:Triage] Failed to assign card ##{card_number}: #{output}"
  end
end

def rule_defaults(rule)
  { "discord_channel_id" => rule&.dig("discord_channel_id") || ZOHO_CONFIG["default_discord_channel_id"],
    "notify_as" => rule&.dig("notify_as") || ZOHO_CONFIG["notify_as"] }
end
