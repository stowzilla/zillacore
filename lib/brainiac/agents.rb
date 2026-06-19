# frozen_string_literal: true

# Agent registry, discovery, identity, mention detection, and env injection.
#
# The registry at ~/.brainiac/agents.json uses a generic `env` hash so any
# environment variable can be set per-agent:
#
#   {
#     "galen": {
#       "fizzy_name": "Galen",
#       "local": true,
#       "env": {
#         "FIZZY_TOKEN": "fizzy_abc...",
#         "DISCORD_BOT_TOKEN": "Bot_abc..."
#       }
#     }
#   }
#
# The "local" flag marks agents that this machine should dispatch work for
# (card assignments). Agents without "local": true are still known for
# mention detection, display names, tokens, and cross-agent interactions —
# they just won't pick up card assignments on this machine.
#
# Legacy format with top-level `fizzy_token` / `discord_bot_token` keys is
# auto-migrated into the `env` hash at load time.

def load_agent_registry
  if File.exist?(AGENT_REGISTRY_FILE)
    raw_registry = JSON.parse(File.read(AGENT_REGISTRY_FILE))
    LOG.info "Loaded agent registry (#{raw_registry.size} agents) from #{AGENT_REGISTRY_FILE}"

    # Normalize keys: convert to lowercase, replace non-alphanumeric with hyphens
    registry = {}
    raw_registry.each do |key, entry|
      normalized_key = key.downcase.gsub(/[^a-z0-9-]/, "-")
      if registry.key?(normalized_key) && registry[normalized_key] != entry
        LOG.warn "Duplicate agent key after normalization: '#{key}' → '#{normalized_key}' (already exists)"
      end
      registry[normalized_key] = entry
    end

    # Migrate legacy keys into env hash
    registry.each_value do |entry|
      next unless entry.is_a?(Hash)

      entry["env"] ||= {}
      # Migrate fizzy_token → FIZZY_TOKEN
      if (ft = entry.delete("fizzy_token"))
        entry["env"]["FIZZY_TOKEN"] ||= ft
      end
      # Migrate discord_bot_token → DISCORD_BOT_TOKEN
      if (dt = entry.delete("discord_bot_token"))
        entry["env"]["DISCORD_BOT_TOKEN"] ||= dt
      end
    end
    return registry
  end

  if File.exist?(AGENT_TOKENS_FILE)
    tokens = JSON.parse(File.read(AGENT_TOKENS_FILE))
    LOG.info "Loaded legacy agent tokens (#{tokens.size} agents) from #{AGENT_TOKENS_FILE}"
    return tokens.transform_values { |token| { "env" => { "FIZZY_TOKEN" => token } } }
  end

  {}
rescue JSON::ParserError => e
  LOG.error "Failed to parse agent registry: #{e.message}"
  {}
end

AGENT_REGISTRY = load_agent_registry

def reload_agent_registry!(force: false)
  return unless file_changed?(AGENT_REGISTRY_FILE, force: force)

  AGENT_REGISTRY.replace(load_agent_registry)
  LOG.info "Reloaded agent registry: #{AGENT_REGISTRY.keys.join(", ")}"
end

# Get the env hash for an agent. Returns {} if none configured.
def agent_env_for(agent_name)
  return {} unless agent_name

  key = agent_name.downcase.gsub(/[^a-z0-9-]/, "-")
  entry = AGENT_REGISTRY[key]
  return {} unless entry.is_a?(Hash)

  entry["env"] || {}
end

# Get a specific env var for an agent. Returns nil if not set.
def agent_env_var(agent_name, var_name)
  agent_env_for(agent_name)[var_name]
end

# Convenience: get the Fizzy token for an agent.
def fizzy_token_for(agent_name)
  agent_env_var(agent_name, "FIZZY_TOKEN")
end

# Convenience: build env hash for fizzy CLI calls (backward compat).
# Falls back to default agent token when the given agent has no token.
def fizzy_env_for(agent_name)
  token = fizzy_token_for(agent_name) || fizzy_token_for(AI_AGENT_NAME)
  token ? { "FIZZY_TOKEN" => token } : {}
end

def default_fizzy_env
  fizzy_env_for(AI_AGENT_NAME)
end

def fizzy_display_name(agent_name)
  return agent_name unless agent_name

  key = agent_name.downcase.gsub(/[^a-z0-9-]/, "-")
  entry = AGENT_REGISTRY[key]
  return agent_name unless entry.is_a?(Hash)

  entry["fizzy_name"] || agent_name
end

def agent_roster
  roster = {}
  all_agent_names.each { |name| roster[name.downcase] = fizzy_display_name(name) }
  roster
end

def discover_kiro_agents
  return [] unless File.directory?(KIRO_AGENTS_DIR)

  Dir.glob(File.join(KIRO_AGENTS_DIR, "*.json")).map { |path| File.basename(path, ".json") }
rescue StandardError => e
  LOG.error "Failed to scan kiro agents directory: #{e.message}"
  []
end

def agent_name_for(project_config)
  project_config["agent_name"] || AI_AGENT_NAME
end

def all_agent_names
  names = Set.new([AI_AGENT_NAME])
  PROJECTS.each_value { |config| names << config["agent_name"] if config["agent_name"] }
  discover_kiro_agents.each { |name| names << name.capitalize }
  # Include agents from the registry (with their fizzy_name if specified)
  AGENT_REGISTRY.each do |key, entry|
    names << (entry["fizzy_name"] || key.capitalize)
  end
  names
end

# Agents marked "local": true in the registry — only these should pick up
# card assignments on this machine. All other agents are still "known" for
# mention detection, tokens, and display names.
def local_agent_names
  names = Set.new
  # The default AI_AGENT_NAME is always local (it's this machine's primary agent)
  names << AI_AGENT_NAME
  # Project-configured agents are local by definition
  PROJECTS.each_value { |config| names << config["agent_name"] if config["agent_name"] }
  # kiro-cli agent configs on disk are local
  discover_kiro_agents.each { |name| names << name.capitalize }
  # Registry agents only if explicitly marked local
  AGENT_REGISTRY.each do |key, entry|
    next unless entry.is_a?(Hash) && entry["local"]

    names << (entry["fizzy_name"] || key.capitalize)
  end
  names
end

def detect_mentioned_agent(text)
  downcased = text.downcase
  # Exact full-name match first (highest priority)
  all_agent_names.each do |name|
    return name if downcased.include?("@#{name.downcase}")

    # Fizzy renders mentions using first name only (e.g. "@Sleeper" not "@Sleeper Service").
    # Fall back to matching the first word of multi-word agent names.
    first_word = name.split.first.downcase
    next if first_word == name.downcase # already checked above
    return name if downcased.include?("@#{first_word}")
  end
  nil
end

def detect_mentioned_user_ids(text)
  return [] unless FIZZY_CONFIG["authorized_users"]

  mentioned_ids = []
  FIZZY_CONFIG["authorized_users"].each do |user|
    name = user["name"]
    mentioned_ids << user["id"] if text.downcase.include?("@#{name.downcase}")
  end
  mentioned_ids
end

def comment_from_agent?(name)
  return false unless name

  downcased = name.downcase
  all_agent_names.any? { |agent| agent.downcase == downcased }
end
