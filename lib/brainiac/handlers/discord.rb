# frozen_string_literal: true

# Discord bot handlers: per-agent gateway connections, message handling, API helpers.
#
# Each agent with a `discord_bot_token` in the agent registry gets its own
# Discord bot connection. Users @mention @Galen or @GLaDOS directly in Discord
# rather than a single shared bot.

require "English"
DISCORD_CONFIG_FILE = File.join(BRAINIAC_DIR, "discord.json")
DISCORD_API_BASE = "https://discord.com/api/v10"
DISCORD_GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"

# Draft/posted directories for resilient Discord response delivery.
# Response files land in draft/ with a .meta.json sidecar containing delivery info.
# After successful posting, both files move to posted/.
# A poller thread recovers orphaned drafts (e.g. after a server restart).
DISCORD_DRAFT_DIR  = File.join(BRAINIAC_DIR, "tmp", "discord", "draft")
DISCORD_POSTED_DIR = File.join(BRAINIAC_DIR, "tmp", "discord", "posted")
FileUtils.mkdir_p(DISCORD_DRAFT_DIR)
FileUtils.mkdir_p(DISCORD_POSTED_DIR)

# Per-bot state: { agent_key => { token:, user_id:, status:, thread: } }
DISCORD_BOTS = {}
DISCORD_BOTS_MUTEX = Mutex.new
DISCORD_ALL_READY_LOGGED = { done: false }

# Shared thread map: when multiple agents are mentioned in the same message,
# the first to deliver creates the thread and stores its ID here so the rest
# post into the same thread instead of creating duplicates.
# Key: original message_id, Value: thread channel ID
DISCORD_SHARED_THREADS = {}
DISCORD_SHARED_THREADS_MUTEX = Mutex.new

# Zillacore restart queue: when an agent works on brainiac itself, queue a restart
# instead of doing it immediately. A background thread checks every 30s and only
# restarts when no other agents are running, preventing mid-session kills.
# Using a hash instead of a constant to allow mutation inside synchronize blocks
BRAINIAC_RESTART_STATE = { queued: false, triggered_by: nil }
BRAINIAC_RESTART_MUTEX = Mutex.new

def queue_brainiac_restart(agent_name)
  BRAINIAC_RESTART_MUTEX.synchronize do
    unless BRAINIAC_RESTART_STATE[:queued]
      BRAINIAC_RESTART_STATE[:queued] = true
      BRAINIAC_RESTART_STATE[:triggered_by] = agent_name
      LOG.info "[Brainiac] #{agent_name} queued a restart — will execute when all agents finish"
    end
  end
end

# Send a Discord notification about brainiac restart/startup using any available bot token.
def send_restart_notification(message)
  channel_id = DISCORD_CONFIG["notification_channel_id"]
  return unless channel_id

  tokens = discord_bot_tokens
  # Prefer the triggering agent's token, fall back to first available
  triggered_by = BRAINIAC_RESTART_MUTEX.synchronize { BRAINIAC_RESTART_STATE[:triggered_by] }
  token = tokens[triggered_by&.downcase] || tokens.values.first
  return unless token

  send_discord_message(channel_id, message, token: token)
rescue StandardError => e
  LOG.warn "[Brainiac] Failed to send restart notification: #{e.message}"
end

def any_agents_running?
  ACTIVE_SESSIONS_MUTEX.synchronize do
    ACTIVE_SESSIONS.any? do |_key, info|
      Process.kill(0, info[:pid])
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end
end

def start_brainiac_restart_monitor
  Thread.new do
    LOG.info "[Brainiac] Restart monitor started, checking every 30s"
    loop do
      sleep 30
      restart_needed = BRAINIAC_RESTART_MUTEX.synchronize { BRAINIAC_RESTART_STATE[:queued] }

      if restart_needed && !any_agents_running?
        triggered_by = BRAINIAC_RESTART_MUTEX.synchronize { BRAINIAC_RESTART_STATE[:triggered_by] }
        LOG.info "[Brainiac] All agents finished, executing restart..."
        BRAINIAC_RESTART_MUTEX.synchronize { BRAINIAC_RESTART_STATE[:queued] = false }

        send_restart_notification("🔄 Restarting brainiac (triggered by #{triggered_by || "unknown"})...")

        # Schedule restart: stop now, start in 3 seconds
        # This ensures the current process fully exits before the new one starts
        Thread.new do
          sleep 1 # Give time for log to flush

          # Spawn a delayed restart command that will execute after we exit
          # Inherit current PATH so brainiac binary can be found regardless of install location
          # Process.detach ensures the spawned process survives when parent exits
          pid = spawn({ "PATH" => ENV.fetch("PATH", nil) }, "sh", "-c", "sleep 3 && brainiac server --daemon",
                      out: "/dev/null", err: "/dev/null")
          Process.detach(pid)

          sleep 1
          LOG.info "[Brainiac] Stopping server, new instance will start in 3 seconds..."
          Sinatra::Application.quit!
          sleep 0.5 # Give Sinatra a moment to shut down gracefully
          exit! # Force exit to kill all threads immediately
        end
      elsif restart_needed
        active_count = ACTIVE_SESSIONS_MUTEX.synchronize { ACTIVE_SESSIONS.size }
        LOG.info "[Brainiac] Restart queued but #{active_count} agent(s) still running, waiting..."
      end
    end
  end
end

def load_discord_config
  default = { "channel_mappings" => {}, "authorized_role_ids" => [], "authorized_user_ids" => [] }
  return default unless File.exist?(DISCORD_CONFIG_FILE)

  JSON.parse(File.read(DISCORD_CONFIG_FILE))
rescue JSON::ParserError => e
  LOG.error "Failed to parse discord config: #{e.message}"
  default
end

DISCORD_CONFIG = load_discord_config

def reload_discord_config!
  DISCORD_CONFIG.replace(load_discord_config)
end

# Collect all agent Discord bot tokens from the registry.
# Returns { "galen" => "token...", "glados" => "token..." }
def discord_bot_tokens
  tokens = {}
  AGENT_REGISTRY.each do |key, entry|
    next unless entry.is_a?(Hash)

    token = (entry["env"] || {})["DISCORD_BOT_TOKEN"]
    next unless token

    tokens[key] = token
  end
  tokens
end

# --- Discord REST API ---

def discord_api(method, path, token:, body: nil, log_errors: true)
  uri = URI("#{DISCORD_API_BASE}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = case method
        when :get    then Net::HTTP::Get.new(uri)
        when :post   then Net::HTTP::Post.new(uri)
        when :put    then Net::HTTP::Put.new(uri)
        when :delete then Net::HTTP::Delete.new(uri)
        end

  req["Authorization"] = "Bot #{token}"
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body

  response = http.request(req)

  if response.code.to_i == 429
    retry_after = JSON.parse(response.body)["retry_after"] || 1
    LOG.warn "Discord rate limited, waiting #{retry_after}s"
    sleep retry_after
    return discord_api(method, path, token: token, body: body, log_errors: log_errors)
  end

  LOG.error "Discord API error (#{method} #{path}): HTTP #{response.code} - #{response.body}" if response.code.to_i >= 400 && log_errors

  JSON.parse(response.body) unless response.body.nil? || response.body.empty?
rescue StandardError => e
  LOG.error "Discord API error (#{method} #{path}): #{e.message}" if log_errors
  nil
end

def fetch_discord_channel_history(channel_id, before_message_id, token:, limit: 10)
  messages = discord_api(:get, "/channels/#{channel_id}/messages?before=#{before_message_id}&limit=#{limit}", token: token)

  all_messages = messages.is_a?(Array) ? messages : []

  # If we're in a thread, check if the oldest message is a THREAD_STARTER_MESSAGE (type 21).
  # These messages have no content but point to the original message via referenced_message.
  # We need to include that original message for full context.
  if all_messages.any?
    oldest = all_messages.last # API returns newest-first
    if oldest && oldest["type"] == 21 && oldest["referenced_message"]
      # Prepend the actual starter message content
      all_messages << oldest["referenced_message"]
    end
  end

  return "" if all_messages.empty?

  # Messages come newest-first from the API, reverse for chronological order
  lines = all_messages.reverse.filter_map do |msg|
    author = msg.dig("author", "username") || "unknown"
    content = msg["content"]&.strip || ""
    next if content.empty?

    "#{author}: #{content}"
  end

  return "" if lines.empty?

  lines.join("\n")
rescue StandardError => e
  LOG.warn "Failed to fetch channel history: #{e.message}"
  ""
end

def fetch_channel_info(channel_id, token:)
  discord_api(:get, "/channels/#{channel_id}", token: token)
end

def forum_channel?(channel_id, token:)
  info = fetch_channel_info(channel_id, token: token)
  info && info["type"] == 15
end

def find_latest_forum_thread(channel_id, token:)
  # Get the guild ID from the channel info, then list active threads
  channel_info = fetch_channel_info(channel_id, token: token)
  return nil unless channel_info && channel_info["guild_id"]

  guild_id = channel_info["guild_id"]
  result = discord_api(:get, "/guilds/#{guild_id}/threads/active", token: token)
  return nil unless result && result["threads"]

  # Filter to threads in this forum channel, sort by creation (newest first)
  forum_threads = result["threads"]
                  .select { |t| t["parent_id"] == channel_id }
                  .sort_by { |t| t["id"].to_i }
                  .reverse

  return nil if forum_threads.empty?

  latest = forum_threads.first
  LOG.info "[Discord] Found latest forum thread: #{latest["id"]} (#{latest["name"]}) in channel #{channel_id}"
  latest
end

def create_forum_post(channel_id, title:, content:, token:)
  thread_name = title.length > 100 ? "#{title[0..96]}..." : title
  result = discord_api(:post, "/channels/#{channel_id}/threads", token: token, body: {
                         name: thread_name,
                         message: { content: content },
                         auto_archive_duration: 1440
                       })
  if result && result["id"]
    LOG.info "[Discord] Forum post created in channel #{channel_id}, thread_id: #{result["id"]}"
  else
    LOG.error "[Discord] Failed to create forum post in channel #{channel_id}, result: #{result.inspect}"
  end
  result
end

def send_discord_message(channel_id, content, token:, reply_to: nil)
  body = { content: content }
  body[:message_reference] = { message_id: reply_to } if reply_to
  result = discord_api(:post, "/channels/#{channel_id}/messages", token: token, body: body)
  if result && result["id"]
    LOG.info "[Discord] Message posted successfully to channel #{channel_id}, message_id: #{result["id"]}"
  else
    LOG.error "[Discord] Failed to post message to channel #{channel_id}, result: #{result.inspect}"
  end
  result
end

def send_discord_typing(channel_id, token:)
  discord_api(:post, "/channels/#{channel_id}/typing", token: token)
end

def fetch_discord_message(channel_id, message_id, token:, log_errors: true)
  discord_api(:get, "/channels/#{channel_id}/messages/#{message_id}", token: token, log_errors: log_errors)
end

# Emojis reserved for brainiac functionality — not treated as feedback
RESERVED_EMOJIS = %w[👀 ❌ 🛑 🚫 ⚠️ ⏳ 😶 ❔ ❓ 🧠].freeze

def add_discord_reaction(channel_id, message_id, emoji, token:)
  encoded = URI.encode_www_form_component(emoji)
  discord_api(:put, "/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded}/@me", token: token)
end

def remove_discord_reaction(channel_id, message_id, emoji, token:)
  encoded = URI.encode_www_form_component(emoji)
  discord_api(:delete, "/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded}/@me", token: token)
end

def create_discord_thread(channel_id, message_id, name:, token:)
  thread_name = name.length > 100 ? "#{name[0..96]}..." : name
  discord_api(:post, "/channels/#{channel_id}/messages/#{message_id}/threads", token: token, body: {
                name: thread_name,
                auto_archive_duration: 1440
              })
end

def fetch_guild_member(guild_id, user_id, token:)
  discord_api(:get, "/guilds/#{guild_id}/members/#{user_id}", token: token)
end

def send_long_discord_message(channel_id, content, token:, reply_to: nil)
  if content.length <= 2000
    send_discord_message(channel_id, content, token: token, reply_to: reply_to)
    return
  end

  chunks = []
  remaining = content
  while remaining.length.positive?
    if remaining.length <= 2000
      chunks << remaining
      remaining = ""
    else
      split_at = remaining.rindex("\n", 1990) || 1990
      chunks << remaining[0...split_at]
      remaining = remaining[split_at..].lstrip
    end
  end

  chunks.each_with_index do |chunk, i|
    send_discord_message(channel_id, chunk, token: token, reply_to: i.zero? ? reply_to : nil)
    sleep 0.5
  end
end

def find_project_for_discord_channel(channel_id)
  mapping = DISCORD_CONFIG.dig("channel_mappings", channel_id)

  unless mapping
    default_project = DISCORD_CONFIG["default_project"]
    mapping = { "project" => default_project } if default_project
  end

  return nil unless mapping

  project_key = mapping["project"]
  project_config = PROJECTS[project_key]
  return nil unless project_config

  [project_key, project_config, mapping]
end

# Find the root message for a conversation thread.
# Walks back through message_reference chain to find the original message.
# Returns { id: root_message_id, content: root_message_text, author: username }
# or { id: current_message_id, content: nil, author: nil } if already the root.
def find_root_message(message, channel_id, bot_token)
  current_msg = message
  visited = Set.new
  max_depth = 20 # Prevent infinite loops
  walked = false

  max_depth.times do
    msg_id = current_msg["id"]
    return { id: msg_id, content: nil, author: nil } if visited.include?(msg_id) # Loop detected

    visited << msg_id

    ref = current_msg["message_reference"]
    break unless ref

    ref_msg_id = ref["message_id"]
    ref_channel = ref["channel_id"] || channel_id
    break unless ref_msg_id

    # Fetch the referenced message
    referenced = discord_api(:get, "/channels/#{ref_channel}/messages/#{ref_msg_id}", token: bot_token)
    break unless referenced

    current_msg = referenced
    walked = true
  end

  {
    id: current_msg["id"],
    content: walked ? current_msg["content"]&.strip : nil,
    author: walked ? current_msg.dig("author", "username") : nil
  }
end

# Build a Discord mention roster so the agent can @mention people and other bots.
# Discord requires `<@USER_ID>` syntax — plain text "@Name" doesn't work.
# Sources:
#   - Other agent bots: DISCORD_BOTS (populated at gateway READY)
#   - Human users: discord.json "user_mappings" (manually maintained)
def discord_mention_roster
  lines = []

  # Agent bots
  DISCORD_BOTS_MUTEX.synchronize do
    DISCORD_BOTS.each do |agent_key, info|
      next unless info[:user_id]

      display = fizzy_display_name(agent_key) || agent_key.capitalize
      lines << "  - #{display}: `<@#{info[:user_id]}>`"
    end
  end

  # Human users from config
  user_mappings = DISCORD_CONFIG["user_mappings"] || {}
  user_mappings.each do |name, discord_id|
    lines << "  - #{name}: `<@#{discord_id}>`"
  end

  lines.join("\n")
end

# Handle an incoming Discord message for a specific agent bot.
# agent_key: the lowercase agent key (e.g. "galen")
# bot_token: the Discord bot token for this agent
# bot_user_id: the Discord user ID of this bot
def handle_discord_message(message, agent_key, bot_token, bot_user_id)
  channel_id = message["channel_id"]
  message_id = message["id"]
  author = message["author"]
  content = message["content"] || ""

  is_bot = !author["bot"].nil?

  # Identify if the author is a known agent bot (local or remote).
  # Local agents are in DISCORD_BOTS; remote agents (running on other machines)
  # are recognized via discord.json "user_mappings".
  sender_agent_key = nil
  if is_bot
    sender_id = author["id"]

    # Check local bots first
    DISCORD_BOTS_MUTEX.synchronize do
      DISCORD_BOTS.each do |key, info|
        if info[:user_id] == sender_id && key != agent_key
          sender_agent_key = key
          break
        end
      end
    end

    # Check user_mappings for remote agents
    unless sender_agent_key
      user_mappings = DISCORD_CONFIG["user_mappings"] || {}
      user_mappings.each do |name, discord_id|
        if discord_id == sender_id
          sender_agent_key = name.downcase
          break
        end
      end
    end

    # Unknown bot or self — ignore entirely
    unless sender_agent_key
      LOG.info "[Discord:#{agent_key}] Ignoring unknown bot: id=#{sender_id}, username=#{author["username"]}, bot=#{author["bot"]}"
      return
    end
  end

  mentions = message["mentions"] || []
  mentioned = mentions.any? { |m| m["id"].to_s == bot_user_id.to_s }

  # Discord doesn't always populate the mentions array for bot-to-bot mentions.
  # Check the raw content for mention patterns as a fallback.
  mentioned ||= content.match?(/<@!?#{Regexp.escape(bot_user_id.to_s)}>/)

  # Check for @everyone mention (DISABLED — agents need to cool it)
  # unless mentioned
  #   mentioned = message['mention_everyone'] == true
  # end

  # Cross-agent bot mention: only proceed if this bot is explicitly @mentioned
  # and the dispatch depth hasn't been exceeded (prevents infinite loops).
  if sender_agent_key
    unless mentioned
      fizzy_display_name(sender_agent_key) || sender_agent_key.capitalize
      agent_display = fizzy_display_name(agent_key) || agent_key.capitalize
      # LOG.info "[Discord:#{agent_display}] Ignoring cross-agent message from #{sender_display} — not mentioned (content: #{content[0..100]})"
      return
    end

    # Skip dispatch when the message is a Fizzy card creation/assignment
    # announcement. The Fizzy webhook handles card assignments — dispatching
    # here too causes the mentioned agent to respond in Discord instead of
    # (or in addition to) the new card.
    if content.match?(/created\s+card\s+#?\d+/i) || content.match?(/assigned\s+.*card\s+#?\d+/i) || content.match?(/card\s+#?\d+.*assigned/i)
      sender_display = fizzy_display_name(sender_agent_key) || sender_agent_key.capitalize
      agent_display = fizzy_display_name(agent_key) || agent_key.capitalize
      LOG.info "[Discord:#{agent_display}] Ignoring cross-agent mention from #{sender_display} — Fizzy card creation/assignment (handled by webhook)"
      return
    end

    depth_key = "discord-#{channel_id}"
    unless agent_dispatch_allowed?(depth_key)
      sender_display = fizzy_display_name(sender_agent_key) || sender_agent_key.capitalize
      agent_display = fizzy_display_name(agent_key) || agent_key.capitalize
      LOG.info "[Discord:#{agent_display}] Blocking cross-agent dispatch from #{sender_display} — depth limit reached"
      return
    end
    record_agent_dispatch(depth_key)
  end

  # Detect if the message is a reply to one of this bot's own messages.
  # Discord replies include a `message_reference` but don't automatically add
  # the referenced author to the `mentions` array, so we check explicitly.
  # We also cache the referenced message for later use as reply context.
  is_reply_to_bot = false
  referenced_message = nil
  if message["message_reference"]
    ref_msg_id = message.dig("message_reference", "message_id")
    ref_channel = message.dig("message_reference", "channel_id") || channel_id
    if ref_msg_id
      referenced_message = discord_api(:get, "/channels/#{ref_channel}/messages/#{ref_msg_id}", token: bot_token)
      is_reply_to_bot = !mentioned && referenced_message && referenced_message.dig("author", "id") == bot_user_id
    end
  end

  # Detect if inside a thread (follow-up conversation) or a DM.
  # Only call the API if the message doesn't already have an explicit @mention,
  # to avoid unnecessary API calls on every message.
  channel_info = nil
  is_thread = false
  is_dm = false
  in_own_thread = false

  if !mentioned && !is_reply_to_bot
    channel_info = discord_api(:get, "/channels/#{channel_id}", token: bot_token)
    is_thread = channel_info && [11, 12].include?(channel_info["type"])
    is_dm = channel_info && channel_info["type"] == 1
    in_own_thread = is_thread && channel_info["owner_id"] == bot_user_id
  end

  # If we'd respond only because we own the thread (not explicitly mentioned,
  # not a reply to us), check whether the human is explicitly talking to a
  # DIFFERENT agent. If so, stand down — they're directing the conversation
  # elsewhere and we shouldn't butt in.
  if in_own_thread && !mentioned && !is_reply_to_bot && !is_bot
    other_bot_mentioned = false
    DISCORD_BOTS_MUTEX.synchronize do
      DISCORD_BOTS.each do |key, info|
        next if key == agent_key # skip self
        next unless info[:user_id]

        next unless mentions.any? { |m| m["id"].to_s == info[:user_id].to_s } ||
                    content.match?(/<@!?#{Regexp.escape(info[:user_id].to_s)}>/)

        other_bot_mentioned = true
        break
      end
    end

    # Also check user_mappings for remote agent bots
    unless other_bot_mentioned
      user_mappings = DISCORD_CONFIG["user_mappings"] || {}
      user_mappings.each_value do |discord_id|
        next unless mentions.any? { |m| m["id"].to_s == discord_id.to_s } ||
                    content.match?(/<@!?#{Regexp.escape(discord_id.to_s)}>/)

        other_bot_mentioned = true
        break
      end
    end

    if other_bot_mentioned
      agent_display = fizzy_display_name(agent_key) || agent_key.capitalize
      LOG.info "[Discord:#{agent_display}] Standing down in own thread — human is directing message to another agent"
      return
    end
  end

  # In DMs, threads the bot created, and replies to the bot's own messages,
  # respond without requiring an explicit @mention.
  # In guild channels, require an explicit @mention.
  return unless mentioned || in_own_thread || is_dm || is_reply_to_bot

  # Human message resets the cross-agent dispatch depth for this channel/thread
  record_human_comment("discord-#{channel_id}") unless is_bot

  clean_content = content.gsub(/<@!?#{bot_user_id}>/, "").strip

  # Handle attachments (images, gifs, etc.)
  attachments = message["attachments"] || []
  attachment_paths = []
  agent_display = fizzy_display_name(agent_key) || agent_key.capitalize
  attachments.each do |att|
    url = att["url"]
    filename = att["filename"]
    content_type = att["content_type"] || ""

    # Only process image attachments
    next unless content_type.start_with?("image/")

    # Download to temp directory
    temp_dir = File.join(BRAINIAC_DIR, "tmp", "discord", "attachments")
    FileUtils.mkdir_p(temp_dir)
    temp_path = File.join(temp_dir, "#{message_id}-#{filename}")

    begin
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      response = http.get(uri.path + (uri.query ? "?#{uri.query}" : ""))

      if response.code.to_i == 200
        File.binwrite(temp_path, response.body)
        attachment_paths << temp_path
        LOG.info "[Discord:#{agent_display}] Downloaded attachment: #{filename} (#{content_type})"
      else
        LOG.warn "[Discord:#{agent_display}] Failed to download attachment #{filename}: HTTP #{response.code}"
      end
    rescue StandardError => e
      LOG.error "[Discord:#{agent_display}] Error downloading attachment #{filename}: #{e.message}"
    end
  end

  # Append attachment paths to the message content so kiro-cli can process them
  unless attachment_paths.empty?
    clean_content += "\n\n" unless clean_content.empty?
    clean_content += attachment_paths.join("\n")
  end

  return if clean_content.empty? && attachment_paths.empty?

  # Build reply context from the cached referenced message.
  reply_context = ""
  if referenced_message && referenced_message["content"]
    ref_author = referenced_message.dig("author", "username") || "unknown"
    ref_text = referenced_message["content"].strip
    reply_context = "**Replying to #{ref_author}:**\n> #{ref_text}\n\n" unless ref_text.empty?
  end

  # Fetch recent channel history so the agent has conversational context.
  # (Moved after is_thread detection below — needs thread status for limit)

  discord_user = author["username"]
  discord_user_id = author["id"]

  # The agent name comes directly from the bot identity — no detection needed
  agent_name = fizzy_display_name(agent_key) || agent_key.capitalize

  # Fetch channel_info if we haven't already (mentioned path skipped it)
  unless channel_info
    channel_info = discord_api(:get, "/channels/#{channel_id}", token: bot_token)
    is_thread = channel_info && [11, 12].include?(channel_info["type"])
    is_dm = channel_info && channel_info["type"] == 1
  end
  parent_channel_id = is_thread ? channel_info&.dig("parent_id") || channel_id : channel_id

  # Fetch recent channel history — threads get a larger window since they're bounded conversations.
  history_limit = is_thread ? 25 : 10
  channel_history = fetch_discord_channel_history(channel_id, message_id, token: bot_token, limit: history_limit)

  LOG.info "[Discord:#{agent_name}] Message from #{discord_user} in #{if is_dm
                                                                        "DM"
                                                                      else
                                                                        is_thread ? "thread" : "channel"
                                                                      end} #{channel_id}: #{clean_content[0..100]}"

  reload_projects!
  reload_agent_registry!
  reload_discord_config!

  # Authorization
  authorized_users = DISCORD_CONFIG["authorized_user_ids"] || []

  # Support both role_mappings (hash) and authorized_role_ids (array or hash)
  # If authorized_role_ids is a hash, treat it like role_mappings
  authorized_roles = if DISCORD_CONFIG["role_mappings"]
                       DISCORD_CONFIG["role_mappings"].values
                     elsif DISCORD_CONFIG["authorized_role_ids"].is_a?(Hash)
                       DISCORD_CONFIG["authorized_role_ids"].values
                     else
                       DISCORD_CONFIG["authorized_role_ids"] || []
                     end

  # Ensure all role IDs are strings (Discord API returns strings)
  authorized_roles = authorized_roles.map(&:to_s)

  unless authorized_users.empty? && authorized_roles.empty?
    user_authorized = authorized_users.include?(discord_user_id)

    # Fetch member roles — message.member is not always populated, so we need to
    # fetch guild member info separately if we have a guild_id
    member_roles = message.dig("member", "roles") || []

    # If member roles aren't in the message and we have a guild_id, fetch them
    if member_roles.empty? && message["guild_id"]
      guild_member = fetch_guild_member(message["guild_id"], discord_user_id, token: bot_token)
      member_roles = guild_member["roles"] || [] if guild_member
    end

    role_authorized = member_roles.intersect?(authorized_roles)

    unless user_authorized || role_authorized
      LOG.info "[Discord:#{agent_name}] Unauthorized user #{discord_user} (#{discord_user_id}), roles: #{member_roles.inspect}"
      add_discord_reaction(channel_id, message_id, "🚫", token: bot_token)
      return
    end
  end

  # Inline tags: [project:my-project] and [model] anywhere in the message.
  # Both are parsed for routing/config and stripped from the prompt content.
  inline_project_key = nil
  if (proj_match = clean_content.match(/\[project:(\S+)\]/i))
    inline_project_key = proj_match[1]
    clean_content = clean_content.sub(proj_match[0], "").strip
    LOG.info "[Discord:#{agent_name}] Detected inline project tag: #{inline_project_key}"
  end

  # Strip model tag (e.g. [opus], [sonnet]) from prompt content — detect_model
  # reads the original clean_content later, but we save the tag-free version
  # for the actual prompt so the bracket noise doesn't leak through.
  inline_model_tag = clean_content.match(/\[\w+\]/)
  clean_content_for_prompt = inline_model_tag ? clean_content.sub(inline_model_tag[0], "").strip : clean_content

  # Strip effort tag (e.g. [effort:high]) from prompt content
  clean_content_for_prompt = clean_content_for_prompt.sub(/\[effort:\w+\]/i, "").strip

  # Find project: inline override > channel mapping > default_project
  if inline_project_key && PROJECTS.key?(inline_project_key)
    project_key = inline_project_key
    project_config = PROJECTS[inline_project_key]
    LOG.info "[Discord:#{agent_name}] Using inline project: #{project_key} (#{project_config["repo_path"]})"
  else
    if inline_project_key && !PROJECTS.key?(inline_project_key)
      LOG.warn "[Discord:#{agent_name}] Unknown inline project '#{inline_project_key}', falling back to channel mapping. Available: #{PROJECTS.keys.join(", ")}"
      Thread.new { add_discord_reaction(channel_id, message_id, "⚠️", token: bot_token) }
    end
    project_key, project_config, _mapping = find_project_for_discord_channel(parent_channel_id)
    if project_key
      LOG.info "[Discord:#{agent_name}] Using channel-mapped project: #{project_key}"
    else
      LOG.info "[Discord:#{agent_name}] No project context (no inline tag or channel mapping)"
    end
  end

  session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"
  supersede_key = "discord-#{agent_key}-#{channel_id}"

  if session_active?(session_key)
    add_discord_reaction(channel_id, message_id, "⏳", token: bot_token)
    return
  end

  # Supersede: if a human sends a follow-up within 60s, kill the previous agent run
  if !is_bot && (prev = find_supersedable_session(supersede_key))
    LOG.info "[Discord:#{agent_name}] Superseding previous session #{prev[:session_key]} (pid: #{prev[:pid]}) for follow-up from #{discord_user}"
    kill_session(prev[:session_key])
    # React on the OLD message to show it was cancelled
    if prev[:message_id] && prev[:channel_id]
      Thread.new do
        remove_discord_reaction(prev[:channel_id], prev[:message_id], "👀", token: bot_token)
        add_discord_reaction(prev[:channel_id], prev[:message_id], "❌", token: bot_token)
      end
    end
    # Clean up draft files from the superseded session so the poller doesn't deliver stale responses
    (prev[:draft_files] || []).each { |f| FileUtils.rm_f(f) }
  end

  # React in background — don't block the dispatch path
  # Remove 🛑 if it exists (user may have cancelled and is now retrying via edit)
  Thread.new do
    remove_discord_reaction(channel_id, message_id, "🛑", token: bot_token)
    add_discord_reaction(channel_id, message_id, "👀", token: bot_token)
  end

  # Build project context
  if project_config
    repo_path = project_config["repo_path"]
    # Fetch latest from origin so worktrees branch from up-to-date main
    debounced_repo_fetch(repo_path)
    default_branch = get_default_branch(repo_path)
    lines = ["## Project Context"]
    lines << "Project: #{project_key}"
    lines << "Source directory: `#{repo_path}`"
    lines << "Default branch: `#{default_branch}`"
    lines << "GitHub: #{project_config["github_repo"]}" if project_config["github_repo"]
    lines << ""
    lines << "This is the project's source code directory. When asked to modify, inspect, or work on this project, go directly to `#{repo_path}` — do NOT search for it."
    lines << ""
    lines << "### All registered projects"
    PROJECTS.each do |key, cfg|
      lines << "- **#{key}**: `#{cfg["repo_path"]}`"
    end
    context = lines.join("\n")
    LOG.info "[Discord:#{agent_name}] Built project context for #{project_key} (#{repo_path})"
  else
    lines = ["## Project Context"]
    lines << "No specific project mapped to this channel."
    lines << ""
    lines << "### Registered projects (use `[project:name]` to target one)"
    PROJECTS.each do |key, cfg|
      lines << "- **#{key}**: `#{cfg["repo_path"]}`"
    end
    context = lines.join("\n")
    LOG.info "[Discord:#{agent_name}] No project context - showing available projects"
  end
  project_context = context

  # Prepare files — response goes to draft/ so the poller can recover it after restarts
  response_dir = File.join(BRAINIAC_DIR, "tmp")
  FileUtils.mkdir_p(response_dir)
  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
  response_basename = "discord-response-#{timestamp}-#{agent_key}-#{message_id}"
  response_file = File.join(DISCORD_DRAFT_DIR, "#{response_basename}.md")

  channel_name = channel_info&.dig("name") || channel_id

  # Find the root message for this conversation thread.
  # All messages in a thread should share the same memory file.
  # Also captures root message content so the agent always has the original context.
  root_message = find_root_message(message, channel_id, bot_token)
  root_message_id = root_message[:id]
  card_id = "discord-#{channel_id}-#{root_message_id}"

  # Build thread root context — inject the original question/message that started
  # this thread so the agent never loses sight of it, even in long conversations.
  thread_root_context = ""
  if is_thread && root_message[:content] && !root_message[:content].empty?
    root_author = root_message[:author] || "unknown"
    thread_root_context = "### Original Message (thread starter)\n#{root_author}: #{root_message[:content]}\n\n"
  end

  # Detect planning mode
  planning_info = detect_planning_mode(
    text: clean_content,
    tags: [],
    card_internal_id: card_id,
    card_number: nil
  )

  brain_context = build_brain_context(agent_name: agent_name, card_title: clean_content, comment_body: clean_content)

  if planning_info
    # Planning mode — use planning prompt
    planning_card_id = planning_info[:card_id]
    LOG.info "[Discord:#{agent_name}] Planning mode detected for #{discord_user}"

    prompt = render_planning_prompt(PROMPT_DISCORD,
                                    { "DISCORD_USER" => discord_user,
                                      "CHANNEL_NAME" => channel_name,
                                      "MESSAGE_BODY" => clean_content_for_prompt.sub(/\[plan\]/i, "").strip,
                                      "REPLY_CONTEXT" => reply_context,
                                      "CHANNEL_HISTORY" => channel_history,
                                      "THREAD_ROOT_CONTEXT" => thread_root_context,
                                      "PROJECT_CONTEXT" => project_context,
                                      "RESPONSE_FILE" => response_file,
                                      "CARD_ID" => planning_card_id,
                                      "COMMENT_CREATOR" => discord_user,
                                      "DISCORD_MENTION_ROSTER" => discord_mention_roster },
                                    brain_context: brain_context,
                                    agent_name: agent_name,
                                    channel: :discord)
  else
    # Normal mode
    prompt = render_prompt(PROMPT_DISCORD,
                           { "DISCORD_USER" => discord_user,
                             "CHANNEL_NAME" => channel_name,
                             "MESSAGE_BODY" => clean_content_for_prompt,
                             "REPLY_CONTEXT" => reply_context,
                             "CHANNEL_HISTORY" => channel_history,
                             "THREAD_ROOT_CONTEXT" => thread_root_context,
                             "PROJECT_CONTEXT" => project_context,
                             "RESPONSE_FILE" => response_file,
                             "CARD_ID" => card_id,
                             "COMMENT_CREATOR" => discord_user,
                             "DISCORD_MENTION_ROSTER" => discord_mention_roster },
                           brain_context: brain_context,
                           agent_name: agent_name,
                           channel: :discord)
  end

  work_dir = project_config ? project_config["repo_path"] : Dir.pwd

  prompt_file = File.join(response_dir, "discord-prompt-#{timestamp}-#{agent_key}-#{message_id}.md")
  File.write(prompt_file, prompt)

  # Write delivery metadata sidecar so the poller can post this response
  # even if the monitoring thread dies (e.g. server restart).
  meta_file = File.join(DISCORD_DRAFT_DIR, "#{response_basename}.meta.json")
  File.write(meta_file, JSON.pretty_generate({
                                               channel_id: channel_id,
                                               message_id: message_id,
                                               agent_key: agent_key,
                                               agent_name: agent_name,
                                               is_dm: is_dm,
                                               is_thread: is_thread,
                                               clean_content: clean_content[0..80],
                                               created_at: Time.now.iso8601
                                             }))

  # Detect model override — same [opus]/[sonnet]/[haiku] syntax as Fizzy comments
  model = project_config ? detect_model(project_config, text: clean_content) : nil

  # Detect effort override — [effort:high] syntax
  effort = project_config ? detect_effort(project_config, text: clean_content) : nil

  agent_config_name = agent_key.downcase.gsub(/[^a-z0-9-]/, "-")
  log_file = File.join(response_dir, "discord-agent-#{timestamp}-#{agent_key}-#{message_id}.log")

  resolved = project_config ? resolve_project_cli_config(project_config) : {}
  agent_cli = resolved["agent_cli"] || "kiro-cli"
  agent_cli_args = resolved["agent_cli_args"] || "chat --trust-all-tools --no-interactive"
  agent_model_flag = resolved["agent_model_flag"] || "--model"
  agent_effort_flag = resolved["agent_effort_flag"] || "--effort"

  cmd = [agent_cli]
  cmd.push("--agent", agent_config_name)
  cmd.concat(agent_cli_args.split)
  add_trust_tools!(cmd, agent_cli_args)
  cmd.push(agent_model_flag, model) if agent_model_flag && !agent_model_flag.empty? && model
  cmd.push(agent_effort_flag, effort) if agent_effort_flag && !agent_effort_flag.empty? && effort

  LOG.info "[Discord:#{agent_name}] Dispatching for #{discord_user} (model: #{model || "default"}, effort: #{effort || "default"}), tail -f #{log_file}"
  LOG.info "[Discord:#{agent_name}] Command: #{cmd.join(" ")}"

  spawn_env = {}
  agent_env = agent_env_for(agent_name)
  unless agent_env.empty?
    spawn_env.merge!(agent_env)
    LOG.info "[Discord:#{agent_name}] Injecting #{agent_env.size} env var(s): #{agent_env.keys.join(", ")}"
  end

  # Capture HEAD before spawning so we can detect if THIS session made commits
  head_before = nil
  if project_config
    pk = PROJECTS.find { |_k, v| v == project_config }&.first
    if pk == "brainiac"
      head_before, = Open3.capture2("git", "rev-parse", "HEAD", chdir: work_dir)
      head_before = head_before.strip
    end
  end

  pid = spawn(spawn_env, *cmd,
              chdir: work_dir,
              in: prompt_file,
              out: [log_file, "w"],
              err: %i[child out])

  register_session(session_key, pid, log_file: log_file,
                                     message_id: message_id, channel_id: channel_id,
                                     supersede_key: supersede_key,
                                     draft_files: [response_file, meta_file],
                                     agent_name: agent_name)

  Thread.new do
    Process.wait(pid)
    exit_status = $CHILD_STATUS

    # Check if session was cancelled (removed from ACTIVE_SESSIONS by reaction handler)
    session_cancelled = ACTIVE_SESSIONS_MUTEX.synchronize { !ACTIVE_SESSIONS.key?(session_key) }

    # If the process was killed by a signal (superseded or cancelled), skip response delivery
    if exit_status.signaled? || session_cancelled
      reason = session_cancelled ? "cancelled" : "superseded (signal: #{exit_status.termsig})"
      LOG.info "[Discord:#{agent_name}] Agent was #{reason} for message #{message_id}"
      # Clean up draft/meta files so the poller doesn't deliver a stale response
      [response_file, meta_file].each { |f| FileUtils.rm_f(f) }
      Thread.new do
        sleep 300
        [prompt_file, *attachment_paths].each { |f| FileUtils.rm_f(f) }
      end
      next
    end

    LOG.info "[Discord:#{agent_name}] Agent finished for message #{message_id} (exit: #{exit_status.exitstatus})"

    # Notify if the agent crashed (non-zero exit)
    if exit_status.exitstatus && exit_status.exitstatus != 0
      notify_agent_crash(
        exit_status: exit_status.exitstatus, log_file: log_file,
        agent_name: agent_name, source: :discord,
        source_context: { channel_id: channel_id, message_id: message_id, bot_token: bot_token },
        project_config: project_config
      )
    end

    # If the agent didn't write to the response file, extract it from the log.
    # Agents should write to the file directly, but this is a fallback for when
    # they respond via stdout instead.
    if !File.exist?(response_file) && File.exist?(log_file)
      log_content = File.read(log_file)

      # Detect known fatal error patterns from kiro-cli and write a clean
      # user-facing message instead of leaking raw internal errors to Discord.
      if exit_status.exitstatus != 0 && log_content.match?(/InternalServerError|Encountered an unexpected error|Failed to receive the next message/i)
        LOG.warn "[Discord:#{agent_name}] Agent hit an upstream error for message #{message_id}"
        File.write(response_file, "_Sorry, I hit a temporary error on the backend. Please try again._")
      elsif log_content.match?(/Opening browser\.\.\.|Press \(\^\) \+ C to cancel/)
        LOG.error "[Discord:#{agent_name}] Auth failure detected — re-authenticate with: kiro-cli --agent #{agent_config_name} chat"
        FileUtils.rm_f(meta_file)
      else
        # Strip ANSI codes and kiro-cli UI noise
        clean_output = log_content
                       .gsub(/\e\[[0-9;]*[a-zA-Z]|\e\[\?[0-9;]*[a-zA-Z]/, "") # ANSI escape codes (including cursor visibility)
                       .gsub(/\e\][^\a]*\a/, "") # OSC sequences
                       .delete("\r") # Carriage returns
                       .gsub(/^.*?(using tool:.*?)$/m, "") # Tool usage lines
                       .gsub(/^.*?✓.*?$/m, "")            # Success checkmarks
                       .gsub(/^.*?▸.*?$/m, "")            # Timing lines
                       .gsub(/^.*?Loading\.\.\..*?$/m, "") # Loading indicators
                       .gsub(/^.*?Completed in.*?$/m, "") # Completion messages
                       .strip

        # Only write if there's actual content
        if !clean_output.empty? && clean_output.length > 20
          File.write(response_file, clean_output)
          LOG.info "[Discord:#{agent_name}] Extracted response from log (#{clean_output.length} chars)"
        end
      end
    end

    # Deliver Discord response FIRST for faster human feedback
    remove_discord_reaction(channel_id, message_id, "👀", token: bot_token)
    sleep 0.5 # Breathing room to avoid Discord rate limits

    delivered = deliver_discord_draft(response_file, meta_file)

    # If deliver returned false, check whether the poller already handled it
    # (files moved to posted/) or the response genuinely doesn't exist.
    unless delivered
      response_basename = File.basename(response_file)
      already_posted = File.exist?(File.join(DISCORD_POSTED_DIR, response_basename))
      unless already_posted
        LOG.warn "[Discord:#{agent_name}] No response produced for message #{message_id}"
        add_discord_reaction(channel_id, message_id, "😶", token: bot_token)
      end
    end

    # Re-index brain AFTER response delivery (Discord bypasses run_agent, so we handle it here)
    qmd_out, qmd_status = Open3.capture2e("qmd", "update")
    if qmd_status.success?
      LOG.info "[Brain] qmd update completed after #{agent_name} Discord session"
    else
      LOG.warn "[Brain] qmd update failed: #{qmd_out.strip}"
    end

    brain_push(message: "#{agent_name}: discord-#{message_id}")

    # Restart brainiac if THIS session actually changed code
    # Compare HEAD now vs before the agent ran — only restart if commits were made or files are dirty
    if project_config && head_before
      project_key = PROJECTS.find { |_k, v| v == project_config }&.first
      if project_key == "brainiac"
        chdir = project_config["repo_path"]
        head_after, = Open3.capture2("git", "rev-parse", "HEAD", chdir: chdir)
        git_status, = Open3.capture2("git", "status", "--porcelain", chdir: chdir)
        if head_after.strip != head_before || !git_status.strip.empty?
          queue_brainiac_restart(agent_name)
        else
          LOG.info "[Brainiac] #{agent_name} Discord session on brainiac had no changes — skipping restart"
        end
      end
    end

    Thread.new do
      sleep 300
      [prompt_file, *attachment_paths].each { |f| FileUtils.rm_f(f) }
    end
  rescue StandardError => e
    LOG.error "[Discord:#{agent_name}] Error monitoring agent: #{e.message}"
    add_discord_reaction(channel_id, message_id, "❌", token: bot_token)
  end
end

# --- Discord Reaction Handler ---
# Handles MESSAGE_REACTION_ADD events. Currently supports:
# - ❌ reaction to cancel an active agent session
def handle_discord_reaction(reaction_data, agent_key, bot_token, bot_user_id)
  channel_id = reaction_data["channel_id"]
  message_id = reaction_data["message_id"]
  user_id = reaction_data["user_id"]
  emoji = reaction_data["emoji"]
  emoji_name = emoji["name"]

  agent_name = fizzy_display_name(agent_key) || agent_key.capitalize

  # Ignore reactions from bots (including self)
  return if user_id == bot_user_id

  # Handle ❔ or ❓ reactions (thinking file inspection)
  if ["❔", "❓"].include?(emoji_name)
    session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"
    line_count = emoji_name == "❔" ? 10 : 20

    ACTIVE_SESSIONS_MUTEX.synchronize do
      session_info = ACTIVE_SESSIONS[session_key]

      unless session_info
        LOG.info "[Discord:#{agent_name}] #{emoji_name} reaction on #{message_id} but no active session found"
        return
      end

      log_file = session_info[:log_file]
      unless log_file && File.exist?(log_file)
        LOG.warn "[Discord:#{agent_name}] No log file found for session #{session_key}"
        send_discord_message(channel_id, "No thinking file found for this session.", token: bot_token, reply_to: message_id)
        return
      end

      LOG.info "[Discord:#{agent_name}] Reading last #{line_count} lines from #{log_file}"

      # Read last N lines from the log file
      lines = File.readlines(log_file).last(line_count)
      thinking_output = lines.join

      # Strip all ANSI escape codes and non-ASCII characters
      thinking_output = thinking_output.gsub(/\e\[[0-9;]*[a-zA-Z]/, "") # All CSI sequences
                                       .gsub(/\x1b\[[0-9;]*[a-zA-Z]/, "") # Alternative CSI notation
                                       .gsub(/\e\][0-9;]*.*?(\x07|\e\\)/, "") # OSC sequences
                                       .gsub(/\e[=>]/, "")                 # Other escape sequences
                                       .gsub(/\[\?[0-9]+[lh]/, "")         # Cursor visibility
                                       .gsub("[K", "") # Clear line
                                       .encode("ASCII", invalid: :replace, undef: :replace, replace: "") # Strip non-ASCII
                                       .strip

      # Post to Discord as a code block
      response = "**Last #{line_count} lines:**\n```\n#{thinking_output}\n```"
      send_discord_message(channel_id, response, token: bot_token, reply_to: message_id)
    end
    return
  end

  # Handle 🧠 reaction (stream full thinking to thread)
  if emoji_name == "🧠"
    session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"

    ACTIVE_SESSIONS_MUTEX.synchronize do
      session_info = ACTIVE_SESSIONS[session_key]

      unless session_info
        LOG.info "[Discord:#{agent_name}] 🧠 reaction on #{message_id} but no active session found"
        return
      end

      log_file = session_info[:log_file]
      unless log_file && File.exist?(log_file)
        LOG.warn "[Discord:#{agent_name}] No log file found for session #{session_key}"
        send_discord_message(channel_id, "No thinking file found for this session.", token: bot_token, reply_to: message_id)
        return
      end

      LOG.info "[Discord:#{agent_name}] Creating thread and streaming thinking from #{log_file}"

      # Create thread
      thread_response = create_discord_thread(channel_id, message_id, name: "🧠 Thinking Stream", token: bot_token)
      unless thread_response && thread_response["id"]
        LOG.error "[Discord:#{agent_name}] Failed to create thread, response: #{thread_response.inspect}"
        return
      end

      thread_id = thread_response["id"]
      LOG.info "[Discord:#{agent_name}] Thread created: #{thread_id}"

      # Read and clean full thinking file
      thinking_content = File.read(log_file)
      thinking_content = thinking_content.gsub(/\e\[[0-9;]*[a-zA-Z]/, "")
                                         .gsub(/\x1b\[[0-9;]*[a-zA-Z]/, "")
                                         .gsub(/\e\][0-9;]*.*?(\x07|\e\\)/, "")
                                         .gsub(/\e[=>]/, "")
                                         .gsub(/\[\?[0-9]+[lh]/, "")
                                         .gsub("[K", "")
                                         .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
                                         .strip

      # Split into 1900-char chunks (leave room for code blocks)
      chunks = []
      current_chunk = ""
      thinking_content.lines.each do |line|
        if current_chunk.length + line.length > 1900
          chunks << current_chunk
          current_chunk = line
        else
          current_chunk += line
        end
      end
      chunks << current_chunk unless current_chunk.empty?

      # Post chunks to thread
      chunks.each do |chunk|
        send_discord_message(thread_id, "```\n#{chunk}\n```", token: bot_token)
        sleep 0.5 # Rate limit protection
      end
    end
    return
  end

  # --- Feedback logging for non-reserved emojis ---
  unless RESERVED_EMOJIS.include?(emoji_name)
    Thread.new do
      log_emoji_feedback(channel_id, message_id, user_id, emoji_name, agent_key, agent_name, bot_token)
    rescue StandardError => e
      LOG.warn "[Discord:#{agent_name}] Feedback logging failed: #{e.message}"
    end
    return
  end

  # Only handle ❌ reactions beyond this point
  return unless emoji_name == "❌"

  # Check if there's an active session for this message
  session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"

  ACTIVE_SESSIONS_MUTEX.synchronize do
    session_info = ACTIVE_SESSIONS[session_key]

    unless session_info
      LOG.info "[Discord:#{agent_name}] ❌ reaction on #{message_id} but no active session found"
      return
    end

    LOG.info "[Discord:#{agent_name}] Cancelling session for message #{message_id} (PID: #{session_info[:pid]})"

    # Kill the agent process
    begin
      Process.kill("KILL", session_info[:pid])
      LOG.info "[Discord:#{agent_name}] Killed agent process #{session_info[:pid]}"
    rescue Errno::ESRCH
      LOG.warn "[Discord:#{agent_name}] Process #{session_info[:pid]} already exited"
    rescue Errno::EPERM
      LOG.error "[Discord:#{agent_name}] Permission denied killing process #{session_info[:pid]}"
    end

    # Remove from active sessions
    ACTIVE_SESSIONS.delete(session_key)

    # Update reactions: remove 👀, add 🛑
    begin
      remove_discord_reaction(channel_id, message_id, "👀", token: bot_token)
      add_discord_reaction(channel_id, message_id, "🛑", token: bot_token)
    rescue StandardError => e
      LOG.warn "[Discord:#{agent_name}] Failed to update reactions: #{e.message}"
    end

    # Clean up draft files if they exist
    session_info[:draft_files]&.each do |file|
      FileUtils.rm_f(file)
    end
  end
end

# --- Emoji Feedback Logging ---
# Logs non-reserved emoji reactions on bot messages to the agent's persona feedback file.
# No LLM call, no dispatch — just a file append.

def log_emoji_feedback(channel_id, message_id, user_id, emoji_name, agent_key, agent_name, bot_token)
  # Verify the message was posted by this bot (quiet — bots get reactions from channels they can't access)
  msg = fetch_discord_message(channel_id, message_id, token: bot_token, log_errors: false)
  return unless msg&.dig("author", "bot")

  bot_user_id = DISCORD_BOTS_MUTEX.synchronize { DISCORD_BOTS.dig(agent_key, :user_id) }
  return unless bot_user_id && msg.dig("author", "id") == bot_user_id

  # Resolve reactor to canonical name
  reactor = find_user_by_discord_id(user_id)
  reactor_name = reactor ? reactor["canonical_name"] : user_id

  # Build a brief context snippet from the message
  snippet = (msg["content"] || "")[0, 80].tr("\n", " ").strip
  snippet = "#{snippet}..." if (msg["content"] || "").length > 80

  # Append to persona feedback file
  feedback_dir = File.join(persona_dir_for(agent_name), "people")
  FileUtils.mkdir_p(feedback_dir)
  feedback_file = File.join(feedback_dir, "#{reactor_name.downcase.gsub(/[^a-z0-9]/, "-")}-feedback.md")

  timestamp = Time.now.strftime("%Y-%m-%d %H:%M")
  entry = "- #{timestamp} #{emoji_name} on: \"#{snippet}\" (channel: #{channel_id})\n"

  # Create file with header if new
  if File.exist?(feedback_file)
    File.open(feedback_file, "a") { |f| f.write(entry) }
  else
    File.write(feedback_file, "# Feedback from #{reactor_name}\n\n## Reaction Log\n#{entry}")
  end

  LOG.info "[Discord:#{agent_name}] Logged #{emoji_name} feedback from #{reactor_name} on message #{message_id}"
end

# --- Discord Draft Delivery ---
# Shared logic for posting a draft response file to Discord and moving it to posted/.
# Used by both the monitoring thread (happy path) and the poller (recovery path).

def deliver_discord_draft(response_file, meta_file)
  return false unless File.exist?(meta_file)

  # Simple file-based lock to prevent the monitoring thread and poller
  # from delivering the same draft simultaneously.
  lock_file = "#{meta_file}.lock"
  begin
    File.open(lock_file, File::CREAT | File::EXCL | File::WRONLY) {} # atomic create-or-fail
  rescue Errno::EEXIST
    return false # Another thread is already delivering this draft
  end

  meta = JSON.parse(File.read(meta_file))
  channel_id = meta["channel_id"]
  message_id = meta["message_id"]
  agent_key = meta["agent_key"]
  agent_name = meta["agent_name"]
  is_dm = meta["is_dm"]
  is_thread = meta["is_thread"]
  clean_content = meta["clean_content"] || ""

  # Look up the bot token from the current registry
  bot_token = DISCORD_BOTS_MUTEX.synchronize { DISCORD_BOTS.dig(agent_key, :token) }
  bot_token ||= (AGENT_REGISTRY.dig(agent_key, "env") || {})["DISCORD_BOT_TOKEN"]

  unless bot_token
    LOG.warn "[Discord:#{agent_name}] No bot token found for #{agent_key}, cannot deliver draft"
    FileUtils.rm_f(lock_file)
    return false
  end

  if File.exist?(response_file)
    response = File.read(response_file).strip
    if response.empty?
      add_discord_reaction(channel_id, message_id, "😶", token: bot_token) if message_id
      send_discord_message(channel_id, "_#{agent_name} had nothing to say._", token: bot_token)
    elsif is_dm || is_thread || message_id.nil?
      # DMs, threads, and cron jobs (no message_id) need special handling
      # Check if this is a forum channel
      if message_id.nil? && forum_channel?(channel_id, token: bot_token)
        title = meta["forum_title"] || "#{agent_name} — #{Time.now.strftime("%b %d, %Y")}"
        if meta["forum_reply_to_latest"]
          latest_thread = find_latest_forum_thread(channel_id, token: bot_token)
          if latest_thread
            send_long_discord_message(latest_thread["id"], response, token: bot_token)
          else
            LOG.warn "[Discord:#{agent_name}] No existing thread found, creating new forum post"
            create_forum_post(channel_id, title: title, content: response, token: bot_token)
          end
        else
          create_forum_post(channel_id, title: title, content: response, token: bot_token)
        end
      else
        # Regular DM, thread, or text channel
        send_long_discord_message(channel_id, response, token: bot_token)
      end
    else
      # Check if another agent (local OR remote) already created a thread
      # for this message. Three-tier lookup:
      #   1. Local in-memory cache (DISCORD_SHARED_THREADS) — fast, same-machine
      #   2. Discord API — fetch the original message and check its `thread` field
      #      This is the cross-machine fix: if machine B's agent finishes after
      #      machine A already created a thread, the API will reveal it.
      #   3. Create a new thread if neither found one.
      # The mutex still covers the local check + create to prevent same-machine races.
      thread_id = nil
      created_thread = false
      DISCORD_SHARED_THREADS_MUTEX.synchronize do
        thread_id = DISCORD_SHARED_THREADS[message_id]

        # Tier 2: Ask Discord if a thread already exists on this message.
        # This catches threads created by agents on other machines.
        unless thread_id
          original_msg = discord_api(:get, "/channels/#{channel_id}/messages/#{message_id}", token: bot_token)
          if original_msg&.dig("thread", "id")
            thread_id = original_msg["thread"]["id"]
            DISCORD_SHARED_THREADS[message_id] = thread_id
            LOG.info "[Discord:#{agent_name}] Discovered existing thread #{thread_id} on message #{message_id} via API"
          end
        end

        # Tier 3: No thread exists anywhere — create one.
        unless thread_id
          display_name = fizzy_display_name(agent_key)
          thread = create_discord_thread(channel_id, message_id, name: "#{display_name}: #{clean_content[0..80]}", token: bot_token)
          if thread && thread["id"]
            thread_id = thread["id"]
            DISCORD_SHARED_THREADS[message_id] = thread_id
            created_thread = true
            LOG.info "[Discord:#{agent_name}] Created shared thread #{thread_id} for message #{message_id}"
          end
        end
      end

      if thread_id
        LOG.info "[Discord:#{agent_name}] Joining shared thread #{thread_id} for message #{message_id}" unless created_thread

        # Propagate the parent channel's dispatch depth to the thread so
        # cross-agent mentions inside the thread aren't blocked immediately.
        # The human's message was in the parent channel, but agent responses
        # land in this thread (different channel_id). Without this, the
        # thread's depth key has no entry and agent_dispatch_allowed? returns false.
        parent_depth_key = "discord-#{channel_id}"
        thread_depth_key = "discord-#{thread_id}"
        parent_info = AGENT_DISPATCH_DEPTH[parent_depth_key]
        unless AGENT_DISPATCH_DEPTH[thread_depth_key]
          if parent_info
            AGENT_DISPATCH_DEPTH[thread_depth_key] = { count: 0, last_human_at: parent_info[:last_human_at] }
            LOG.info "[Discord:#{agent_name}] Propagated dispatch depth from channel #{channel_id} to thread #{thread_id}"
          else
            # No parent depth entry (edge case) — initialize with current time
            record_human_comment(thread_depth_key)
          end
        end

        send_discord_typing(thread_id, token: bot_token)
        send_long_discord_message(thread_id, response, token: bot_token)
      else
        LOG.warn "[Discord:#{agent_name}] Thread creation failed, falling back to reply"
        send_long_discord_message(channel_id, response, token: bot_token, reply_to: message_id)
      end
    end
  else
    # Response file doesn't exist yet — agent may still be running
    FileUtils.rm_f(lock_file)
    return false
  end

  # Move both files to posted/
  basename = File.basename(response_file)
  meta_basename = File.basename(meta_file)
  FileUtils.mv(response_file, File.join(DISCORD_POSTED_DIR, basename)) if File.exist?(response_file)
  FileUtils.mv(meta_file, File.join(DISCORD_POSTED_DIR, meta_basename))
  FileUtils.rm_f(lock_file)
  LOG.info "[Discord:#{agent_name}] Draft delivered and moved to posted/"
  true
rescue StandardError => e
  LOG.error "[Discord] Failed to deliver draft #{meta_file}: #{e.message}"
  File.delete(lock_file) if lock_file && File.exist?(lock_file)
  false
end

# Poller thread: scans draft/ for orphaned response files and delivers them.
# Runs every 5 seconds. Only attempts delivery if the response file exists
# (meaning the agent finished) and the meta file is at least 30 seconds old
# (giving the monitoring thread a chance to handle it first).

DISCORD_DRAFT_POLLER_INTERVAL = 5   # seconds
DISCORD_DRAFT_MIN_AGE = 30          # seconds — don't race the monitoring thread

def start_discord_draft_poller
  Thread.new do
    LOG.info "[Discord] Draft poller started, checking #{DISCORD_DRAFT_DIR} every #{DISCORD_DRAFT_POLLER_INTERVAL}s"
    loop do
      sleep DISCORD_DRAFT_POLLER_INTERVAL
      begin
        # Clean up stale lock files (older than 60s) left by crashed deliveries
        Dir.glob(File.join(DISCORD_DRAFT_DIR, "*.lock")).each do |lock_file|
          File.delete(lock_file) if (Time.now - File.mtime(lock_file)) > 60
        end

        Dir.glob(File.join(DISCORD_DRAFT_DIR, "*.meta.json")).each do |meta_file|
          # Don't race the monitoring thread — wait for the file to age
          next if (Time.now - File.mtime(meta_file)) < DISCORD_DRAFT_MIN_AGE

          # Cron metas: foo.md.meta.json → foo.md
          # Discord metas: foo.meta.json → foo.md
          response_file = if meta_file.end_with?(".md.meta.json")
                            meta_file.sub(".md.meta.json", ".md")
                          else
                            meta_file.sub(".meta.json", ".md")
                          end
          next unless File.exist?(response_file)

          LOG.info "[Discord] Poller recovering orphaned draft: #{File.basename(meta_file)}"
          deliver_discord_draft(response_file, meta_file)
        end
      rescue StandardError => e
        LOG.error "[Discord] Draft poller error: #{e.message}"
      end
    end
  end
end

# --- Discord Gateway (one per agent bot) ---

def start_discord_gateway_for(agent_key, bot_token)
  Thread.new do
    agent_display = fizzy_display_name(agent_key) || agent_key.capitalize
    bot_user_id = nil

    loop do
      DISCORD_BOTS_MUTEX.synchronize do
        DISCORD_BOTS[agent_key] ||= {}
        DISCORD_BOTS[agent_key][:status] = "connecting"
        DISCORD_BOTS[agent_key][:token] = bot_token
      end

      LOG.debug "[Discord:#{agent_display}] Connecting to Gateway..."

      heartbeat_thread = nil
      last_sequence = nil

      ws = WebSocket::Client::Simple.connect(DISCORD_GATEWAY_URL)

      ws.on :message do |msg|
        next if msg.data.nil? || msg.data.empty?

        payload = JSON.parse(msg.data)
        op = payload["op"]
        data = payload["d"]
        last_sequence = payload["s"] if payload["s"]

        case op
        when 10 # Hello
          heartbeat_interval = data["heartbeat_interval"]
          LOG.debug "[Discord:#{agent_display}] Gateway connected, heartbeat: #{heartbeat_interval}ms"

          heartbeat_thread&.kill
          heartbeat_thread = Thread.new do
            loop do
              sleep(heartbeat_interval / 1000.0)
              ws.send({ op: 1, d: last_sequence }.to_json)
            end
          end

          ws.send({
            op: 2,
            d: {
              token: bot_token,
              intents: 46_593,
              properties: { os: RUBY_PLATFORM, browser: "brainiac", device: "brainiac" }
            }
          }.to_json)

        when 0 # Dispatch
          case payload["t"]
          when "READY"
            bot_user_id = data.dig("user", "id")
            DISCORD_BOTS_MUTEX.synchronize do
              DISCORD_BOTS[agent_key][:user_id] = bot_user_id
              DISCORD_BOTS[agent_key][:status] = "ready"
            end
            guild_count = data["guilds"]&.size || 0
            LOG.info "[Discord] #{agent_display} ready (#{guild_count} #{guild_count == 1 ? "guild" : "guilds"})"
            LOG.debug "[Discord:#{agent_display}] user_id=#{bot_user_id}"

            # Check if all bots are now ready (log once)
            DISCORD_BOTS_MUTEX.synchronize do
              if !DISCORD_ALL_READY_LOGGED[:done] && DISCORD_BOTS.all? { |_, info| info[:status] == "ready" }
                DISCORD_ALL_READY_LOGGED[:done] = true
                LOG.info "[Discord] All bots connected."
              end
            end

          when "MESSAGE_CREATE"
            Thread.new do
              handle_discord_message(data, agent_key, bot_token, bot_user_id)
            rescue StandardError => e
              LOG.error "[Discord:#{agent_display}] Error handling message: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
            end

          when "MESSAGE_UPDATE"
            # Discord sends MESSAGE_UPDATE for embed/link preview resolution,
            # not just human edits. Only dispatch if edited_timestamp is set
            # (real edit) — otherwise it's just Discord enriching the message.
            if data["edited_timestamp"]
              Thread.new do
                handle_discord_message(data, agent_key, bot_token, bot_user_id)
              rescue StandardError => e
                LOG.error "[Discord:#{agent_display}] Error handling message update: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
              end
            end

          when "MESSAGE_REACTION_ADD"
            Thread.new do
              handle_discord_reaction(data, agent_key, bot_token, bot_user_id)
            rescue StandardError => e
              LOG.error "[Discord:#{agent_display}] Error handling reaction: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
            end
          end

        when 1  then ws.send({ op: 1, d: last_sequence }.to_json)
        when 7  then LOG.info "[Discord:#{agent_display}] Reconnect requested"
                     ws.close
        when 9  then LOG.warn "[Discord:#{agent_display}] Invalid session, re-identifying in 5s"
                     sleep 5
                     ws.send({ op: 2, d: { token: bot_token, intents: 46_593,
                                           properties: { os: RUBY_PLATFORM, browser: "brainiac", device: "brainiac" } } }.to_json)
        when 11 then nil # Heartbeat ACK
        end
      rescue StandardError => e
        LOG.error "[Discord:#{agent_display}] Gateway message error: #{e.message}"
      end

      ws.on :open do
        LOG.debug "[Discord:#{agent_display}] WebSocket connected"
      end

      ws.on :close do |e|
        DISCORD_BOTS_MUTEX.synchronize do
          DISCORD_BOTS[agent_key][:status] = "disconnected" if DISCORD_BOTS[agent_key]
        end
        LOG.warn "[Discord:#{agent_display}] WebSocket closed: #{e&.inspect}"
        heartbeat_thread&.kill
      end

      ws.on :error do |e|
        LOG.error "[Discord:#{agent_display}] WebSocket error: #{e.message}"
      end

      loop do
        sleep 1
        next if ws.open?

        LOG.info "[Discord:#{agent_display}] Connection lost, reconnecting in 5s..."
        sleep 5
        break
      end
    rescue StandardError => e
      DISCORD_BOTS_MUTEX.synchronize do
        DISCORD_BOTS[agent_key][:status] = "error" if DISCORD_BOTS[agent_key]
      end
      LOG.error "[Discord:#{agent_display}] Gateway error: #{e.message}, reconnecting in 5s..."
      sleep 5
    end
  end
end

# Start all per-agent Discord bots.
def start_all_discord_gateways
  tokens = discord_bot_tokens
  if tokens.empty?
    LOG.info "[Discord] No agents have DISCORD_BOT_TOKEN configured — Discord disabled"
    return
  end

  LOG.info "[Discord] Starting #{tokens.size} bot(s): #{tokens.keys.join(", ")}"
  tokens.each do |agent_key, token|
    DISCORD_BOTS_MUTEX.synchronize do
      DISCORD_BOTS[agent_key] = { token: token, status: "starting", user_id: nil }
    end
    start_discord_gateway_for(agent_key, token)
    sleep 1 # Stagger connections to avoid rate limits
  end
end

# Summary of all bot statuses for the API endpoint.
def discord_bots_status
  DISCORD_BOTS_MUTEX.synchronize do
    DISCORD_BOTS.transform_values do |info|
      { status: info[:status], user_id: info[:user_id] }
    end
  end
end
