# frozen_string_literal: true

require "json"
require "openssl"
require "open3"
require "fileutils"
require "logger"
require "net/http"
require "uri"

# --- Version ---

require_relative "version"
BRAINIAC_VERSION = Brainiac::VERSION

# --- Environment & paths ---

FIZZY_WEBHOOK_SECRET = ENV.fetch("FIZZY_WEBHOOK_SECRET", nil)
AI_AGENT_NAME = ENV.fetch("AI_AGENT_NAME") do
  case RbConfig::CONFIG["host_os"]
  when /darwin/i then "Kaylee"
  else "Galen"
  end
end

BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
PROJECTS_FILE = File.join(BRAINIAC_DIR, "projects.json")
KIRO_AGENTS_DIR = File.join(Dir.home, ".kiro", "agents")
CARD_MAP_FILE   = File.join(BRAINIAC_DIR, "card_map.json")
AGENT_TOKENS_FILE = File.join(BRAINIAC_DIR, "agent_tokens.json")
AGENT_REGISTRY_FILE = File.join(BRAINIAC_DIR, "agents.json")

LOG_LEVEL = ENV.fetch("LOG_LEVEL", "info").downcase
LOG = Logger.new($stdout)
LOG.level = case LOG_LEVEL
            when "debug" then Logger::DEBUG
            when "info" then Logger::INFO
            when "warn" then Logger::WARN
            when "error" then Logger::ERROR
            else Logger::INFO # rubocop:disable Lint/DuplicateBranch
            end

# --- Brain paths ---

BRAIN_BASE_DIR       = File.join(BRAINIAC_DIR, "brain")
KNOWLEDGE_DIR        = File.join(BRAIN_BASE_DIR, "knowledge")
PERSONA_BASE_DIR     = File.join(BRAIN_BASE_DIR, "persona")
MEMORY_BASE_DIR      = File.join(BRAINIAC_DIR, "brain", "memory")
MEMORY_FILE_TEMPLATE = "card-{{CARD_ID}}.md"
KNOWLEDGE_COLLECTION = "brainiac-knowledge"

# --- Fizzy auth ---

FIZZY_CONFIG_FILE = File.join(BRAINIAC_DIR, "fizzy.json")

def load_fizzy_config
  return {} unless File.exist?(FIZZY_CONFIG_FILE)

  JSON.parse(File.read(FIZZY_CONFIG_FILE))
rescue JSON::ParserError => e
  LOG.error "Failed to parse Fizzy config: #{e.message}"
  {}
end

FIZZY_CONFIG = load_fizzy_config

# --- GitHub auth ---

GITHUB_CONFIG_FILE = File.join(BRAINIAC_DIR, "github.json")

def load_github_config
  return {} unless File.exist?(GITHUB_CONFIG_FILE)

  JSON.parse(File.read(GITHUB_CONFIG_FILE))
rescue JSON::ParserError => e
  LOG.error "Failed to parse GitHub config: #{e.message}"
  {}
end

GITHUB_CONFIG = load_github_config

def github_webhook_secret
  # Fallback to env var for backwards compatibility
  GITHUB_CONFIG["webhook_secret"] || ENV.fetch("GITHUB_WEBHOOK_SECRET", nil)
end

# --- Board config ---

FIZZY_BOARDS = FIZZY_CONFIG["boards"] || {}

def board_config(board_key)
  FIZZY_BOARDS[board_key.to_s]
end

def board_webhook_secret(board_key)
  config = board_config(board_key)
  config&.dig("webhook_secret") || FIZZY_WEBHOOK_SECRET
end

def board_column_id(board_key, column_name)
  config = board_config(board_key)
  config&.dig("columns", column_name.to_s)
end

# Find board_key by board_id (from .fizzy.yaml or payload)
def board_key_for_id(board_id)
  FIZZY_BOARDS.each do |key, config|
    return key if config["board_id"] == board_id
  end
  nil
end

# Determine board_key for a project by reading its .fizzy.yaml
def board_key_for_project(project_config)
  fizzy_yaml = File.join(project_config["repo_path"], ".fizzy.yaml")
  return nil unless File.exist?(fizzy_yaml)

  require "yaml"
  data = YAML.safe_load_file(fizzy_yaml)
  board_id = data["board"]
  board_key_for_id(board_id)
rescue StandardError => e
  LOG.warn "Could not read .fizzy.yaml for board lookup: #{e.message}"
  nil
end

# Build authorized user IDs from config or env var (env var overrides)
AUTHORIZED_USER_IDS = if ENV["AUTHORIZED_USER_IDS"] && !ENV["AUTHORIZED_USER_IDS"].empty?
                        ENV["AUTHORIZED_USER_IDS"].split(",").map(&:strip)
                      else
                        (FIZZY_CONFIG["authorized_users"] || []).map { |u| u["id"] }
                      end

NOTIFICATION_COMMAND = ENV.fetch("NOTIFICATION_COMMAND", nil)

# --- Projects ---

def load_projects_config
  return {} unless File.exist?(PROJECTS_FILE)

  projects = JSON.parse(File.read(PROJECTS_FILE))
  LOG.info "Loaded #{projects.size} project(s) from #{PROJECTS_FILE}"
  projects
rescue JSON::ParserError => e
  LOG.error "Failed to parse projects config: #{e.message}"
  {}
end

# Track file mtimes to avoid unnecessary reloads
CONFIG_MTIMES = {}

def file_changed?(path, force: false)
  return true if force
  return true unless File.exist?(path)

  current_mtime = File.mtime(path)
  last_mtime = CONFIG_MTIMES[path]
  if last_mtime == current_mtime
    false
  else
    CONFIG_MTIMES[path] = current_mtime
    true
  end
end

def reload_projects!(force: false)
  return unless file_changed?(PROJECTS_FILE, force: force)

  PROJECTS.replace(load_projects_config)
  LOG.info "Reloaded projects configuration: #{PROJECTS.keys.join(", ")}"
end

def reload_github_config!(force: false)
  return unless file_changed?(GITHUB_CONFIG_FILE, force: force)

  GITHUB_CONFIG.replace(load_github_config)
  LOG.info "Reloaded GitHub configuration"
end

PROJECTS = load_projects_config

DEFAULT_PROJECT = {
  "repo_path" => ENV.fetch("REPO_PATH", Dir.pwd),
  "fizzy_tags" => [],
  "github_repo" => ENV.fetch("GITHUB_REPO", nil),
  "agent_cli" => ENV.fetch("AGENT_CLI", "kiro-cli"),
  "agent_cli_args" => ENV.fetch("AGENT_CLI_ARGS", "chat --trust-all-tools --no-interactive"),
  "agent_model_flag" => ENV["AGENT_MODEL_FLAG"] || "--model",
  "agent_model" => ENV.fetch("AGENT_MODEL", nil),
  "agent_effort_flag" => ENV["AGENT_EFFORT_FLAG"] || "--effort",
  "agent_effort" => ENV.fetch("AGENT_EFFORT", nil),
  "allowed_models" => {
    "opus" => "claude-opus-4.6",
    "sonnet" => "claude-sonnet-4.6",
    "haiku" => "claude-haiku-4.5",
    "deepseek" => "deepseek-3.2",
    "minimax" => "minimax-m2.5",
    "minimax25" => "minimax-m2.5",
    "minimax21" => "minimax-m2.1",
    "qwen" => "qwen3-coder-next",
    "auto" => "auto"
  },
  "allowed_efforts" => %w[low medium high xhigh max]
}.freeze

# --- Discord (optional) ---
# Discord is enabled when any agent in the registry has a discord_bot_token,
# OR when the legacy DISCORD_BOT_TOKEN env var is set.
# Requires the websocket-client-simple gem.

DISCORD_ENABLED = begin
  require "websocket-client-simple"
  true
rescue LoadError
  warn "WARNING: websocket-client-simple gem not found. Discord bot disabled."
  warn "Install with: gem install websocket-client-simple"
  false
end

# --- Version check ---

# Check if local brainiac is behind origin/master.
# Returns { behind: true, local_sha:, remote_sha:, commits_behind: } or { behind: false }
def check_brainiac_version
  brainiac_dir = File.join(__dir__, "..", "..")

  # Fetch latest from origin (quiet, don't fail if offline)
  _, _, status = Open3.capture3("git", "fetch", "origin", "master", "--quiet", chdir: brainiac_dir)
  unless status.success?
    LOG.warn "[Version] Could not fetch origin/master — skipping version check"
    return { behind: false }
  end

  local_sha, = Open3.capture3("git", "rev-parse", "HEAD", chdir: brainiac_dir)
  remote_sha, = Open3.capture3("git", "rev-parse", "origin/master", chdir: brainiac_dir)
  local_sha = local_sha.strip
  remote_sha = remote_sha.strip

  return { behind: false } if local_sha == remote_sha

  count, = Open3.capture3("git", "rev-list", "--count", "HEAD..origin/master", chdir: brainiac_dir)
  { behind: true, local_sha: local_sha[0..6], remote_sha: remote_sha[0..6], commits_behind: count.strip.to_i }
end

# Discord user ID of the machine owner (for version-outdated notifications).
# Reads from discord.json (Discord-scoped config).
def owner_discord_id
  discord_file = File.join(BRAINIAC_DIR, "discord.json")
  return nil unless File.exist?(discord_file)

  JSON.parse(File.read(discord_file))["owner_discord_id"]
rescue JSON::ParserError
  nil
end

# --- Dashboard auth ---

DASHBOARD_TOKEN = begin
  discord_file = File.join(BRAINIAC_DIR, "discord.json")
  JSON.parse(File.read(discord_file))["dashboard_token"] if File.exist?(discord_file)
rescue JSON::ParserError
  nil
end
