#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time setup script to add Brainiac module to waybar config
# Run this once, then the module will update dynamically without config rewrites

require "json"
require "fileutils"

WAYBAR_CONFIG = File.expand_path("~/.config/waybar/config.jsonc")
WAYBAR_SCRIPT = File.expand_path("~/.brainiac/bin/waybar-status")

# Create a wrapper script that resolves the running server's waybar.rb dynamically
wrapper_dir = File.expand_path("~/.brainiac/bin")
FileUtils.mkdir_p(wrapper_dir)
wrapper_path = File.join(wrapper_dir, "waybar-status")
File.write(wrapper_path, <<~SCRIPT)
  #!/usr/bin/env ruby
  # Resolves the running Brainiac server's waybar module dynamically.
  # This allows worktrees / branches to work without reconfiguring waybar.

  root_file = File.expand_path("~/.brainiac/server.root")
  if File.exist?(root_file)
    server_root = File.read(root_file).strip
    waybar_script = File.join(server_root, "monitor", "waybar.rb")
    if File.exist?(waybar_script)
      load waybar_script
      exit
    end
  end

  # Fallback: no server root known, try the API directly
  require "json"
  require "net/http"

  begin
    uri = URI("http://localhost:4567/api/status")
    response = Net::HTTP.get_response(uri)
    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      sessions = data["sessions"] || []
      if sessions.empty?
        puts({ text: "💤", tooltip: "No active agent sessions", class: "idle" }.to_json)
      else
        puts({ text: "🟢 \#{sessions.size}", tooltip: sessions.map { |s| s["agent"] }.join(", "), class: "working" }.to_json)
      end
    else
      puts({ text: "⚠️", tooltip: "Brainiac Error: HTTP \#{response.code}", class: "error" }.to_json)
    end
  rescue StandardError => e
    puts({ text: "⚠️", tooltip: "Brainiac Error: \#{e.message}", class: "error" }.to_json)
  end
SCRIPT
File.chmod(0o755, wrapper_path)

def load_config
  content = File.read(WAYBAR_CONFIG)
  # Strip comments for JSON parsing
  json_content = content.lines.reject { |line| line.strip.start_with?("//") }.join
  JSON.parse(json_content)
end

def save_config(config)
  File.write(WAYBAR_CONFIG, JSON.pretty_generate(config))
end

# Load current config
config = load_config

# Remove old brainiac modules if they exist (from all module arrays)
%w[modules-left modules-center modules-right].each do |section|
  next unless config[section].is_a?(Array)

  config[section].reject! { |m| ["custom/brainiac", "group/brainiac-agents"].include?(m.to_s) }
end
config.each_key do |key|
  config.delete(key) if ["custom/brainiac", "group/brainiac-agents"].include?(key.to_s)
end

# Add single dynamic module at the end of modules-center (after deploy envs)
config["modules-center"] ||= []
config["modules-center"].push("custom/brainiac")

# Add module config
config["custom/brainiac"] = {
  "exec" => WAYBAR_SCRIPT,
  "return-type" => "json",
  "interval" => 3,
  "format" => "{}",
  "tooltip" => true,
  "on-click" => File.expand_path("~/.brainiac/bin/waybar-logs").to_s
}

# Create on-click wrapper too
logs_wrapper = File.expand_path("~/.brainiac/bin/waybar-logs")
File.write(logs_wrapper, <<~SCRIPT)
  #!/usr/bin/env ruby
  root_file = File.expand_path("~/.brainiac/server.root")
  if File.exist?(root_file)
    server_root = File.read(root_file).strip
    script = File.join(server_root, "monitor", "view-logs-rofi.rb")
    exec("ruby", script) if File.exist?(script)
  end
  warn "Brainiac server root not found"
SCRIPT
File.chmod(0o755, logs_wrapper)

# Save updated config
save_config(config)

puts "✓ Brainiac module added to waybar config"
puts "  Module will update every 3 seconds without config rewrites"
puts "  Restart waybar to apply: omarchy restart waybar"
