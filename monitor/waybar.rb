#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Waybar Module
# Reads from monitor daemon socket and outputs JSON for waybar
# Single module that updates content dynamically (no config rewrites)

require "json"
require "socket"
require "net/http"

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
  agents
rescue StandardError => e
  warn "Failed to load waybar.json: #{e.message}"
  {}
end

AGENTS = load_agent_config.freeze
DEFAULT_EMOJI = "❓"

def normalize_agent_name(name)
  name.downcase
end

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
  fetch_state_from_api || { "sessions" => [], "count" => 0, "error" => "server not reachable" }
rescue StandardError => e
  { "sessions" => [], "count" => 0, "error" => e.message }
end

def format_elapsed(seconds)
  return "#{seconds}s" if seconds < 60

  minutes = seconds / 60
  return "#{minutes}m" if minutes < 60

  hours = minutes / 60
  "#{hours}h"
end

INFRA_CMDS = %w[kiro-cli-chat ruby-lsp clangd gopls].freeze

def infra_process?(cmd_short)
  INFRA_CMDS.any? { |ic| cmd_short.start_with?(ic) }
end

def escape_pango(str)
  str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
end

def generate_output
  state = fetch_state

  if state["error"]
    return {
      text: "⚠️",
      tooltip: "Brainiac Error: #{escape_pango(state["error"])}",
      class: "error"
    }
  end

  sessions = state["sessions"] || []

  if sessions.empty?
    return {
      text: "💤",
      tooltip: "No active agent sessions",
      class: "idle"
    }
  end

  # Build text: show emoji for each active agent
  text_parts = sessions.map { |s| AGENTS[normalize_agent_name(s["agent"])] || DEFAULT_EMOJI }
  text = text_parts.join(" ")

  # Build tooltip
  tooltip_lines = sessions.map do |s|
    agent_display = s["agent"]
    emoji = AGENTS[normalize_agent_name(agent_display)] || DEFAULT_EMOJI
    elapsed = format_elapsed(s["elapsed_seconds"])

    card_key = s["card_key"]
    context = if card_key.start_with?("discord-")
                "Discord chat"
              elsif card_key.start_with?("card-")
                card_key.split("-")[1]
              else
                card_key
              end

    lines = ["#{emoji} #{agent_display}: #{context} (#{elapsed})"]

    children = (s["children"] || []).reject do |c|
      cmd_short = c["cmd"].to_s.split("/").last.to_s.split.first.to_s
      infra_process?(cmd_short)
    end

    children.each do |c|
      cmd_short = c["cmd"].to_s.split("/").last.to_s.split.first.to_s
      cmd_short = c["cmd"].to_s[0..40] if cmd_short.empty?
      lines << "   └ #{escape_pango(cmd_short)} (#{format_elapsed(c["elapsed_seconds"])}) [PID #{c["pid"]}]"
    end

    lines.join("\n")
  end

  tooltip_lines << "\n[Click to manage]"

  {
    text: text,
    tooltip: tooltip_lines.join("\n"),
    class: "working"
  }
end

puts generate_output.to_json
