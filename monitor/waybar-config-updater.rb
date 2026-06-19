#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Waybar Config Updater
# Dynamically updates waybar config with per-agent modules

require "json"

WAYBAR_CONFIG = File.expand_path("~/.config/waybar/config.jsonc")
WAYBAR_SCRIPT = File.expand_path("~/Code/brainiac/monitor/waybar.rb")

def load_config
  content = File.read(WAYBAR_CONFIG)
  # Strip comments for JSON parsing
  json_content = content.lines.reject { |line| line.strip.start_with?("//") }.join
  JSON.parse(json_content)
end

def save_config(config)
  File.write(WAYBAR_CONFIG, JSON.pretty_generate(config))
end

def brainiac_modules
  output = `#{WAYBAR_SCRIPT} --config`
  JSON.parse(output)
end

# Load current config
config = load_config

# Get dynamic Brainiac modules
brainiac_data = brainiac_modules
modules = brainiac_data["modules"]
module_configs = brainiac_data["config"]

# Remove old brainiac modules and groups from modules-right
config["modules-right"].reject! { |m| m.to_s.start_with?("custom/brainiac") || m.to_s == "group/brainiac-agents" }

# Insert new modules at the beginning of modules-right
config["modules-right"] = modules + config["modules-right"]

# Remove old brainiac module configs and groups
config.each_key do |key|
  config.delete(key) if key.to_s.start_with?("custom/brainiac") || key.to_s == "group/brainiac-agents"
end

# Add new module configs
module_configs.each do |name, cfg|
  config[name] = cfg
end

# Save updated config
save_config(config)

# Reload waybar
system("killall", "-SIGUSR2", "waybar")
