#!/usr/bin/env ruby

# Brainiac — modular webhook receiver
#
# This is the thin entry point. All logic lives in lib/brainiac/*.
# Start with: ruby receiver.rb

require "sinatra"
require "json"

# Load all modules
require_relative "lib/brainiac/config"
require_relative "lib/brainiac/users"
require_relative "lib/brainiac/agents"
require_relative "lib/brainiac/brain"
require_relative "lib/brainiac/skills"
require_relative "lib/brainiac/sessions"
require_relative "lib/brainiac/prompts"
require_relative "lib/brainiac/planning"
require_relative "lib/brainiac/helpers"
require_relative "lib/brainiac/cron"
require_relative "lib/brainiac/handlers/fizzy"
require_relative "lib/brainiac/handlers/github"
require_relative "lib/brainiac/card_index"
require_relative "lib/brainiac/deployments"

# Reload hook registry — custom handlers register callbacks here
module ReloadHooks
  @hooks = []

  def self.register(name, &block)
    @hooks << { name: name, block: block }
  end

  def self.run_all!
    @hooks.each { |hook| hook[:block].call }
  end
end

def register_reload_hook(name, &)
  ReloadHooks.register(name, &)
end

# Load custom handlers from ~/.brainiac/handlers/ (plugin system)
CUSTOM_HANDLERS_DIR = File.join(BRAINIAC_DIR, "handlers")
if Dir.exist?(CUSTOM_HANDLERS_DIR)
  Dir.glob(File.join(CUSTOM_HANDLERS_DIR, "*.rb")).each do |handler|
    LOG.info "[Handlers] Loading custom handler: #{File.basename(handler)}"
    require handler
  end
end

if DISCORD_ENABLED
  require_relative "lib/brainiac/handlers/discord"
  require_relative "lib/brainiac/handlers/zoho"
end

# --- Sinatra config ---
set :host_authorization, { permit_all: true }

# Disable Sinatra's default logging (we use SelectiveLogger instead)
set :logging, false

# Suppress Sinatra/Puma startup banners — we log our own version line
disable :show_exceptions
set :quiet, true
set :server_settings, { Silent: true }

# Custom logger that filters polling endpoints unless LOG_LEVEL=debug
SILENT_POLL_PATHS = %w[/api/status /api/deployments].freeze

class SelectiveLogger < Rack::CommonLogger
  def call(env)
    if SILENT_POLL_PATHS.include?(env["PATH_INFO"]) && LOG.level > Logger::DEBUG
      @app.call(env)
    else
      super
    end
  end
end

configure do
  use SelectiveLogger, LOG
end

LOG.info "[Brainiac] Starting v#{BRAINIAC_VERSION} on port #{settings.port} (#{settings.environment})"

# --- Dashboard authentication ---

helpers do
  def authenticate_dashboard!
    return unless DASHBOARD_TOKEN # No token configured = no auth (local-only mode)

    provided = params["token"] || request.env["HTTP_AUTHORIZATION"]&.sub(/^Bearer /i, "")
    halt 401, "Unauthorized" unless provided == DASHBOARD_TOKEN
  end

  def localhost_request?
    host = request.env["HTTP_HOST"].to_s
    host.include?("localhost") || host.include?("127.0.0.1")
  end
end

before "/dashboard" do
  authenticate_dashboard!
end

before "/api/*" do
  # Skip auth for all localhost requests (CLI, waybar, daemon, etc.)
  pass if localhost_request?
  # Skip auth for webhook-related routes that have their own verification
  pass if request.path_info == "/api/discord"
  authenticate_dashboard!
end

# --- Fizzy webhook routes ---

post "/fizzy/?:board_key?" do
  content_type :json
  request.body.rewind
  payload_body = request.body.read
  board_key = params["board_key"]

  verify_signature!(request, payload_body, board_key: board_key)

  payload = JSON.parse(payload_body)

  event_id = payload["id"]
  action = payload["action"]

  LOG.info "[Fizzy] Received event #{event_id}: action=#{action}"

  if already_processed?(event_id)
    LOG.info "Skipping duplicate event #{event_id}"
    halt 200, { status: "duplicate" }.to_json
  end

  reload_projects!
  reload_agent_registry!
  reload_github_config!

  case action
  when "card_assigned"
    status_code, body = handle_card_assigned(payload)
    LOG.info "[Fizzy] #{action} response: #{status_code} - #{body}"
    halt status_code, body
  when "comment_created"
    status_code, body = handle_comment(payload)
    LOG.info "[Fizzy] comment_created response: #{status_code} - #{body}"
    halt status_code, body
  when "card_published", "card_triaged"
    eventable = payload["eventable"] || {}
    card_number = eventable["number"]&.to_s

    # card_triaged never dispatches agents — only card_assigned and @mentions do that.
    # Guards remain as defense-in-depth for any future column-based routing.
    if action == "card_triaged" && card_number
      if self_move_recent?(card_number)
        LOG.info "[Fizzy] Ignoring card_triaged for ##{card_number} — self-move echo"
        halt 200, { status: "ignored", reason: "self_move" }.to_json
      end

      if card_merged?(card_number)
        LOG.info "[Fizzy] Ignoring card_triaged for ##{card_number} — card already merged"
        halt 200, { status: "ignored", reason: "card_merged" }.to_json
      end

      card_key = "card-#{card_number}"
      if recently_completed?(card_key)
        LOG.info "[Fizzy] Ignoring card_triaged for ##{card_number} — recently completed"
        halt 200, { status: "ignored", reason: "recently_completed" }.to_json
      end
    end

    # Only card_published does duplicate detection — card_triaged skips agent dispatch entirely
    if action == "card_published"
      assignees = eventable["assignees"] || []
      if assignees.any? { |a| local_agent_names.include?(a["name"]) }
        status_code, body = handle_card_assigned(payload)
        LOG.info "[Fizzy] #{action} (with assignee) response: #{status_code} - #{body}"
        halt status_code, body
      end
    end

    status_code, body = handle_card_published(payload)
    LOG.info "[Fizzy] #{action} response: #{status_code} - #{body}"
    halt status_code, body
  else
    LOG.info "[Fizzy] Ignoring unknown action: #{action}"
    halt 200, { status: "ignored", action: action }.to_json
  end
rescue JSON::ParserError => e
  LOG.error "Invalid JSON: #{e.message}"
  halt 400, { error: "Invalid JSON" }.to_json
rescue StandardError => e
  LOG.error "Unhandled error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
  halt 500, { error: e.message }.to_json
end

post "/github" do
  content_type :json
  request.body.rewind
  payload_body = request.body.read

  verify_github_signature!(request, payload_body)

  payload = JSON.parse(payload_body)
  event = request.env["HTTP_X_GITHUB_EVENT"]

  reload_projects!
  reload_agent_registry!
  reload_github_config!

  action = payload["action"]

  case event
  when "pull_request"
    if action == "closed" && payload.dig("pull_request", "merged")
      status_code, body = handle_github_pr_merged(payload)
      halt status_code, body
    elsif action == "opened"
      track_pr_in_card_map(payload)
      halt 200, { status: "processed", action: "pr_tracked" }.to_json
    elsif action == "synchronize"
      status_code, body = handle_github_pr_synchronized(payload)
      halt status_code, body
    else
      halt 200, { status: "ignored", reason: "pull_request action: #{action}" }.to_json
    end
  when "pull_request_review"
    if action == "submitted"
      status_code, body = handle_github_pr_review_submitted(payload)
      halt status_code, body
    else
      halt 200, { status: "ignored", reason: "pull_request_review action: #{action}" }.to_json
    end
  when "issue_comment"
    if action == "created"
      status_code, body = handle_github_issue_comment(payload)
      halt status_code, body
    else
      halt 200, { status: "ignored", reason: "issue_comment action: #{action}" }.to_json
    end
  when "issues"
    if action == "opened"
      status_code, body = handle_github_issue_opened(payload)
      halt status_code, body
    else
      halt 200, { status: "ignored", reason: "issues action: #{action}" }.to_json
    end
  when "workflow_run"
    if action == "completed"
      status_code, body = handle_github_workflow_run(payload)
      halt status_code, body
    else
      halt 200, { status: "ignored", reason: "workflow_run action: #{action}" }.to_json
    end
  when "ping"
    halt 200, { status: "pong" }.to_json
  else
    halt 200, { status: "ignored", event: event }.to_json
  end
rescue JSON::ParserError => e
  LOG.error "Invalid JSON: #{e.message}"
  halt 400, { error: "Invalid JSON" }.to_json
rescue StandardError => e
  LOG.error "Unhandled error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
  halt 500, { error: e.message }.to_json
end

# --- Zoho Mail webhook route ---

if DISCORD_ENABLED
  post "/zoho" do
    content_type :json
    request.body.rewind
    payload_body = request.body.read

    # Zoho sends X-Hook-Secret on the very first request — capture and store it
    hook_secret = request.env["HTTP_X_HOOK_SECRET"]
    if hook_secret
      save_zoho_hook_secret(hook_secret)
      LOG.info "[Zoho] Received and stored hook_secret from initial handshake"
      halt 200, { status: "hook_secret_received" }.to_json
    end

    verify_zoho_signature!(request, payload_body)

    email = JSON.parse(payload_body)
    LOG.info "[Zoho] Received email: subject=#{email["subject"]}, from=#{email["fromAddress"]}, to=#{email["toAddress"]}"
    LOG.info "[Zoho] Payload keys: #{email.keys.sort.join(", ")}"
    LOG.info "[Zoho] summary=#{email["summary"].to_s[0..200].inspect}, html=#{email["html"].to_s[0..200].inspect}, content=#{email["content"].to_s[0..200].inspect}"

    # Dump raw payload for debugging (last 5 kept)
    zoho_debug_dir = File.join(BRAINIAC_DIR, "tmp", "zoho", "payloads")
    FileUtils.mkdir_p(zoho_debug_dir)
    File.write(File.join(zoho_debug_dir, "#{Time.now.strftime("%Y%m%d-%H%M%S")}.json"), JSON.pretty_generate(email))

    reload_zoho_config!
    rule = match_zoho_rule(email)

    if rule
      LOG.info "[Zoho] Matched rule: #{rule["label"]}"
      if rule["dispatch_agent"]
        dispatch_zoho_triage(email, rule)
        halt 200, { status: "triage_dispatched", rule: rule["label"], agent: rule["dispatch_agent"] }.to_json
      else
        notify_zoho_match(email, rule)
        halt 200, { status: "matched", rule: rule["label"] }.to_json
      end
    else
      LOG.info "[Zoho] No rules matched"
      halt 200, { status: "no_match" }.to_json
    end
  rescue JSON::ParserError => e
    LOG.error "[Zoho] Invalid JSON: #{e.message}"
    halt 400, { error: "Invalid JSON" }.to_json
  rescue StandardError => e
    LOG.error "[Zoho] Unhandled error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    halt 500, { error: e.message }.to_json
  end
end

# --- Zoho OAuth routes ---

if DISCORD_ENABLED
  ZOHO_AUTH_SCOPES = "ZohoMail.messages.READ,ZohoMail.accounts.READ,ZohoMail.folders.READ".freeze

  get "/zoho/auth" do
    reload_zoho_config!
    api = ZOHO_CONFIG["api"] || {}
    halt 500, "Missing client_id in zoho.json api section" unless api["client_id"]

    redirect_uri = "#{request.base_url}/zoho/callback"
    params = URI.encode_www_form(
      scope: ZOHO_AUTH_SCOPES,
      client_id: api["client_id"],
      response_type: "code",
      access_type: "offline",
      redirect_uri: redirect_uri,
      prompt: "consent"
    )
    redirect "https://accounts.zoho.com/oauth/v2/auth?#{params}"
  end

  get "/zoho/callback" do
    content_type :html
    code = params["code"]
    halt 400, "No authorization code received" unless code

    reload_zoho_config!
    api = ZOHO_CONFIG["api"] || {}
    redirect_uri = "#{request.base_url}/zoho/callback"

    uri = URI(ZOHO_TOKEN_URL)
    res = Net::HTTP.post_form(uri, {
                                "grant_type" => "authorization_code",
                                "client_id" => api["client_id"],
                                "client_secret" => api["client_secret"],
                                "code" => code,
                                "redirect_uri" => redirect_uri
                              })

    data = JSON.parse(res.body)
    if data["refresh_token"]
      ZOHO_CONFIG["api"] ||= {}
      ZOHO_CONFIG["api"]["refresh_token"] = data["refresh_token"]
      @zoho_access_token = data["access_token"]
      @zoho_token_expires_at = Time.now + 3300
      File.write(ZOHO_CONFIG_FILE, JSON.pretty_generate(ZOHO_CONFIG))
      LOG.info "[Zoho:OAuth] Stored refresh_token and access_token"

      # Auto-fetch account_id if not set
      unless ZOHO_CONFIG.dig("api", "account_id")
        acct_uri = URI(ZOHO_MAIL_API_BASE.to_s)
        http = Net::HTTP.new(acct_uri.host, acct_uri.port)
        http.use_ssl = true
        req = Net::HTTP::Get.new(acct_uri)
        req["Authorization"] = "Zoho-oauthtoken #{@zoho_access_token}"
        acct_res = http.request(req)
        acct_data = JSON.parse(acct_res.body)
        if (account_id = acct_data.dig("data", 0, "accountId"))
          ZOHO_CONFIG["api"]["account_id"] = account_id
          File.write(ZOHO_CONFIG_FILE, JSON.pretty_generate(ZOHO_CONFIG))
          LOG.info "[Zoho:OAuth] Auto-fetched account_id: #{account_id}"
        end
      end

      "<h1>✅ Zoho OAuth Complete</h1><p>Refresh token and account_id saved to zoho.json. You can close this tab.</p>"
    else
      LOG.error "[Zoho:OAuth] Token exchange failed: #{data}"
      "<h1>❌ OAuth Failed</h1><pre>#{data.to_json}</pre>"
    end
  rescue StandardError => e
    LOG.error "[Zoho:OAuth] Error: #{e.message}"
    "<h1>❌ Error</h1><pre>#{e.message}</pre>"
  end
end

# --- Admin API routes ---

get "/api/projects" do
  content_type :json
  reload_projects!
  { projects: PROJECTS }.to_json
end

get "/api/projects/:key" do
  content_type :json
  reload_projects!
  project_key = params["key"]
  if PROJECTS.key?(project_key)
    { project: PROJECTS[project_key] }.to_json
  else
    halt 404, { error: "Project not found" }.to_json
  end
end

post "/api/reload" do
  content_type :json
  reload_projects!(force: true)
  reload_agent_registry!(force: true)
  reload_user_registry!(force: true)
  reload_github_config!(force: true)
  reload_deployments_config!(force: true)
  ReloadHooks.run_all!
  { status: "reloaded", projects: PROJECTS.keys, agents: all_agent_names.to_a, registry: AGENT_REGISTRY.keys,
    users: USER_REGISTRY["users"].size }.to_json
end

get "/api/agents" do
  content_type :json
  { default: AI_AGENT_NAME, agents: discover_kiro_agents, all_known: all_agent_names.to_a, roster: agent_roster }.to_json
end

get "/api/users" do
  content_type :json
  reload_user_registry!

  filter = params["filter"]
  users = case filter
          when "humans" then human_users
          when "agents" then ai_agents
          else USER_REGISTRY["users"]
          end

  { users: users, total: USER_REGISTRY["users"].size, schema_version: USER_REGISTRY["schema_version"] }.to_json
end

get "/api/users/:identifier" do
  content_type :json
  reload_user_registry!

  identifier = params["identifier"]
  user = find_user(identifier)

  if user
    { user: user }.to_json
  else
    halt 404, { error: "User not found", identifier: identifier }.to_json
  end
end

# --- Brain API routes ---

get "/api/brain" do
  content_type :json
  agent = params["agent"] || AI_AGENT_NAME
  persona_dir = persona_dir_for(agent)
  persona_col = persona_collection_for(agent)

  knowledge_files = File.directory?(KNOWLEDGE_DIR) ? Dir.glob(File.join(KNOWLEDGE_DIR, "**", "*.md")).map { |f| f.sub("#{KNOWLEDGE_DIR}/", "") } : []
  persona_files = File.directory?(persona_dir) ? Dir.glob(File.join(persona_dir, "**", "*.md")).map { |f| f.sub("#{persona_dir}/", "") } : []

  {
    agent: agent,
    knowledge: { dir: KNOWLEDGE_DIR, collection: KNOWLEDGE_COLLECTION, files: knowledge_files },
    persona: { dir: persona_dir, collection: persona_col, files: persona_files }
  }.to_json
end

get "/api/brain/search" do
  content_type :json
  query = params["q"]
  halt 400, { error: "Missing query parameter ?q=" }.to_json unless query && !query.empty?

  agent = params["agent"] || AI_AGENT_NAME
  scope = (params["scope"] || "knowledge").to_sym
  scope = :knowledge unless %i[knowledge persona].include?(scope)
  results = query_brain(query, agent_name: agent, scope: scope, max_results: (params["n"] || 5).to_i)

  { agent: agent, scope: scope, query: query, results: results }.to_json
end

get "/api/skills" do
  content_type :json
  skills = build_skill_index
  { total: skills.size, skills: skills }.to_json
end

post "/api/skills/curate" do
  content_type :json
  result = curate_skills
  result.to_json
end

get "/api/card-index" do
  content_type :json
  query = params["q"]
  if query && !query.empty?
    similar = CARD_INDEX.find_similar_cards(query)
    { query: query, matches: similar, total_indexed: CARD_INDEX.size }.to_json
  else
    { total: CARD_INDEX.size, cards: CARD_INDEX }.to_json
  end
end

get "/api/dispatch-depth" do
  content_type :json
  {
    max_depth: AGENT_DISPATCH_MAX_DEPTH,
    window_seconds: AGENT_DISPATCH_WINDOW,
    cards: AGENT_DISPATCH_DEPTH.transform_values do |v|
      { count: v[:count], last_human_at: v[:last_human_at]&.iso8601, blocked: v[:count] >= AGENT_DISPATCH_MAX_DEPTH }
    end
  }.to_json
end

get "/api/status" do
  content_type :json
  ACTIVE_SESSIONS_MUTEX.synchronize do
    # Clean up stale sessions first
    ACTIVE_SESSIONS.delete_if do |card_key, info|
      Process.kill(0, info[:pid])
      false # Keep alive sessions
    rescue Errno::ESRCH, Errno::EPERM
      archive_session(card_key, info)
      true # Remove dead sessions
    end

    sessions = ACTIVE_SESSIONS.map do |card_key, info|
      # Use stored agent_name if available, otherwise try to extract from card_key
      agent_name = if info[:agent_name]
                     info[:agent_name]
                   else
                     # Fallback: extract from card_key for backwards compatibility
                     # Formats: "discord-AGENT-CHANNEL-MESSAGE" or "card-ID"
                     parts = card_key.split("-")
                     agent_key = if parts[0] == "discord" && parts.size >= 4
                                   parts[1] # Second part is agent name
                                 else
                                   "Unknown"
                                 end
                     fizzy_display_name(agent_key)
                   end

      {
        card_key: card_key,
        agent: agent_name,
        pid: info[:pid],
        started_at: info[:started_at].iso8601,
        elapsed_seconds: (Time.now - info[:started_at]).to_i,
        log_file: info[:log_file],
        alive: true,
        children: child_processes_for(info[:pid])
      }
    end

    recent = RECENT_SESSIONS.map do |s|
      {
        card_key: s[:card_key],
        agent: s[:agent_name] || "Unknown",
        log_file: s[:log_file],
        started_at: s[:started_at]&.iso8601,
        finished_at: s[:finished_at]&.iso8601
      }
    end

    { sessions: sessions, count: sessions.size, recent: recent, version: BRAINIAC_VERSION }.to_json
  end
end

# Kill an entire agent session (parent process + all children)
post "/api/sessions/kill/:card_key" do
  content_type :json
  card_key = params[:card_key]
  halt 400, { error: "missing card_key" }.to_json if card_key.to_s.empty?

  killed = kill_session(card_key)
  halt 404, { error: "session not found" }.to_json unless killed

  LOG.info "Killed agent session #{card_key} via API"
  { killed: card_key }.to_json
end

# Kill a specific child process of an active agent session
post "/api/sessions/kill-process/:pid" do
  content_type :json
  target_pid = params[:pid].to_i
  halt 400, { error: "invalid pid" }.to_json if target_pid <= 0

  # Verify the target PID is actually a descendant of an active session
  valid = ACTIVE_SESSIONS_MUTEX.synchronize do
    ACTIVE_SESSIONS.any? do |_, info|
      child_processes_for(info[:pid]).any? { |c| c[:pid] == target_pid }
    end
  end
  halt 403, { error: "pid is not a child of any active agent session" }.to_json unless valid

  begin
    Process.kill("TERM", target_pid)
    # Give it a moment, then force kill if still alive
    Thread.new do
      sleep 3
      begin
        Process.kill(0, target_pid)
        Process.kill("KILL", target_pid)
      rescue Errno::ESRCH, Errno::EPERM # rubocop:disable Lint/SuppressedException
      end
    end
    LOG.info "Killed child process #{target_pid} (SIGTERM)"
    { killed: target_pid }.to_json
  rescue Errno::ESRCH
    halt 404, { error: "process not found" }.to_json
  rescue Errno::EPERM
    halt 403, { error: "permission denied" }.to_json
  end
end

# --- Dashboard ---

WAYBAR_CONFIG_PATH = File.expand_path("~/.brainiac/waybar.json")

def load_dashboard_agents
  return {} unless File.exist?(WAYBAR_CONFIG_PATH)

  config = JSON.parse(File.read(WAYBAR_CONFIG_PATH))
  agents = {}
  (config["agents"] || []).each { |a| agents[a["name"].downcase] = { emoji: a["emoji"], color: a["color"] } }
  agents
rescue StandardError
  {}
end

get "/dashboard" do
  content_type :html
  erb :dashboard, layout: false
end

get "/api/logs" do
  content_type "text/plain"
  log_file = params["file"]
  lines = (params["lines"] || 200).to_i

  halt 400, "Missing ?file= parameter" unless log_file && !log_file.empty?
  halt 400, "Invalid path" if log_file.include?("..") || !log_file.start_with?("/")
  halt 404, "File not found" unless File.exist?(log_file)

  # Only allow reading log files from known project tmp dirs or brainiac tmp
  allowed = PROJECTS.values.map { |p| File.join(p["repo_path"], "tmp") }
  allowed << File.join(BRAINIAC_DIR, "tmp")
  halt 403, "Forbidden" unless allowed.any? { |dir| log_file.start_with?(dir) }

  # Read last N lines and strip ANSI escape codes
  all_lines = File.readlines(log_file).last(lines)
  all_lines.join.gsub(/\e\[[\d;]*[a-zA-Z]/, "").gsub(/\e\[\?[\d;]*[a-zA-Z]/, "")
end

# --- Discord API + startup ---

if DISCORD_ENABLED
  get "/api/discord" do
    content_type :json
    {
      enabled: true,
      bots: discord_bots_status,
      config: {
        default_project: DISCORD_CONFIG["default_project"],
        channel_mappings: DISCORD_CONFIG["channel_mappings"]&.size || 0,
        authorized_users: (DISCORD_CONFIG["authorized_user_ids"] || []).size,
        authorized_roles: (DISCORD_CONFIG["authorized_role_ids"] || []).size
      }
    }.to_json
  end

  start_all_discord_gateways
  start_discord_draft_poller
  start_brainiac_restart_monitor

  # Send "back online" notification after bots connect (if restarted)
  Thread.new do
    # Wait for at least one bot to be ready (up to 30s)
    30.times do
      sleep 1
      ready = DISCORD_BOTS_MUTEX.synchronize { DISCORD_BOTS.any? { |_, info| info[:status] == "ready" } }
      next unless ready

      send_restart_notification("✅ Brainiac back online")

      # Check if running an outdated version (skip in dev/foreground mode)
      unless $stdout.tty?
        version_info = check_brainiac_version
        if version_info[:behind]
          owner_id = owner_discord_id
          mention = owner_id ? "<@#{owner_id}>" : "Someone"
          channel_id = DISCORD_CONFIG["notification_channel_id"]
          tokens = discord_bot_tokens
          token = tokens.values.first
          if channel_id && token
            send_discord_message(channel_id,
                                 "#{mention}: Brainiac was updated and needs to be pulled down (#{version_info[:commits_behind]} commit#{"s" if version_info[:commits_behind] != 1} behind, running #{version_info[:local_sha]} vs #{version_info[:remote_sha]})",
                                 token: token)
          end
        end
      end

      break
    end
  end
else
  get "/api/discord" do
    content_type :json
    { enabled: false, reason: "websocket-client-simple gem not installed" }.to_json
  end
end

# --- Cron API + startup ---

get "/api/cron/script" do
  content_type "text/plain"
  path = params["path"]
  halt 400, "Missing ?path= parameter" unless path && !path.empty?
  halt 400, "Invalid path" if path.include?("..")

  # Only allow reading scripts that are actually referenced by a cron job
  reload_cron_jobs!
  valid = CRON_JOBS.values.any? do |j|
    j[:script] == path || j["script"] == path ||
      (j[:prompt] || j["prompt"] || "").include?(path)
  end
  halt 403, "Not a registered cron script" unless valid
  halt 404, "File not found" unless File.exist?(path)

  File.read(path)
end

get "/api/cron" do
  content_type :json
  reload_cron_jobs!
  {
    enabled: true,
    jobs: CRON_JOBS,
    thread_alive: CRON_THREAD[:ref]&.alive? || false
  }.to_json
end

post "/api/cron/add" do
  content_type :json
  request.body.rewind
  payload = JSON.parse(request.body.read)

  result = add_cron_job(
    id: payload["id"],
    schedule: payload["schedule"],
    agent: payload["agent"],
    project: payload["project"],
    prompt: payload["prompt"],
    script: payload["script"],
    model: payload["model"],
    effort: payload["effort"],
    discord_channel_id: payload["discord_channel_id"],
    forum_title: payload["forum_title"],
    forum_reply_to_latest: payload["forum_reply_to_latest"] || false,
    repeat_count: payload["repeat_count"]
  )

  result.to_json
end

post "/api/cron/remove" do
  content_type :json
  request.body.rewind
  payload = JSON.parse(request.body.read)

  result = remove_cron_job(payload["id"])
  result.to_json
end

post "/api/cron/toggle" do
  content_type :json
  request.body.rewind
  payload = JSON.parse(request.body.read)

  result = toggle_cron_job(payload["id"], payload["enabled"])
  result.to_json
end

post "/api/cron/update" do
  content_type :json
  request.body.rewind
  payload = JSON.parse(request.body.read)

  result = update_cron_job(
    payload["id"],
    schedule: payload["schedule"],
    discord_channel_id: payload["discord_channel_id"],
    forum_title: payload["forum_title"],
    forum_reply_to_latest: payload["forum_reply_to_latest"]
  )
  result.to_json
end

post "/api/cron/reload" do
  content_type :json
  reload_cron_jobs!
  { status: "reloaded", jobs: CRON_JOBS.size }.to_json
end

get "/api/cron/logs" do
  content_type :json
  job_id = params["id"]
  halt 400, { error: "Missing ?id= parameter" }.to_json unless job_id && !job_id.empty?

  logs = []
  PROJECTS.each_value do |proj|
    tmp_dir = File.join(proj["repo_path"], "tmp")
    next unless Dir.exist?(tmp_dir)

    Dir.glob(File.join(tmp_dir, "{agent-cron,cron-script}-#{job_id}-*.log")).each do |f|
      logs << { file: f, size: File.size(f), modified: File.mtime(f).iso8601 }
    end
  end
  logs.sort_by! { |l| l[:modified] }.reverse!
  logs.first(20).to_json
end

get "/api/gif" do
  content_type :json
  query = params[:q].to_s.strip
  halt 400, { error: "Missing ?q= parameter" }.to_json if query.empty?

  api_key = DISCORD_CONFIG["giphy_api_key"]
  halt 503, { error: "No giphy_api_key configured in discord.json" }.to_json unless api_key

  begin
    uri = URI("https://api.giphy.com/v1/gifs/search")
    uri.query = URI.encode_www_form(api_key: api_key, q: query, limit: 5, rating: "pg-13")
    response = Net::HTTP.get_response(uri)

    if response.code.to_i == 200
      results = JSON.parse(response.body)["data"] || []
      gifs = results.map { |g| { url: g.dig("images", "original", "url") || g["url"], title: g["title"] } }
      { query: query, results: gifs }.to_json
    else
      LOG.warn "[GIF] Giphy API returned #{response.code}: #{response.body[0..200]}"
      halt 502, { error: "Giphy API error: #{response.code}" }.to_json
    end
  rescue StandardError => e
    LOG.error "[GIF] Search failed: #{e.message}"
    halt 500, { error: e.message }.to_json
  end
end

# --- Deployment environment tracking ---

get "/api/deployments" do
  content_type :json
  reload_deployments_config!
  reload_deployment_state!
  { deployments: deployment_status }.to_json
end

post "/api/deployments/:env" do
  content_type :json
  env_key = params["env"]
  request.body.rewind
  payload = JSON.parse(request.body.read)

  result = deploy_to_environment(env_key, worktree_path: payload["worktree"], deployed_by: payload["deployed_by"])
  if result[:error]
    halt 404, result.to_json
  else
    { status: "deployed", env: env_key, deployment: result }.to_json
  end
rescue JSON::ParserError
  halt 400, { error: "Invalid JSON" }.to_json
end

delete "/api/deployments/:env" do
  content_type :json
  env_key = params["env"]
  state = load_deployment_state
  if state.key?(env_key)
    state[env_key] = { "status" => "available", "cleared_at" => Time.now.iso8601, "last_card" => state[env_key]["card_number"] }
    save_deployment_state(state)
    DEPLOYMENT_STATE.replace(state)
    LOG.info "[Deploy] Manually cleared #{env_key}"
    { status: "cleared", env: env_key }.to_json
  else
    halt 404, { error: "Unknown environment: #{env_key}" }.to_json
  end
end

post "/api/deployments/:env/deploying" do
  content_type :json
  env_key = params["env"]
  config = DEPLOYMENTS_CONFIG["environments"] || {}
  halt 404, { error: "Unknown environment: #{env_key}" }.to_json unless config.key?(env_key)
  request.body.rewind
  payload = begin
    JSON.parse(request.body.read)
  rescue StandardError
    {}
  end
  mark_deploying(env_key, worktree_path: payload["worktree"] || "")
  LOG.info "[Deploy] #{env_key} marked deploying via API"
  { status: "deploying", env: env_key }.to_json
end

LOG.info "[Cron] Starting cron thread..."
start_cron_thread

# Skill curator: runs daily, archives stale skills, logs consolidation candidates.
CURATOR_THREAD = Thread.new do
  loop do
    sleep(86_400) # Run once per day
    LOG.info "[Curator] Running scheduled skill curation..."
    curate_skills
  rescue StandardError => e
    LOG.warn "[Curator] Error: #{e.message}"
  end
end

LOG.info "[CardIndex] Starting background backfill..."
CARD_INDEX.backfill

LOG.info "[Monitor] Starting daemon..."
daemon_path = File.join(__dir__, "monitor", "daemon.rb")
daemon_pid_file = "/tmp/brainiac-daemon.pid"

# Kill old daemon if it exists
if File.exist?(daemon_pid_file)
  old_pid = File.read(daemon_pid_file).strip.to_i
  begin
    Process.kill("TERM", old_pid)
    LOG.info "[Monitor] Killed old daemon (PID #{old_pid})"
  rescue Errno::ESRCH
    LOG.debug "[Monitor] Old daemon PID #{old_pid} not running"
  end
end

# Start new daemon
pid = spawn("ruby", daemon_path, chdir: __dir__, out: "/dev/null", err: "/dev/null")
File.write(daemon_pid_file, pid)
Process.detach(pid)
LOG.info "[Monitor] Daemon started (PID #{pid})"
