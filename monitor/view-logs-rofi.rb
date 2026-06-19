#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Log Viewer (Rofi version)
# Shows a rofi menu to select which agent log to tail
# Non-blocking, safe for waybar on-click

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
    system("notify-send", "Brainiac", "Server not reachable")
    exit 1
  end
  data
rescue StandardError => e
  system("notify-send", "Brainiac Error", e.message)
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

INFRA_CMDS = %w[kiro-cli-chat ruby-lsp clangd gopls].freeze

# Build menu entries: sessions + their child processes
entries = []
sessions.each do |s|
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
  entries << { display: "#{emoji} #{agent}: #{context} (#{elapsed})", type: :log, log: s["log_file"] }
  entries << { display: "   ⛔ Kill session: #{agent} (#{context})", type: :kill_session, card_key: card_key, agent: agent }

  (s["children"] || []).each do |c|
    cmd_short = c["cmd"].to_s.split("/").last.to_s.split.first.to_s
    cmd_short = c["cmd"].to_s[0..40] if cmd_short.empty?
    next if INFRA_CMDS.any? { |ic| cmd_short.start_with?(ic) }

    entries << {
      display: "   └ 🔪 Kill: #{cmd_short} (#{format_elapsed(c["elapsed_seconds"])}) [PID #{c["pid"]}]",
      type: :kill_child, pid: c["pid"], cmd: cmd_short
    }
  end
end

# If only one session with no children, open log directly
if entries.size == 1 && entries[0][:type] == :log
  spawn("alacritty", "-e", "tail", "-f", entries[0][:log]) if entries[0][:log]
  exit 0
end

def find_launcher
  %w[rofi fuzzel wofi zenity].find { |cmd| system("which #{cmd} > /dev/null 2>&1") }
end

def run_menu(launcher, entries)
  menu_text = entries.map { |e| e[:display] }.join("\n")
  case launcher
  when "rofi"
    IO.popen(%w[rofi -dmenu -i -p] + ["Agent Sessions"], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "fuzzel"
    IO.popen(%w[fuzzel --dmenu --prompt] + ["Agent Sessions: "], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "wofi"
    IO.popen(%w[wofi --dmenu --prompt] + ["Agent Sessions"], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "zenity"
    IO.popen(["zenity", "--list", "--title", "Agent Sessions", "--column", "Session", "--width", "600", "--height", "400"], "r+",
             err: "/dev/null") do |io|
      entries.each { |e| io.puts e[:display] }
      io.close_write
      io.read.strip
    end
  end
end

launcher = find_launcher
unless launcher
  system("notify-send", "Brainiac", "No menu launcher found (install rofi, fuzzel, wofi, or zenity)")
  exit 1
end

selected_line = run_menu(launcher, entries)

unless selected_line.to_s.empty?
  selected = entries.find { |e| e[:display].strip == selected_line.strip }
  if selected
    case selected[:type]
    when :log
      spawn("alacritty", "-e", "tail", "-f", selected[:log]) if selected[:log]
    when :kill_session
      card_key = selected[:card_key]
      uri = URI("http://localhost:4567/api/sessions/kill/#{card_key}")
      response = Net::HTTP.post(uri, "", { "Content-Type" => "application/json" })
      if response.is_a?(Net::HTTPSuccess)
        system("notify-send", "Brainiac", "Killed session: #{selected[:agent]}")
      else
        system("notify-send", "Brainiac", "Failed to kill session: #{selected[:agent]}")
      end
    when :kill_child
      pid = selected[:pid]
      begin
        Process.kill("TERM", pid)
      rescue StandardError
        nil
      end
      Thread.new do
        sleep 3
        begin
          Process.kill("KILL", pid)
        rescue StandardError
          nil
        end
      end
      system("notify-send", "Brainiac", "Killed #{selected[:cmd]} (PID #{pid})")
    end
  end
end
