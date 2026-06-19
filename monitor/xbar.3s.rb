#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac xbar Plugin (macOS menu bar)
# Reads from monitor daemon socket and outputs xbar-formatted text
# Filename encodes refresh interval: xbar.3s.rb = every 3 seconds
#
# <xbar.title>Brainiac Agent Monitor</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>Brainiac</xbar.author>
# <xbar.desc>Shows active AI agent sessions in the macOS menu bar</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>

require "json"
require "shellwords"
require "socket"

SOCKET_PATH = "/tmp/brainiac-monitor.sock"
CONFIG_PATH = File.expand_path("~/.brainiac/waybar.json")

def load_agent_config
  config = JSON.parse(File.read(CONFIG_PATH))
  agents = {}
  config["agents"].each do |agent|
    agents[agent["name"].downcase] = { emoji: agent["emoji"], color: agent["color"] }
  end
  [agents, config["default_emoji"] || "❓"]
rescue StandardError
  [{}, "❓"]
end

AGENTS, DEFAULT_EMOJI = load_agent_config

COLOR_MAP = {
  "red" => "#ff5555", "green" => "#50fa7b", "blue" => "#8be9fd",
  "yellow" => "#f1fa8c", "cyan" => "#8be9fd", "magenta" => "#ff79c6",
  "purple" => "#bd93f9", "pink" => "#ff79c6", "white" => "#f8f8f2"
}.freeze

def hex_color(name)
  COLOR_MAP[name] || name
end

def fetch_state
  socket = UNIXSocket.new(SOCKET_PATH)
  data = socket.read
  socket.close
  JSON.parse(data)
rescue Errno::ENOENT
  { "error" => "daemon not running" }
rescue StandardError => e
  { "error" => e.message }
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

state = fetch_state

if state["error"]
  puts "⚠️ | color=red"
  puts "---"
  puts "Brainiac: #{state["error"]} | color=red"
  exit
end

sessions = state["sessions"] || []
recent = state["recent"] || []
view_logs_script = File.join(__dir__, "view-logs-macos.rb")

# Menu bar title
if sessions.any?
  puts sessions.map { |s| AGENTS.dig(s["agent"]&.downcase, :emoji) || DEFAULT_EMOJI }.join(" ")
else
  puts "💤"
end

puts "---"

# Active sessions
if sessions.any?
  puts "Active | size=12"
  sessions.each do |s|
    agent = s["agent"] || "Unknown"
    info = AGENTS[agent.downcase] || {}
    emoji = info[:emoji] || DEFAULT_EMOJI
    color = info[:color] ? " | color=#{hex_color(info[:color])}" : ""
    elapsed = format_elapsed(s["elapsed_seconds"] || 0)
    context = format_context(s["card_key"])

    puts "#{emoji} #{agent}: #{context} (#{elapsed})#{color}"

    log_lines = tail_log(s["log_file"])
    if log_lines.any?
      log_lines.each do |line|
        puts "-- #{format_log_line(line)} | font=#{LOG_FONT} size=#{LOG_SIZE}"
      end
      puts "-- ---"
    end

    puts "-- Open Full Log | shell=#{view_logs_script} param1=#{s["log_file"]} terminal=false refresh=false" if s["log_file"]
  end
else
  puts "No active sessions | size=12"
end

# Recent completed sessions
if recent.any?
  puts "---"
  puts "Recent | size=12"
  recent.each do |s|
    agent = s["agent"] || "Unknown"
    emoji = AGENTS.dig(agent.downcase, :emoji) || DEFAULT_EMOJI
    context = format_context(s["card_key"])
    ago = time_ago(s["finished_at"]) || "?"

    puts "#{emoji} #{agent}: #{context} — #{ago}"

    log_lines = tail_log(s["log_file"])
    if log_lines.any?
      log_lines.each do |line|
        puts "-- #{format_log_line(line)} | font=#{LOG_FONT} size=#{LOG_SIZE}"
      end
      puts "-- ---"
    end

    puts "-- Open Full Log | shell=#{view_logs_script} param1=#{s["log_file"]} terminal=false refresh=false" if s["log_file"]
  end
end
