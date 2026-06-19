#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac macOS Deploy Action
# Prompts for a Fizzy card number via osascript, finds the worktree, and deploys.
# Usage: deploy-env-macos.rb <env_key>

require "English"
require "json"
require "net/http"
require "shellwords"
require "uri"

SERVER_URL = "http://localhost:4567"

env_key = ARGV[0]
exit unless env_key

def fetch_deployments
  uri = URI("#{SERVER_URL}/api/deployments")
  response = Net::HTTP.get_response(uri)
  JSON.parse(response.body)["deployments"] || []
rescue StandardError
  nil
end

deployments = fetch_deployments
deployment = deployments&.find { |d| d["env"] == env_key }

prefill = deployment && deployment["status"] == "occupied" && deployment["card_number"] ? deployment["card_number"].to_s : ""

# Prompt via AppleScript
prompt_script = <<~APPLESCRIPT
  set defaultAnswer to "#{prefill}"
  set dialogResult to display dialog "Fizzy card number:" default answer defaultAnswer with title "Deploy to #{env_key}" buttons {"Cancel", "Deploy"} default button "Deploy"
  return text returned of dialogResult
APPLESCRIPT

card_number = `osascript -e #{Shellwords.escape(prompt_script)} 2>/dev/null`.strip
exit if card_number.empty?

# Find worktree via card_map.json
card_map_path = File.expand_path("~/.brainiac/card_map.json")
worktree = nil
if File.exist?(card_map_path)
  card_map = begin
    JSON.parse(File.read(card_map_path))
  rescue StandardError
    {}
  end
  entry = card_map.values.find { |e| e["card_number"].to_s == card_number }
  worktree = entry["worktree"] if entry && entry["worktree"] && File.directory?(entry["worktree"].to_s)
end

# Fallback: glob for worktree directories
unless worktree
  matches = Dir.glob(File.expand_path("~/projects/sogholdings/*fizzy-#{card_number}-*/"))
  worktree = matches.find { |d| File.directory?(d) }
end

unless worktree
  system("osascript", "-e",
         "display dialog \"No worktree found for card ##{card_number}\" buttons {\"OK\"} default button \"OK\" with title \"Deploy Failed\" with icon stop")
  exit
end

# Resolve AWS_PROFILE
config_file = File.expand_path("~/.brainiac/deployments.json")
aws_profile = nil
if File.exist?(config_file)
  cfg = begin
    JSON.parse(File.read(config_file))
  rescue StandardError
    {}
  end
  aws_profile = cfg.dig("environments", env_key, "aws_profile")
end

# Mark deploying
begin
  uri = URI("#{SERVER_URL}/api/deployments/#{env_key}/deploying")
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  req.body = { worktree: worktree }.to_json
  Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
rescue StandardError
  # Non-fatal
end

# Build deploy script
deploy_script = <<~BASH
  cd #{Shellwords.escape(worktree)}
  #{"export AWS_PROFILE=#{Shellwords.escape(aws_profile)}" if aws_profile}
  echo "🚀 Deploying card ##{card_number} to #{env_key}..."
  echo "   Worktree: #{worktree}"
  echo
  logfile=$(mktemp)
  ./scripts/deploy.sh #{Shellwords.escape(env_key)} 2>&1 | tee "$logfile"
  status=${PIPESTATUS[0]}
  if [ $status -ne 0 ] && grep -q "checksums previously recorded in the dependency lock file" "$logfile"; then
    echo
    echo "⚠️  Terraform lock file mismatch — removing lock and running init -upgrade..."
    echo
    rm -f infrastructure/#{Shellwords.escape(env_key)}/.terraform.lock.hcl
    (cd infrastructure/#{Shellwords.escape(env_key)} && terraform init -upgrade)
    echo
    echo "🔄 Retrying deploy..."
    echo
    ./scripts/deploy.sh #{Shellwords.escape(env_key)} 2>&1
    status=$?
  fi
  rm -f "$logfile"
  echo
  if [ $status -eq 0 ]; then echo "✅ Deploy complete"; else echo "❌ Deploy failed (exit $status)"; fi
  echo
  echo "Press any key to close..."
  read -n 1
BASH

# Write to temp file and run in Terminal.app
script_file = "/tmp/brainiac-deploy-#{env_key}-#{$PROCESS_ID}.sh"
File.write(script_file, deploy_script)
File.chmod(0o755, script_file)

terminal_script = <<~APPLESCRIPT
  tell application "Terminal"
    activate
    do script "#{script_file.gsub('"', '\\"')}; rm -f #{script_file.gsub('"', '\\"')}"
  end tell
APPLESCRIPT

system("osascript", "-e", terminal_script)
