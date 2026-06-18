#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time setup: adds ZillaCore deployments module to waybar config
# and repositions the agent session module with more breathing room.

require "json"

WAYBAR_CONFIG = File.expand_path("~/.config/waybar/config.jsonc")
DEPLOY_SCRIPT = File.expand_path("~/Code/zillacore/monitor/waybar-deployments.rb")
WAYBAR_STYLE  = File.expand_path("~/.config/waybar/style.css")

def load_config
  content = File.read(WAYBAR_CONFIG)
  json_content = content.lines.reject { |line| line.strip.start_with?("//") }.join
  JSON.parse(json_content)
end

def save_config(config)
  File.write(WAYBAR_CONFIG, JSON.pretty_generate(config))
end

config = load_config

# Remove any existing deployment module
config["modules-center"]&.reject! { |m| m.to_s.include?("zillacore-deploy") }
config["modules-right"]&.reject! { |m| m.to_s.include?("zillacore-deploy") }
config.delete("custom/zillacore-deployments")

# Move agent session module from modules-right to modules-center (after indicators)
if config["modules-right"]&.delete("custom/zillacore")
  config["modules-center"] ||= []
  config["modules-center"] << "custom/zillacore" unless config["modules-center"].include?("custom/zillacore")
end

# Add deployments module right before agent sessions in modules-center
center = config["modules-center"] || []
zc_idx = center.index("custom/zillacore")
if zc_idx
  center.insert(zc_idx, "custom/zillacore-deployments") unless center.include?("custom/zillacore-deployments")
else
  center << "custom/zillacore-deployments" unless center.include?("custom/zillacore-deployments")
end

# Add module config
config["custom/zillacore-deployments"] = {
  "exec" => DEPLOY_SCRIPT,
  "return-type" => "json",
  "interval" => 30,
  "format" => "{}",
  "tooltip" => true,
  "format-alt" => "{}",
  "escape" => false,
  "on-click" => "#{DEPLOY_SCRIPT} --click",
  "on-click-right" => "#{DEPLOY_SCRIPT} --deploy"
}

save_config(config)

# Add CSS for the deployments module
style = File.read(WAYBAR_STYLE)
unless style.include?("#custom-zillacore-deployments")
  css = <<~CSS

    /* ZillaCore deployment environment dots */
    #custom-zillacore-deployments {
      margin-left: 100px;
      margin-right: 40px;
      font-size: 14px;
    }
  CSS
  File.write(WAYBAR_STYLE, style + css)
  puts "✓ Added deployment styles to waybar CSS"
end

# Add padding-right to agent sessions module
unless style.include?("padding-right") && style.include?("#custom-zillacore")
  updated_style = File.read(WAYBAR_STYLE)
  if updated_style.include?("#custom-zillacore {")
    updated_style.sub!(/(#custom-zillacore\s*\{[^}]*)(\})/) do
      block = Regexp.last_match(1)
      close = Regexp.last_match(2)
      if block.include?("padding-right")
        "#{block}#{close}"
      else
        "#{block}\n  padding-right: 100px;\n#{close}"
      end
    end
    File.write(WAYBAR_STYLE, updated_style)
    puts "✓ Added padding-right to agent session module"
  end
end

puts "✓ Deployments module added to waybar config"
puts "  Positioned: [deploy-dots] [agent-sessions] in center bar"
puts "  Restart waybar to apply: omarchy restart waybar"
