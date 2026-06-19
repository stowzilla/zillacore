#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac macOS Log Viewer
# Opens agent log files in a terminal (wezterm by default, configurable via waybar.json)
# Set "log_viewer_command" in ~/.brainiac/waybar.json to override (supports wezterm/iTerm/Terminal.app)
# Uses macOS notifications via osascript for status messages

require "json"
require "socket"

SOCKET_PATH = "/tmp/brainiac-monitor.sock"
CONFIG_PATH = File.expand_path("~/.brainiac/waybar.json")

# Load agent configuration from JSON
# Returns [agents_hash, default_emoji] tuple
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

# Read agent state from daemon socket
# Returns hash with sessions/count/last_update, or error hash if daemon unavailable
def fetch_state
  socket = UNIXSocket.new(SOCKET_PATH)
  data = socket.read
  socket.close
  JSON.parse(data)
rescue Errno::ENOENT
  { "sessions" => [], "count" => 0, "error" => "daemon not running" }
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

# Send a macOS notification via osascript
# Silently fails if osascript is unavailable
def notify(title, message)
  escaped_title = title.gsub('"', '\\"')
  escaped_message = message.gsub('"', '\\"')
  system("osascript", "-e", "display notification \"#{escaped_message}\" with title \"#{escaped_title}\"")
rescue StandardError => e
  warn "Notification failed: #{e.message}"
end

def format_context(card_key)
  if card_key.start_with?("discord-")
    "Discord chat"
  elsif card_key.start_with?("card-")
    card_key.split("-")[1]
  else
    card_key
  end
end

def load_log_viewer_command
  config = JSON.parse(File.read(CONFIG_PATH))
  config["log_viewer_command"]
rescue StandardError
  nil
end

DEFAULT_LOG_VIEWER = "/opt/homebrew/bin/wezterm"
LOG_VIEWER_COMMAND = load_log_viewer_command || DEFAULT_LOG_VIEWER

# Find an existing wezterm pane that's already tailing the given log file
def find_wezterm_pane_for(log_file)
  json = `#{LOG_VIEWER_COMMAND} cli list --format json 2>/dev/null`
  panes = JSON.parse(json)
  panes.find { |p| p["title"]&.include?(log_file) || p["cwd"]&.include?(log_file) }
rescue StandardError
  nil
end

# Get the window ID of the first wezterm window
def find_wezterm_window_id
  json = `#{LOG_VIEWER_COMMAND} cli list --format json 2>/dev/null`
  panes = JSON.parse(json)
  panes.first&.dig("window_id")
rescue StandardError
  nil
end

def open_log(log_file)
  escaped_path = log_file.gsub("'", "'\\\\''")

  if LOG_VIEWER_COMMAND.include?("wezterm")
    wezterm_running = system("pgrep -qf WezTerm")
    if wezterm_running
      # Check if this log is already being tailed in an existing tab
      existing_pane = find_wezterm_pane_for(log_file)
      if existing_pane
        system(LOG_VIEWER_COMMAND, "cli", "activate-pane", "--pane-id", existing_pane["pane_id"].to_s)
      else
        # Spawn as a new tab in the first available window
        window_id = find_wezterm_window_id
        args = [LOG_VIEWER_COMMAND, "cli", "spawn"]
        args += ["--window-id", window_id.to_s] if window_id
        args += ["--", "tail", "-f", log_file]
        system(*args)
      end
    else
      system(LOG_VIEWER_COMMAND, "start", "--", "tail", "-f", log_file)
      sleep 0.5 # Give wezterm time to launch before trying to activate
    end
    system("open", "-a", "WezTerm")
    system("osascript", "-e", 'tell application "System Events" to set frontmost of process "WezTerm" to true')
  elsif LOG_VIEWER_COMMAND.include?("iTerm")
    script = <<~APPLESCRIPT
      tell application "iTerm"
        activate
        create window with default profile command "tail -f '#{escaped_path}'"
      end tell
    APPLESCRIPT
    system("osascript", "-e", script)
  elsif LOG_VIEWER_COMMAND.include?("Terminal")
    system("osascript", "-e", "tell application \"Terminal\" to do script \"tail -f '#{escaped_path}'\"")
    system("osascript", "-e", 'tell application "Terminal" to activate')
  else
    system(LOG_VIEWER_COMMAND, "tail", "-f", log_file)
  end
end

# --- Main invocation logic ---

# Mode 1: xbar submenu click — log file path passed as param1 (ARGV[0])
if ARGV[0]
  log_file = ARGV[0]
  unless File.exist?(log_file)
    notify("Brainiac", "Log file not found: #{log_file}")
    exit 1
  end
  open_log(log_file)
  exit 0
end

# Mode 2+: standalone invocation — fetch state from daemon
state = fetch_state
sessions = state["sessions"] || []

if state["error"]
  notify("Brainiac", state["error"])
  exit 1
end

if sessions.empty?
  notify("Brainiac", "No active agent sessions")
  exit 0
end

# Single session — open directly
if sessions.size == 1
  log_file = sessions[0]["log_file"]
  if log_file && File.exist?(log_file)
    open_log(log_file)
  else
    notify("Brainiac", "Log file not found: #{log_file}")
  end
  exit 0
end

# Multiple sessions — use fzf if available
if system("which fzf > /dev/null 2>&1")
  options = sessions.map do |s|
    agent = s["agent"]
    elapsed = format_elapsed(s["elapsed_seconds"])
    context = format_context(s["card_key"])
    emoji = AGENTS[agent.downcase] || DEFAULT_EMOJI
    "#{emoji} #{agent}: #{context} (#{elapsed})|#{s["log_file"]}"
  end

  menu_text = options.join("\n")
  selected = `echo "#{menu_text}" | fzf --prompt="Agent Logs: "`.strip

  unless selected.empty?
    log_file = selected.split("|").last
    if File.exist?(log_file)
      open_log(log_file)
    else
      notify("Brainiac", "Log file not found: #{log_file}")
    end
  end
else
  # No fzf — open first session's log
  log_file = sessions[0]["log_file"]
  if log_file && File.exist?(log_file)
    open_log(log_file)
  else
    notify("Brainiac", "Log file not found: #{log_file}")
  end
end
