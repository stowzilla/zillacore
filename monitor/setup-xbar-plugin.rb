#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time setup: symlinks the Brainiac xbar plugin into xbar's plugin directory
# Run this once on macOS after installing xbar

require "fileutils"

XBAR_PLUGIN_DIR = File.expand_path("~/Library/Application Support/xbar/plugins")
PLUGIN_SOURCE = File.expand_path("xbar.3s.rb", __dir__)
PLUGIN_DEST = File.join(XBAR_PLUGIN_DIR, "brainiac.3s.rb")

unless RUBY_PLATFORM.match?(/darwin/i)
  puts "⚠ This script is for macOS only (xbar doesn't run on Linux)"
  exit 1
end

unless File.directory?(XBAR_PLUGIN_DIR)
  puts "⚠ xbar plugin directory not found: #{XBAR_PLUGIN_DIR}"
  puts "  Install xbar first: https://xbarapp.com"
  exit 1
end

if File.exist?(PLUGIN_DEST)
  puts "Removing existing plugin at #{PLUGIN_DEST}"
  File.delete(PLUGIN_DEST)
end

File.symlink(PLUGIN_SOURCE, PLUGIN_DEST)
File.chmod(0o755, PLUGIN_SOURCE)

puts "✓ Brainiac xbar plugin installed"
puts "  #{PLUGIN_SOURCE} → #{PLUGIN_DEST}"
puts "  Refresh interval: 3 seconds"
puts "  Restart xbar to activate"
