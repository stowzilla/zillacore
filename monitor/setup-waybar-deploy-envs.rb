#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time setup: replaces the single brainiac-deployments module
# with per-environment modules so each dot gets its own border/click.

require "json"
require "fileutils"

WAYBAR_CONFIG = File.expand_path("~/.config/waybar/config.jsonc")
DEPLOY_SCRIPT = File.expand_path("~/.brainiac/bin/waybar-deploy-env")
DEPLOYMENTS_CONFIG = File.expand_path("~/.brainiac/deployments.json")
WAYBAR_STYLE = File.expand_path("~/.config/waybar/style.css")

# Create wrapper script that resolves from server.root
wrapper_dir = File.expand_path("~/.brainiac/bin")
FileUtils.mkdir_p(wrapper_dir)
File.write(DEPLOY_SCRIPT, <<~SCRIPT)
  #!/usr/bin/env ruby
  root_file = File.expand_path("~/.brainiac/server.root")
  if File.exist?(root_file)
    server_root = File.read(root_file).strip
    script = File.join(server_root, "monitor", "waybar-deploy-env.rb")
    if File.exist?(script)
      ARGV.unshift if ARGV.empty?
      load script
      exit
    end
  end
  require "json"
  puts({ text: "", tooltip: "Brainiac server root not found", class: "error" }.to_json)
SCRIPT
File.chmod(0o755, DEPLOY_SCRIPT)

def load_config
  content = File.read(WAYBAR_CONFIG)
  json_content = content.lines.reject { |line| line.strip.start_with?("//") }.join
  JSON.parse(json_content)
end

def save_config(config)
  File.write(WAYBAR_CONFIG, JSON.pretty_generate(config))
end

deployments = JSON.parse(File.read(DEPLOYMENTS_CONFIG))
envs = deployments["environments"].keys

config = load_config

# Remove old single deployments module from all bar positions
%w[modules-left modules-center modules-right].each do |pos|
  next unless config[pos]

  config[pos].reject! { |m| m.to_s.include?("brainiac-deploy") }
end
config.delete("custom/brainiac-deployments")

# Remove any existing per-env modules
config.each_key do |key|
  config.delete(key) if key.start_with?("custom/brainiac-deploy-")
end

# Insert per-env modules into modules-center, before custom/brainiac
center = config["modules-center"] || []
zc_idx = center.index("custom/brainiac") || center.length
envs.each_with_index do |env, i|
  mod_name = "custom/brainiac-deploy-#{env}"
  center.insert(zc_idx + i, mod_name) unless center.include?(mod_name)
end
config["modules-center"] = center

# Add module configs for each env
envs.each do |env|
  mod_name = "custom/brainiac-deploy-#{env}"
  config[mod_name] = {
    "exec" => "#{DEPLOY_SCRIPT} #{env}",
    "return-type" => "json",
    "interval" => 30,
    "format" => "{}",
    "tooltip" => true,
    "escape" => false,
    "on-click" => "#{DEPLOY_SCRIPT} #{env} --click",
    "on-click-right" => "#{DEPLOY_SCRIPT} #{env} --deploy"
  }
end

save_config(config)
puts "✓ Added per-environment deploy modules: #{envs.map { |e| "custom/brainiac-deploy-#{e}" }.join(", ")}"

# Update CSS — remove old single-module styles, add per-env styles
style = File.read(WAYBAR_STYLE)

# Remove old block
style.gsub!(%r{/\* Brainiac deployment environment dots \*/.*?(?=\n\n|\n/\*|\z)}m, "")
style.gsub!(/\n*#custom-brainiac-deployments[^{]*\{[^}]*\}\n*/m, "")

# Add new per-env styles
unless style.include?("#custom-brainiac-deploy-")
  css = <<~CSS

    /* Brainiac per-environment deploy dots */
    [id^="custom-brainiac-deploy-"] {
      font-size: 28px;
      padding: 0 6px;
      border-radius: 8px;
      border: 2px solid transparent;
    }

    [id^="custom-brainiac-deploy-"].deploy-recent {
      border: 2px solid #4488ff;
    }

    [id^="custom-brainiac-deploy-"].deploy-failed {
      border: 2px solid #ff4444;
    }
  CSS
  File.write(WAYBAR_STYLE, "#{style.strip}\n#{css}")
  puts "✓ Updated waybar CSS with per-environment border styles"
end

puts "✓ Restart waybar to apply: omarchy restart waybar"
