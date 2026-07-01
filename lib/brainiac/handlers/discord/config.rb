# frozen_string_literal: true

# Discord configuration and shared state.
#
# Constants, config loading, and thread map persistence used across
# all Discord sub-modules.

DISCORD_CONFIG_FILE = File.join(BRAINIAC_DIR, "discord.json")

# Discord thread worktree map: tracks worktrees created for Discord thread conversations.
# Keyed by "agent_key:channel_id" → { worktree, branch, project, created_at }
# Persisted to disk so sessions survive restarts.
DISCORD_THREAD_MAP_FILE = File.join(BRAINIAC_DIR, "discord_thread_map.json")
DISCORD_THREAD_MAP_MUTEX = Mutex.new

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

# --- Thread Map Persistence ---

def load_discord_thread_map
  return {} unless File.exist?(DISCORD_THREAD_MAP_FILE)

  JSON.parse(File.read(DISCORD_THREAD_MAP_FILE))
rescue JSON::ParserError
  {}
end

def save_discord_thread_map(map)
  File.write(DISCORD_THREAD_MAP_FILE, JSON.pretty_generate(map))
end

# --- Channel/Project Routing ---

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
def find_root_message(message, channel_id, bot_token)
  current_msg = message
  visited = Set.new
  max_depth = 20
  walked = false

  max_depth.times do
    msg_id = current_msg["id"]
    return { id: msg_id, content: nil, author: nil } if visited.include?(msg_id)

    visited << msg_id

    ref = current_msg["message_reference"]
    break unless ref

    ref_msg_id = ref["message_id"]
    ref_channel = ref["channel_id"] || channel_id
    break unless ref_msg_id

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
def discord_mention_roster
  lines = []

  DISCORD_BOTS_MUTEX.synchronize do
    DISCORD_BOTS.each do |agent_key, info|
      next unless info[:user_id]

      display = agent_display_name(agent_key) || agent_key.capitalize
      lines << "  - #{display}: `<@#{info[:user_id]}>`"
    end
  end

  user_mappings = DISCORD_CONFIG["user_mappings"] || {}
  user_mappings.each do |name, discord_id|
    lines << "  - #{name}: `<@#{discord_id}>`"
  end

  lines.join("\n")
end
