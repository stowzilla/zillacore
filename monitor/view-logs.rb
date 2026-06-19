#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Log Viewer
# Shows a rofi menu to select which agent log to tail

require "json"
require "net/http"
require "socket"

SOCKET_PATH = "/tmp/brainiac-monitor.sock"
API_URL = "http://localhost:4567/api/status"
CONFIG_PATH = File.expand_path("~/.brainiac/waybar.json")

# Load agent configuration from JSON
def load_agent_config
  config = JSON.parse(File.read(CONFIG_PATH))
  agents = {}
  config["agents"].each do |agent|
    agents[agent["name"].downcase] = agent["emoji"]
  end
  default_emoji = config["default_emoji"] || "❓"
  [agents, default_emoji]
rescue StandardError => e
  warn "Failed to load waybar.json: #{e.message}"
  [{}, "❓"]
end

AGENTS, DEFAULT_EMOJI = load_agent_config

def fetch_state_from_socket
  socket = UNIXSocket.new(SOCKET_PATH)
  data = socket.read
  socket.close
  JSON.parse(data)
end

def fetch_state_from_api
  uri = URI(API_URL)
  response = Net::HTTP.get_response(uri)
  return nil unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
end

def fetch_state
  # Prefer socket (daemon mode) — faster, no HTTP overhead
  fetch_state_from_socket
rescue Errno::ENOENT, Errno::ECONNREFUSED
  # Daemon not running — fall back to direct API call
  data = fetch_state_from_api
  unless data
    puts "Error: Server not reachable"
    exit 1
  end
  data
rescue StandardError => e
  puts "Error: #{e.message}"
  exit 1
end

def format_elapsed(seconds)
  return "#{seconds}s" if seconds < 60

  minutes = seconds / 60
  return "#{minutes}m" if minutes < 60

  hours = minutes / 60
  "#{hours}h"
end

state = fetch_state
sessions = state["sessions"] || []

if sessions.empty?
  system("notify-send", "Brainiac", "No active agent sessions")
  exit 0
end

# If only one session, open it directly
if sessions.size == 1
  log_file = sessions[0]["log_file"]
  exec("alacritty", "-e", "tail", "-f", log_file) if log_file
  exit 0
end

# Multiple sessions: use fzf if available, otherwise just open the first one
if system("which fzf > /dev/null 2>&1")
  # Build fzf menu
  options = sessions.map do |s|
    agent = s["agent"]
    elapsed = format_elapsed(s["elapsed_seconds"])

    card_key = s["card_key"]
    context = if card_key.start_with?("discord-")
                "Discord chat"
              elsif card_key.start_with?("card-")
                card_key.split("-")[1]
              else
                card_key
              end

    emoji = AGENTS[agent.downcase] || DEFAULT_EMOJI

    "#{emoji} #{agent}: #{context} (#{elapsed})|#{s["log_file"]}"
  end

  menu_text = options.join("\n")
  selected = `echo "#{menu_text}" | fzf --prompt="Agent Logs: "`.strip

  unless selected.empty?
    log_file = selected.split("|").last
    exec("alacritty", "-e", "tail", "-f", log_file)
  end
else
  # No menu system, just open the first log
  log_file = sessions[0]["log_file"]
  exec("alacritty", "-e", "tail", "-f", log_file) if log_file
end
