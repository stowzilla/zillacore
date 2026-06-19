#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Waybar Per-Environment Deploy Module
# Usage: waybar-deploy-env.rb <env_key>
#        waybar-deploy-env.rb <env_key> --click
#        waybar-deploy-env.rb <env_key> --deploy

require "json"
require "net/http"
require "shellwords"
require "uri"
require "time"

SERVER_URL = "http://localhost:4567"
RECENT_WINDOW = 30 * 60

env_key = ARGV.find { |a| !a.start_with?("--") }
unless env_key
  puts({ text: "?", tooltip: "No env specified", class: "error" }.to_json)
  exit
end

def fetch_deployments
  uri = URI("#{SERVER_URL}/api/deployments")
  response = Net::HTTP.get_response(uri)
  JSON.parse(response.body)["deployments"] || []
rescue StandardError
  nil
end

def time_ago(iso_time)
  return nil unless iso_time

  seconds = (Time.now - Time.parse(iso_time)).to_i
  return "#{seconds}s ago" if seconds < 60

  minutes = seconds / 60
  return "#{minutes}m ago" if minutes < 60

  hours = minutes / 60
  "#{hours}h ago"
end

def resize_deploy_terminal
  # Shrink the deploy terminal to ~15% width after it tiles in at 50%
  # Calculates resize delta from monitor width dynamically
  script = "sleep 0.5 && " \
           'width=$(hyprctl monitors -j | ruby -rjson -e "puts JSON.parse(STDIN.read)[0][%q(width)]") && ' \
           "delta=$(( (width / 2) - (width * 15 / 100) )) && " \
           'hyprctl --batch "dispatch focuswindow class:brainiac-deploy; dispatch resizeactive -${delta} 0"'
  spawn("bash", "-c", script, %i[out err] => "/dev/null")
end

def handle_click(env_key, deployment)
  return unless deployment

  if deployment["last_deploy_status"] == "failed" && deployment["last_deploy_log"]
    log = deployment["last_deploy_log"]
    if File.exist?(log.to_s)
      spawn("alacritty", "--class", "brainiac-deploy", "-e", "bash", "-c",
            "echo '=== Deploy failure: #{deployment["label"] || env_key} ===' && echo && cat #{Shellwords.escape(log)} && echo && echo 'Press Enter to close...' && read",
            %i[out err] => "/dev/null")
      resize_deploy_terminal
      return
    end
  end

  url = deployment["url"]
  spawn("xdg-open", url, %i[out err] => "/dev/null") if url
end

def handle_deploy(env_key, deployment)
  return unless deployment

  prefill = deployment["status"] == "occupied" && deployment["card_number"] ? deployment["card_number"].to_s : ""
  card_number = `timeout 60 zenity --entry --title="Deploy to #{env_key}" --text="Fizzy card number:"#{unless prefill.empty?
                                                                                                         " --entry-text=#{Shellwords.escape(prefill)}"
                                                                                                       end} 2>/dev/null`.strip
  return if card_number.empty?

  matches = Dir.glob(File.expand_path("~/Code/*fizzy-#{card_number}-*/"))
  worktree = matches.find { |d| File.directory?(d) }
  unless worktree
    `timeout 10 zenity --error --text="No worktree found for card ##{card_number}" 2>/dev/null`
    return
  end

  # Resolve AWS_PROFILE from deployments config
  aws_profile = nil
  config_file = File.expand_path("~/.brainiac/deployments.json")
  if File.exist?(config_file)
    cfg = begin
      JSON.parse(File.read(config_file))
    rescue StandardError
      {}
    end
    aws_profile = cfg.dig("environments", env_key, "aws_profile")
  end

  deploy_script = <<~BASH
    cd #{Shellwords.escape(worktree)}
    #{"export AWS_PROFILE=#{Shellwords.escape(aws_profile)}" if aws_profile}
    echo "🚀 #{env_key} deploy in progress..."
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
    echo "Press Enter to close..."
    read
  BASH

  # Mark deploying via API so waybar turns orange immediately
  begin
    uri = URI("#{SERVER_URL}/api/deployments/#{env_key}/deploying")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = { worktree: worktree }.to_json
    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
  rescue StandardError
    # Non-fatal — deploy proceeds even if server is unreachable
  end

  spawn("alacritty", "--class", "brainiac-deploy", "-e", "bash", "-c", deploy_script, %i[out err] => "/dev/null")
  resize_deploy_terminal
end

def generate_output(env_key)
  deployments = fetch_deployments
  unless deployments
    puts({ text: "", tooltip: "#{env_key}: server unreachable", class: "error" }.to_json)
    return
  end

  d = deployments.find { |dep| dep["env"] == env_key }
  unless d
    puts({ text: "", tooltip: "#{env_key}: not configured", class: "error" }.to_json)
    return
  end

  label = d["label"] || env_key

  if d["status"] == "occupied"
    deploy_time = d["last_deploy_at"] || d["deployed_at"]
    recent = deploy_time && (Time.now - Time.parse(deploy_time)) < RECENT_WINDOW
    status = d["last_deploy_status"]

    if status == "deploying"
      dot = '<span color="#ffaa00">●</span>'
      css_class = "deploy-deploying"
    elsif status == "failed"
      dot = '<span color="#ff4444">●</span>'
      css_class = "deploy-failed"
    elsif recent && status == "success"
      dot = '<span color="#4488ff">●</span>'
      css_class = "deploy-recent"
    else
      dot = '<span color="#ff4444">●</span>'
      css_class = "deploy-occupied"
    end

    card = d["card_number"] ? "##{d["card_number"]}" : d["branch"] || "unknown"
    branch = d["branch"] ? " — #{d["branch"]}" : ""
    ago = time_ago(d["deployed_at"])
    status_icon = case status
                  when "deploying" then "🚀"
                  when "failed" then "💥"
                  when "success" then recent ? "🚀✅" : "🔴"
                  else "🔴"
                  end
    tooltip = "#{status_icon} #{label}: #{card}#{branch}#{" (#{ago})" if ago}\nClick: open URL | Right-click: deploy"
  else
    dot = '<span color="#44ff44">●</span>'
    css_class = "deploy-available"
    ago = time_ago(d["cleared_at"])
    last = d["last_card"] ? " (was ##{d["last_card"]})" : ""
    tooltip = "🟢 #{label}: Available#{" #{ago}" if ago}#{last}\nRight-click: deploy"
  end

  puts({ text: dot, tooltip: tooltip, class: css_class }.to_json)
end

deployments = fetch_deployments
deployment = deployments&.find { |d| d["env"] == env_key }

if ARGV.include?("--click")
  handle_click(env_key, deployment)
elsif ARGV.include?("--deploy")
  handle_deploy(env_key, deployment)
else
  generate_output(env_key)
end
