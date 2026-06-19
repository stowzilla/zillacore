# frozen_string_literal: true

# User identity registry - resolves identities across platforms
# (Discord, GitHub, Fizzy)

USERS_FILE = File.join(BRAINIAC_DIR, "users.json")

def load_user_registry
  return { "users" => [] } unless File.exist?(USERS_FILE)

  data = JSON.parse(File.read(USERS_FILE))
  LOG.info "Loaded #{data["users"].size} user(s) from #{USERS_FILE}"
  data
rescue JSON::ParserError => e
  LOG.error "Failed to parse user registry: #{e.message}"
  { "users" => [] }
end

def reload_user_registry!(force: false)
  return unless file_changed?(USERS_FILE, force: force)

  USER_REGISTRY.replace(load_user_registry)
  LOG.info "Reloaded user registry: #{USER_REGISTRY["users"].size} users"
end

USER_REGISTRY = load_user_registry

# Find user by Discord user ID
def find_user_by_discord_id(user_id)
  USER_REGISTRY["users"].find { |u| u.dig("identities", "discord", "user_id") == user_id.to_s }
end

# Find user by Discord username
def find_user_by_discord_username(username)
  USER_REGISTRY["users"].find { |u| u.dig("identities", "discord", "username") == username.to_s }
end

# Find user by GitHub username
def find_user_by_github_username(username)
  USER_REGISTRY["users"].find { |u| u.dig("identities", "github", "username") == username.to_s }
end

# Find user by Fizzy username
def find_user_by_fizzy_username(username)
  USER_REGISTRY["users"].find { |u| u.dig("identities", "fizzy", "username") == username.to_s }
end

# Find user by canonical name
def find_user_by_canonical_name(name)
  USER_REGISTRY["users"].find { |u| u["canonical_name"].downcase == name.downcase }
end

# Find user by any identifier (tries all platforms)
def find_user(identifier)
  find_user_by_discord_id(identifier) ||
    find_user_by_discord_username(identifier) ||
    find_user_by_github_username(identifier) ||
    find_user_by_fizzy_username(identifier) ||
    find_user_by_canonical_name(identifier)
end

# Get canonical name for a platform-specific identifier
def canonical_name_for(identifier)
  user = find_user(identifier)
  user ? user["canonical_name"] : identifier
end

# Get all human users (exclude AI agents)
def human_users
  USER_REGISTRY["users"].reject { |u| u["notes"]&.include?("AI agent") }
end

# Get all AI agents
def ai_agents
  USER_REGISTRY["users"].select { |u| u["notes"]&.include?("AI agent") }
end
