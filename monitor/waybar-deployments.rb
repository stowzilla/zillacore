#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Waybar Deployments Module
# Polls /api/deployments and outputs JSON for waybar

require "json"
require "net/http"
require "shellwords"
require "uri"
require "time"

SERVER_URL = "http://localhost:4567"

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
  return "#{hours}h ago" if hours < 24

  "#{hours / 24}d ago"
end

def generate_output
  deployments = fetch_deployments
  unless deployments
    puts({ text: "", tooltip: "Deploy tracker: server unreachable", class: "error" }.to_json)
    return
  end

  if deployments.empty?
    puts({ text: "", tooltip: "No environments configured", class: "empty" }.to_json)
    return
  end

  recent_window = 30 * 60 # 30 minutes

  dots = deployments.map do |d|
    if d["status"] == "occupied"
      deploy_time = d["last_deploy_at"] || d["deployed_at"]
      recent = deploy_time && (Time.now - Time.parse(deploy_time)) < recent_window
      status = d["last_deploy_status"]

      if status == "failed"
        '<span color="#ff4444" background="#440000">●</span>'
      elsif recent && status == "success"
        '<span color="#4488ff">●</span>'
      else
        '<span color="#ff4444">●</span>'
      end
    else
      '<span color="#44ff44">●</span>'
    end
  end
  text = dots.join(" ")

  # Determine CSS class based on deploy states
  has_recent_success = deployments.any? do |d|
    t = d["last_deploy_at"] || d["deployed_at"]
    d["last_deploy_status"] == "success" && t && (Time.now - Time.parse(t)) < recent_window
  end
  has_failure = deployments.any? { |d| d["last_deploy_status"] == "failed" }

  css_class = if has_failure
                "deploy-failed"
              elsif has_recent_success
                "deploy-recent"
              else
                "deployments"
              end

  tooltip_lines = deployments.map do |d|
    label = d["label"] || d["env"]
    if d["status"] == "occupied"
      card = d["card_number"] ? "##{d["card_number"]}" : d["branch"] || "unknown"
      branch = d["branch"] ? " — #{d["branch"]}" : ""
      ago = time_ago(d["deployed_at"])
      status_icon = case d["last_deploy_status"]
                    when "failed" then "💥"
                    when "success"
                      t = d["last_deploy_at"] || d["deployed_at"]
                      t && (Time.now - Time.parse(t)) < recent_window ? "🚀✅" : "🔴"
                    else "🔴"
                    end
      "#{status_icon} #{label}: #{card}#{branch}#{" (#{ago})" if ago}"
    else
      ago = time_ago(d["cleared_at"])
      last = d["last_card"] ? " (was ##{d["last_card"]})" : ""
      "🟢 #{label}: Available#{" #{ago}" if ago}#{last}"
    end
  end

  puts({ text: text, tooltip: tooltip_lines.join("\n"), class: css_class }.to_json)
end

def resize_deploy_terminal
  script = "sleep 0.5 && " \
           'width=$(hyprctl monitors -j | ruby -rjson -e "puts JSON.parse(STDIN.read)[0][%q(width)]") && ' \
           "delta=$(( (width / 2) - (width * 15 / 100) )) && " \
           'hyprctl --batch "dispatch focuswindow class:brainiac-deploy; dispatch resizeactive -${delta} 0"'
  spawn("bash", "-c", script, %i[out err] => "/dev/null")
end

def handle_click
  deployments = fetch_deployments
  return unless deployments&.any?

  # If any environment has a failed deploy, show the log
  failed = deployments.find { |d| d["last_deploy_status"] == "failed" && d["last_deploy_log"] }
  if failed && File.exist?(failed["last_deploy_log"].to_s)
    spawn("alacritty", "-e", "bash", "-c",
          "echo '=== Deploy failure: #{failed["label"] || failed["env"]} ===' && echo && cat #{Shellwords.escape(failed["last_deploy_log"])} && echo && echo 'Press Enter to close...' && read",
          %i[out err] => "/dev/null")
    return
  end

  # Otherwise open environment URLs
  options = deployments.filter_map do |d|
    url = d["url"]
    next unless url

    label = d["label"] || d["env"]
    status = d["status"] == "occupied" ? "🔴" : "🟢"
    card = d["card_number"] ? " ##{d["card_number"]}" : ""
    ["#{status} #{label}#{card}", url]
  end
  return if options.empty?

  if options.length == 1
    spawn("xdg-open", options[0][1], %i[out err] => "/dev/null")
  else
    labels = options.map(&:first)
    choice = `timeout 30 zenity --list --title="Open Environment" --column="Environment" #{labels.map do |l|
      Shellwords.escape(l)
    end.join(" ")} 2>/dev/null`.strip
    return if choice.empty?

    selected = options.find { |label, _| label == choice }
    spawn("xdg-open", selected[1], %i[out err] => "/dev/null") if selected
  end
end

def handle_deploy
  deployments = fetch_deployments
  return unless deployments&.any?

  # Pick environment
  envs = deployments.map { |d| [d["env"], d["label"] || d["env"]] }
  if envs.length == 1
    env_key = envs[0][0]
  else
    labels = envs.map { |key, label| "#{key}|#{label}" }
    choice = `timeout 30 zenity --list --title="Deploy to..." --column="Env" --column="Label" #{labels.map do |l|
      l.split("|").map do |p|
        Shellwords.escape(p)
      end.join(" ")
    end.join(" ")} 2>/dev/null`.strip
    return if choice.empty?

    env_key = choice
  end

  # Get card number — pre-fill with current card if environment is occupied
  selected_dep = deployments.find { |d| d["env"] == env_key }
  prefill = selected_dep && selected_dep["status"] == "occupied" && selected_dep["card_number"] ? selected_dep["card_number"].to_s : ""
  card_number = `timeout 60 zenity --entry --title="Deploy to #{env_key}" --text="Fizzy card number:"#{unless prefill.empty?
                                                                                                         " --entry-text=#{Shellwords.escape(prefill)}"
                                                                                                       end} 2>/dev/null`.strip
  return if card_number.empty?

  # Resolve worktree via glob (same pattern as fz shell function)
  matches = Dir.glob(File.expand_path("~/Code/*fizzy-#{card_number}-*/"))
  worktree = matches.find { |d| File.directory?(d) }
  unless worktree
    `timeout 10 zenity --error --text="No worktree found for card ##{card_number}" 2>/dev/null`
    return
  end

  deploy_script = <<~BASH
    cd #{Shellwords.escape(worktree)}
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

if ARGV.include?("--click")
  handle_click
elsif ARGV.include?("--deploy")
  handle_deploy
else
  generate_output
end
