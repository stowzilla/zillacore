#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

# UserRegistry - Centralized user identity tracking
#
# Resolves user identities across platforms (Discord, GitHub, Fizzy)
# and provides canonical names, aliases, and relationships.
#
# Usage:
#   registry = UserRegistry.new
#   user = registry.find_by_discord_id('832331260088287242')
#   puts user['canonical_name']  # => "Adam Dalton"
#   puts user['identities']['github']['username']  # => "dalton"
#
class UserRegistry
  USERS_FILE = File.expand_path("~/.brainiac/users.json")

  def initialize
    @data = load_data
  end

  # Find user by Discord user ID
  def find_by_discord_id(user_id)
    @data["users"].find { |u| u.dig("identities", "discord", "user_id") == user_id.to_s }
  end

  # Find user by Discord username
  def find_by_discord_username(username)
    @data["users"].find { |u| u.dig("identities", "discord", "username") == username.to_s }
  end

  # Find user by GitHub username
  def find_by_github_username(username)
    @data["users"].find { |u| u.dig("identities", "github", "username") == username.to_s }
  end

  # Find user by Fizzy username
  def find_by_fizzy_username(username)
    @data["users"].find { |u| u.dig("identities", "fizzy", "username") == username.to_s }
  end

  # Find user by canonical name
  def find_by_canonical_name(name)
    @data["users"].find { |u| u["canonical_name"].downcase == name.downcase }
  end

  # Find user by any identifier (tries all platforms)
  def find(identifier)
    find_by_discord_id(identifier) ||
      find_by_discord_username(identifier) ||
      find_by_github_username(identifier) ||
      find_by_fizzy_username(identifier) ||
      find_by_canonical_name(identifier)
  end

  # Get all users
  def all
    @data["users"]
  end

  # Get all human users (exclude AI agents)
  def humans
    @data["users"].reject { |u| u["notes"]&.include?("AI agent") }
  end

  # Get all AI agents
  def agents
    @data["users"].select { |u| u["notes"]&.include?("AI agent") }
  end

  # Reload data from disk
  def reload!
    @data = load_data
  end

  private

  def load_data
    return { "users" => [] } unless File.exist?(USERS_FILE)

    JSON.parse(File.read(USERS_FILE))
  rescue JSON::ParserError => e
    warn "Failed to parse #{USERS_FILE}: #{e.message}"
    { "users" => [] }
  end
end

# CLI interface when run directly
if __FILE__ == $PROGRAM_NAME
  require "optparse"

  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: user_registry.rb [options] [identifier]"

    opts.on("-d", "--discord-id ID", "Find by Discord user ID") do |id|
      options[:discord_id] = id
    end

    opts.on("-u", "--discord-username USERNAME", "Find by Discord username") do |username|
      options[:discord_username] = username
    end

    opts.on("-g", "--github USERNAME", "Find by GitHub username") do |username|
      options[:github] = username
    end

    opts.on("-f", "--fizzy USERNAME", "Find by Fizzy username") do |username|
      options[:fizzy] = username
    end

    opts.on("-l", "--list", "List all users") do
      options[:list] = true
    end

    opts.on("--humans", "List only human users") do
      options[:humans] = true
    end

    opts.on("--agents", "List only AI agents") do
      options[:agents] = true
    end

    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit
    end
  end.parse!

  registry = UserRegistry.new

  if options[:list]
    puts JSON.pretty_generate(registry.all)
  elsif options[:humans]
    puts JSON.pretty_generate(registry.humans)
  elsif options[:agents]
    puts JSON.pretty_generate(registry.agents)
  elsif options[:discord_id]
    user = registry.find_by_discord_id(options[:discord_id])
    puts user ? JSON.pretty_generate(user) : "User not found"
  elsif options[:discord_username]
    user = registry.find_by_discord_username(options[:discord_username])
    puts user ? JSON.pretty_generate(user) : "User not found"
  elsif options[:github]
    user = registry.find_by_github_username(options[:github])
    puts user ? JSON.pretty_generate(user) : "User not found"
  elsif options[:fizzy]
    user = registry.find_by_fizzy_username(options[:fizzy])
    puts user ? JSON.pretty_generate(user) : "User not found"
  elsif ARGV[0]
    user = registry.find(ARGV[0])
    puts user ? JSON.pretty_generate(user) : "User not found"
  else
    puts "No search criteria provided. Use --help for usage."
    exit 1
  end
end
