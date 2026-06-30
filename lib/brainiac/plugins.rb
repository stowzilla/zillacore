# frozen_string_literal: true

# Plugin system for Brainiac.
#
# Plugins are distributed as gems named `brainiac-<name>` (e.g. brainiac-whatsapp).
# Each gem exposes a module at `Brainiac::Plugins::<Name>` that responds to `.register(app)`
# where `app` is the Sinatra application instance.
#
# Installed plugins are tracked in ~/.brainiac/plugins.json so the receiver
# knows which gems to require at startup.

PLUGINS_FILE = File.join(BRAINIAC_DIR, "plugins.json")

def load_plugins_config
  return { "plugins" => [] } unless File.exist?(PLUGINS_FILE)

  JSON.parse(File.read(PLUGINS_FILE))
rescue JSON::ParserError => e
  LOG.error "Failed to parse plugins.json: #{e.message}"
  { "plugins" => [] }
end

def save_plugins_config(config)
  FileUtils.mkdir_p(BRAINIAC_DIR)
  File.write(PLUGINS_FILE, JSON.pretty_generate(config))
end

PLUGINS_CONFIG = load_plugins_config

# Returns the list of installed plugin names (e.g. ["whatsapp", "slack"])
def installed_plugins
  (PLUGINS_CONFIG["plugins"] || []).map { |p| p.is_a?(Hash) ? p["name"] : p.to_s }
end

# Load all installed plugin gems and call their register hooks.
# Called once during server startup, after core handlers are loaded.
def load_plugins!(app)
  installed_plugins.each do |name|
    gem_name = "brainiac-#{name}"
    begin
      require gem_name
      plugin_module = resolve_plugin_module(name)
      if plugin_module.respond_to?(:register)
        plugin_module.register(app)
        LOG.info "[Plugins] Loaded #{gem_name}"
      else
        LOG.warn "[Plugins] #{gem_name} loaded but no register method found"
      end
    rescue LoadError => e
      LOG.error "[Plugins] Could not load #{gem_name}: #{e.message}"
      LOG.error "[Plugins]   Is the gem installed? Run: gem install #{gem_name}"
    rescue StandardError => e
      LOG.error "[Plugins] Error registering #{gem_name}: #{e.message}"
      LOG.error "[Plugins]   #{e.backtrace.first(3).join("\n  ")}"
    end
  end
end

# Resolve the plugin module for a given name.
# Tries Brainiac::Plugins::Whatsapp, Brainiac::Plugins::WhatsApp, etc.
def resolve_plugin_module(name)
  return nil unless defined?(Brainiac::Plugins)

  # Try PascalCase (e.g. "whatsapp" -> "Whatsapp", "test-widget" -> "TestWidget")
  pascal = name.split(/[-_]/).map(&:capitalize).join
  return Brainiac::Plugins.const_get(pascal) if Brainiac::Plugins.const_defined?(pascal)

  # Try case-insensitive match (e.g. "WhatsApp" if the gem defines it that way)
  Brainiac::Plugins.constants.each do |const|
    return Brainiac::Plugins.const_get(const) if const.to_s.downcase == name.downcase
  end

  nil
end

# Install a plugin gem and register it in plugins.json.
# rubocop:disable Naming/PredicateMethod
def install_plugin(name, version: nil)
  gem_name = "brainiac-#{name}"

  if installed_plugins.include?(name)
    puts "Plugin '#{name}' is already installed."
    return false
  end

  puts "Installing #{gem_name}..."
  install_cmd = ["gem", "install", gem_name]
  install_cmd.push("--version", version) if version

  stdout, stderr, status = Open3.capture3(*install_cmd)
  unless status.success?
    puts "Failed to install #{gem_name}:"
    puts stderr.empty? ? stdout : stderr
    return false
  end
  puts stdout unless stdout.strip.empty?

  config = load_plugins_config
  config["plugins"] ||= []
  entry = { "name" => name, "gem" => gem_name, "installed_at" => Time.now.iso8601 }
  entry["version"] = version if version
  config["plugins"] << entry
  save_plugins_config(config)

  puts "✓ Installed plugin '#{name}' (#{gem_name})"
  puts "  Restart the server to activate: brainiac restart"
  true
end

# Uninstall a plugin gem and remove from plugins.json
def uninstall_plugin(name)
  gem_name = "brainiac-#{name}"

  unless installed_plugins.include?(name)
    puts "Plugin '#{name}' is not installed."
    return false
  end

  config = load_plugins_config
  config["plugins"].reject! { |p| (p.is_a?(Hash) ? p["name"] : p.to_s) == name }
  save_plugins_config(config)

  puts "Removed plugin '#{name}' from Brainiac."
  puts "  The gem #{gem_name} is still installed system-wide."
  puts "  To fully remove: gem uninstall #{gem_name}"
  puts "  Restart the server to apply: brainiac restart"
  true
end
# rubocop:enable Naming/PredicateMethod
