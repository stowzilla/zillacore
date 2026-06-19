#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Monitor Daemon
# Polls /api/status and exposes agent state via Unix socket for waybar
# No longer triggers config updates - waybar module polls this socket directly

require "json"
require "net/http"
require "socket"

SOCKET_PATH = "/tmp/brainiac-monitor.sock"
API_URL = "http://localhost:4567/api/status"
POLL_INTERVAL = 2 # seconds
CONFIG_PATH = File.expand_path("~/.brainiac/waybar.json")

# Load agent configuration from JSON
def load_agent_config
  config = JSON.parse(File.read(CONFIG_PATH))
  agents = {}
  config["agents"].each do |agent|
    agents[agent["name"]] = { color: agent["color"], emoji: agent["emoji"] }
  end
  agents
rescue StandardError => e
  warn "Failed to load waybar.json: #{e.message}"
  {}
end

AGENTS = load_agent_config.freeze

@state = { sessions: [], count: 0, recent: [], last_update: nil }

def fetch_status
  uri = URI(API_URL)
  response = Net::HTTP.get_response(uri)
  return nil unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
rescue StandardError => e
  warn "Failed to fetch status: #{e.message}"
  nil
end

def update_state
  data = fetch_status
  return unless data

  @state = {
    sessions: data["sessions"],
    count: data["count"],
    recent: data["recent"] || [],
    last_update: Time.now.to_i
  }
end

def handle_client(client)
  client.puts @state.to_json
  client.close
rescue StandardError => e
  warn "Error handling client: #{e.message}"
end

def start_server
  FileUtils.rm_f(SOCKET_PATH)

  server = UNIXServer.new(SOCKET_PATH)
  File.chmod(0o666, SOCKET_PATH)

  # Write PID file
  File.write("/tmp/brainiac-daemon.pid", Process.pid)

  puts "Monitor daemon started, socket: #{SOCKET_PATH}"

  # Start polling thread
  poller = Thread.new do
    loop do
      update_state
      sleep POLL_INTERVAL
    end
  end

  # Initial state fetch
  update_state

  # Accept client connections
  loop do
    client = server.accept
    Thread.new { handle_client(client) }
  end
rescue Interrupt
  puts "\nShutting down..."
  poller&.kill
  FileUtils.rm_f(SOCKET_PATH)
  FileUtils.rm_f("/tmp/brainiac-daemon.pid")
  exit 0
end

start_server
