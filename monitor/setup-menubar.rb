#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time setup script to install Brainiac menubar plugin into xbar or SwiftBar
# Run this once — the plugin will then auto-refresh on its configured interval

PLUGIN_APPS = [
  {
    name: "SwiftBar",
    plugin_dir: File.expand_path("~/Library/Application Support/SwiftBar/Plugins"),
    app_path: "/Applications/SwiftBar.app"
  },
  {
    name: "xbar",
    plugin_dir: File.expand_path("~/Library/Application Support/xbar/plugins"),
    app_path: "/Applications/xbar.app"
  }
].freeze

SYMLINK_NAME = "brainiac.2s.rb"
SOURCE_PATH = File.join(File.dirname(File.expand_path(__FILE__)), "menubar.rb")

def detect_plugin_app
  PLUGIN_APPS.each do |app|
    return { name: app[:name], plugin_dir: app[:plugin_dir] } if Dir.exist?(app[:plugin_dir]) || File.exist?(app[:app_path])
  end
  nil
end

def install_plugin(plugin_dir, source_path)
  FileUtils.mkdir_p(plugin_dir)
  link_path = File.join(plugin_dir, SYMLINK_NAME)

  # Remove existing symlink/file if present
  File.delete(link_path) if File.exist?(link_path) || File.symlink?(link_path)

  File.symlink(source_path, link_path)
rescue StandardError => e
  warn "✗ Failed to create symlink: #{e.message}"
  warn "  Source: #{source_path}"
  warn "  Target: #{link_path}"
  exit 1
end

def verify_executable!(path) # rubocop:disable Naming/PredicateMethod
  unless File.executable?(path)
    File.chmod(0o755, path)
    warn "  Fixed executable permission on #{path}"
  end
  File.executable?(path)
end

# --- Main ---

require "fileutils"

app = detect_plugin_app

unless app
  puts "No xbar or SwiftBar installation detected."
  puts ""
  puts "Install one of the following to use the Brainiac menu bar plugin:"
  puts "  • xbar:     https://xbarapp.com"
  puts "  • SwiftBar: https://github.com/swiftbar/SwiftBar"
  puts ""
  puts "After installing, re-run this script:"
  puts "  ruby #{__FILE__}"
  exit 0
end

puts "Detected #{app[:name]}"
install_plugin(app[:plugin_dir], SOURCE_PATH)
verify_executable!(SOURCE_PATH)

link_path = File.join(app[:plugin_dir], SYMLINK_NAME)
puts "✓ Installed Brainiac plugin into #{app[:name]}"
puts "  Symlink: #{link_path} → #{SOURCE_PATH}"
puts "  Refresh interval: 2s"
