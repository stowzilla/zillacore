#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac macOS Menu Bar Plugin (xbar/SwiftBar)
# Reads from monitor daemon socket and outputs xbar-format text
# Mirrors monitor/waybar.rb patterns for macOS-native display

require "json"
require "net/http"
require "shellwords"
require "socket"
require "time"
require "uri"

SERVER_URL = "http://localhost:4567"
SOCKET_PATH = "/tmp/brainiac-monitor.sock"
CONFIG_PATH = File.expand_path("~/.brainiac/waybar.json")
DEFAULT_EMOJI = "❓"
SELF_PATH = File.realpath(__FILE__)

def load_config
  JSON.parse(File.read(CONFIG_PATH))
rescue StandardError => e
  warn "Failed to load waybar.json: #{e.message}"
  {}
end

CONFIG = load_config.freeze

def load_agent_config
  agents = {}
  (CONFIG["agents"] || []).each do |agent|
    agents[agent["name"].downcase] = { emoji: agent["emoji"], color: agent["color"] }
  end
  agents
end

AGENTS = load_agent_config.freeze
FIZZY_ACCOUNT_ID = CONFIG["fizzy_account_id"]
DISCORD_GUILD_ID = CONFIG["discord_guild_id"]

def fetch_state
  socket = UNIXSocket.new(SOCKET_PATH)
  data = socket.read
  socket.close
  JSON.parse(data)
rescue Errno::ENOENT
  { "sessions" => [], "count" => 0, "recent" => [], "error" => "daemon not running" }
rescue StandardError => e
  { "sessions" => [], "count" => 0, "recent" => [], "error" => e.message }
end

def fetch_deployments
  uri = URI("#{SERVER_URL}/api/deployments")
  response = Net::HTTP.get_response(uri)
  JSON.parse(response.body)["deployments"] || []
rescue StandardError
  nil
end

DEPLOY_RECENT_WINDOW = 30 * 60

def deploy_dot(dep)
  status = dep["last_deploy_status"]
  if status == "deploying"
    "🟠"
  elsif status == "failed"
    "💥"
  elsif dep["status"] == "occupied"
    deploy_time = dep["last_deploy_at"] || dep["deployed_at"]
    recent = deploy_time && (Time.now - Time.parse(deploy_time)) < DEPLOY_RECENT_WINDOW
    recent ? "🚀" : "🔴"
  else
    "🟢"
  end
end

LOG_VIEWER_PATH = File.join(File.dirname(SELF_PATH), "view-logs-macos.rb")
DEPLOY_SCRIPT_PATH = File.join(File.dirname(SELF_PATH), "deploy-env-macos.rb")

ANSI_REGEX = /\e\[[0-9;]*[a-zA-Z]|\e\[\?[0-9;]*[a-zA-Z]/
LOG_PREVIEW_LINES = 15
LOG_LINE_MAX = 80
LOG_FONT = "SFMono-Regular"
LOG_SIZE = 12

def tail_log(log_file, lines: LOG_PREVIEW_LINES)
  return [] unless log_file && File.exist?(log_file)

  raw = `tail -n 50 #{log_file.shellescape} 2>/dev/null`
  raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
     .lines
     .map { |l| l.gsub(ANSI_REGEX, "").gsub(/[^[:print:]\t]/, "").strip }
     .reject(&:empty?)
     .last(lines)
rescue StandardError
  []
end

def format_log_line(text)
  text.length > LOG_LINE_MAX ? "#{text[0, LOG_LINE_MAX]}…" : text
end

def format_elapsed(seconds)
  return "#{seconds}s" if seconds < 60

  minutes = seconds / 60
  return "#{minutes}m" if minutes < 60

  "#{minutes / 60}h"
end

def format_context(card_key)
  return "" unless card_key

  if card_key.start_with?("discord-")
    "Discord"
  elsif card_key.start_with?("card-")
    "##{card_key.split("-")[1]}"
  else
    card_key
  end
end

def time_ago(iso_string)
  return nil unless iso_string

  seconds = (Time.now - Time.parse(iso_string)).to_i
  "#{format_elapsed(seconds)} ago"
rescue StandardError
  nil
end

def log_action(log_file)
  return "" unless log_file

  " | shell=#{LOG_VIEWER_PATH} param1=#{log_file} terminal=false refresh=false"
end

OPEN_SCRIPT = File.join(File.dirname(SELF_PATH), "open-action.sh")

def full_log_action(log_file)
  return "" unless log_file

  " | shell=#{OPEN_SCRIPT} param1=#{log_file.shellescape} terminal=false refresh=false"
end

def prompt_url(card_key)
  return nil unless card_key

  if card_key.start_with?("card-")
    card_num = card_key.split("-")[1]
    "https://app.fizzy.do/#{FIZZY_ACCOUNT_ID}/cards/#{card_num}" if FIZZY_ACCOUNT_ID && card_num
  elsif card_key.start_with?("discord-") && DISCORD_GUILD_ID
    parts = card_key.split("-")
    # discord-AGENT-CHANNEL_ID-MESSAGE_ID (agent name may contain hyphens, IDs are last two numeric parts)
    channel_id = parts[-2]
    message_id = parts[-1]
    "https://discord.com/channels/#{DISCORD_GUILD_ID}/#{channel_id}/#{message_id}" if channel_id && message_id
  end
end

def prompt_action(card_key)
  url = prompt_url(card_key)
  return "" unless url

  " | shell=#{OPEN_SCRIPT} param1=#{url} terminal=false refresh=false"
end

def worktree_path(log_file, card_key)
  return nil unless log_file && card_key&.start_with?("card-")

  dir = File.dirname(log_file, 2)
  dir if File.directory?(dir) && dir != "/"
end

def worktree_action(log_file, card_key)
  path = worktree_path(log_file, card_key)
  return "" unless path

  " | shell=#{OPEN_SCRIPT} param1=#{path.shellescape} terminal=false refresh=false"
end

COLOR_MAP = {
  "red" => "#ff5555", "green" => "#50fa7b", "blue" => "#8be9fd",
  "yellow" => "#f1fa8c", "cyan" => "#8be9fd", "magenta" => "#ff79c6",
  "purple" => "#bd93f9", "pink" => "#ff79c6", "white" => "#f8f8f2"
}.freeze

def hex_color(name)
  COLOR_MAP[name] || name
end

def generate_output
  state = fetch_state
  deployments = fetch_deployments

  return ["⚠️", "---", state["error"], "---", "Refresh | refresh=true"].join("\n") if state["error"] && !deployments

  sessions = state["sessions"] || []
  recent = state["recent"] || []
  lines = []

  # Title line — agent emojis + deploy dots
  parts = []
  parts << sessions.map { |s| AGENTS.dig(s["agent"]&.downcase, :emoji) || DEFAULT_EMOJI }.join(" ") if sessions.any?
  parts << deployments.map { |d| deploy_dot(d) }.join if deployments&.any?
  title = parts.any? ? parts.join(" ") : "💤"
  lines << title
  lines << "---"

  # Active sessions
  if sessions.any?
    lines << "Active | size=12"
    sessions.each do |s|
      agent_key = (s["agent"] || "").downcase
      emoji = AGENTS.dig(agent_key, :emoji) || DEFAULT_EMOJI
      color = AGENTS.dig(agent_key, :color)
      color_str = color ? " color=#{hex_color(color)}" : ""
      context = format_context(s["card_key"])
      elapsed = format_elapsed(s["elapsed_seconds"] || 0)
      lines << "#{emoji} #{s["agent"]}: #{context} (#{elapsed}) |#{color_str}"

      tail_log(s["log_file"]).each do |line|
        lines << "-- #{format_log_line(line)} | font=#{LOG_FONT} size=#{LOG_SIZE}"
      end
      lines << "-- ---" if s["log_file"]
      lines << "-- Tail Log#{log_action(s["log_file"])}" if s["log_file"]
      lines << "-- View Full Log#{full_log_action(s["log_file"])}" if s["log_file"]
      lines << "-- Open Prompt#{prompt_action(s["card_key"])}" unless prompt_url(s["card_key"]).nil?
      wt = worktree_path(s["log_file"], s["card_key"])
      lines << "-- Open Worktree#{worktree_action(s["log_file"], s["card_key"])}" if wt
    end
  else
    lines << "No active sessions | size=12"
  end

  # Recent completed sessions
  if recent.any?
    lines << "---"
    lines << "Recent | size=12"
    recent.each do |s|
      agent_key = (s["agent"] || "").downcase
      emoji = AGENTS.dig(agent_key, :emoji) || DEFAULT_EMOJI
      context = format_context(s["card_key"])
      ago = time_ago(s["finished_at"]) || "?"
      lines << "#{emoji} #{s["agent"]}: #{context} — #{ago}"

      tail_log(s["log_file"]).each do |line|
        lines << "-- #{format_log_line(line)} | font=#{LOG_FONT} size=#{LOG_SIZE}"
      end
      lines << "-- ---" if s["log_file"]
      lines << "-- Tail Log#{log_action(s["log_file"])}" if s["log_file"]
      lines << "-- View Full Log#{full_log_action(s["log_file"])}" if s["log_file"]
      lines << "-- Open Prompt#{prompt_action(s["card_key"])}" unless prompt_url(s["card_key"]).nil?
      wt = worktree_path(s["log_file"], s["card_key"])
      lines << "-- Open Worktree#{worktree_action(s["log_file"], s["card_key"])}" if wt
    end
  end

  # Deployments
  if deployments&.any?
    lines << "---"
    lines << "Deployments | size=12"
    deployments.each do |d|
      label = d["label"] || d["env"]
      env = d["env"]
      dot = deploy_dot(d)
      if d["status"] == "occupied"
        card = d["card_number"] ? "##{d["card_number"]}" : d["branch"] || "unknown"
        ago = time_ago(d["deployed_at"])
        status_label = case d["last_deploy_status"]
                       when "deploying" then " — deploying…"
                       when "failed" then " — FAILED"
                       else ""
                       end
        line = "#{dot} #{label}: #{card}#{status_label}#{" (#{ago})" if ago}"
        url = d["url"]
        lines << (url ? "#{line} | href=#{url}" : line)
      else
        ago = time_ago(d["cleared_at"])
        last = d["last_card"] ? " (was ##{d["last_card"]})" : ""
        lines << "#{dot} #{label}: Available#{" #{ago}" if ago}#{last}"
      end
      lines << "-- Deploy to #{label} | shell=#{DEPLOY_SCRIPT_PATH} param1=#{env} terminal=false refresh=true"
      lines << "-- Open #{label} | shell=#{OPEN_SCRIPT} param1=#{d["url"]} terminal=false refresh=false" if d["status"] == "occupied" && d["url"]
    end
  end

  lines << "---"
  lines << "Refresh | refresh=true"
  lines.join("\n")
end

puts generate_output
