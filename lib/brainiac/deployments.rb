# frozen_string_literal: true

require "shellwords"

# Deployment environment tracking.
# Tracks which dev environments have active card deploys and which are available.

DEPLOYMENTS_CONFIG_FILE = File.join(BRAINIAC_DIR, "deployments.json")
DEPLOYMENT_STATE_FILE   = File.join(BRAINIAC_DIR, "deployment_state.json")

def load_deployments_config
  return {} unless File.exist?(DEPLOYMENTS_CONFIG_FILE)

  JSON.parse(File.read(DEPLOYMENTS_CONFIG_FILE))
rescue JSON::ParserError => e
  LOG.error "Failed to parse deployments config: #{e.message}"
  {}
end

def load_deployment_state
  return {} unless File.exist?(DEPLOYMENT_STATE_FILE)

  JSON.parse(File.read(DEPLOYMENT_STATE_FILE))
rescue JSON::ParserError => e
  LOG.error "Failed to parse deployment state: #{e.message}"
  {}
end

def save_deployment_state(state)
  File.write(DEPLOYMENT_STATE_FILE, JSON.pretty_generate(state))
end

DEPLOYMENTS_CONFIG = load_deployments_config
DEPLOYMENT_STATE   = load_deployment_state

def reload_deployments_config!(force: false)
  return unless file_changed?(DEPLOYMENTS_CONFIG_FILE, force: force)

  DEPLOYMENTS_CONFIG.replace(load_deployments_config)
end

def reload_deployment_state!(force: false)
  return unless file_changed?(DEPLOYMENT_STATE_FILE, force: force)

  DEPLOYMENT_STATE.replace(load_deployment_state)
end

# Mark an environment as actively deploying (in-progress state for waybar).
def mark_deploying(env_key, worktree_path:)
  state = load_deployment_state
  state[env_key] ||= {}
  state[env_key]["status"] = "occupied"
  state[env_key]["last_deploy_status"] = "deploying"
  state[env_key]["last_deploy_at"] = Time.now.iso8601
  save_deployment_state(state)
  DEPLOYMENT_STATE.replace(state)
end

# Mark an environment as occupied. Resolves card info from the card map using the worktree path.
def deploy_to_environment(env_key, worktree_path:, deployed_by: nil)
  config = DEPLOYMENTS_CONFIG["environments"] || {}
  unless config.key?(env_key)
    LOG.warn "[Deploy] Unknown environment: #{env_key}"
    return { error: "Unknown environment: #{env_key}" }
  end

  state = load_deployment_state
  entry = { "status" => "occupied", "deployed_at" => Time.now.iso8601, "deployed_by" => deployed_by,
            "last_deploy_status" => "success", "last_deploy_at" => Time.now.iso8601 }

  # Resolve card info from card map by matching worktree path
  map = load_card_map
  card_entry = map.values.find { |info| info["worktree"] == worktree_path }
  if card_entry
    entry["card_number"] = card_entry["number"]
    entry["card_title"]  = card_entry["title"]
    entry["branch"]      = card_entry["branch"]
    pr = (card_entry["prs"] || []).last
    if pr
      entry["pr_number"] = pr["number"]
      entry["pr_url"]    = pr["url"]
    end
    # Store card tags for URL resolution (e.g. ops-web-app → ops URL)
    card_idx = CARD_INDEX[card_entry["number"].to_s]
    entry["card_tags"] = card_idx["tags"] if card_idx && card_idx["tags"]
  else
    # No card map match — record branch from git
    branch = `git -C #{Shellwords.escape(worktree_path)} rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
    entry["branch"] = branch unless branch.empty?
  end

  commit = `git -C #{Shellwords.escape(worktree_path)} rev-parse --short HEAD 2>/dev/null`.strip
  entry["commit"] = commit unless commit.empty?

  state[env_key] = entry
  save_deployment_state(state)
  DEPLOYMENT_STATE.replace(state)
  LOG.info "[Deploy] #{env_key} marked occupied — card ##{entry["card_number"] || "none"}, branch: #{entry["branch"]}"
  entry
end

DEPLOY_LOGS_DIR = File.join(BRAINIAC_DIR, "deploy_logs")

# Record a failed deploy — saves output to a log file and updates state.
def record_deploy_failure(env_key, worktree_path:, stdout: "", stderr: "")
  FileUtils.mkdir_p(DEPLOY_LOGS_DIR)
  log_file = File.join(DEPLOY_LOGS_DIR, "#{env_key}-#{Time.now.strftime("%Y%m%d-%H%M%S")}.log")
  File.write(log_file, "=== STDOUT ===\n#{stdout}\n\n=== STDERR ===\n#{stderr}")

  state = load_deployment_state
  state[env_key] ||= {}
  state[env_key]["last_deploy_status"] = "failed"
  state[env_key]["last_deploy_at"] = Time.now.iso8601
  state[env_key]["last_deploy_log"] = log_file
  save_deployment_state(state)
  DEPLOYMENT_STATE.replace(state)
  LOG.info "[Deploy] #{env_key} deploy failed — log at #{log_file}"
end

# Auto-deploy after agent session when [deploy] tag was present.
# deploy_intent is either a specific env key (e.g. "dev04"), :auto (auto-detect), or nil (no deploy).
def auto_deploy_after_session(deploy_intent:, card_internal_id:, card_number:, worktree_path:, agent_name:)
  state = load_deployment_state
  config = DEPLOYMENTS_CONFIG["environments"] || {}

  env_key = resolve_deploy_environment(deploy_intent, state, card_number)
  return unless env_key

  unless config.key?(env_key)
    LOG.warn "[Deploy] Auto-deploy skipped — unknown environment: #{env_key}"
    return
  end

  env_owner = config[env_key]["owner"]
  unless env_owner && env_owner.downcase == AI_AGENT_NAME.downcase
    LOG.info "[Deploy] Auto-deploy skipped #{env_key} — owner is #{env_owner.inspect}, this machine is #{AI_AGENT_NAME}"
    return
  end

  deploy_script = File.join(worktree_path, "scripts", "deploy.sh")
  unless File.exist?(deploy_script)
    LOG.warn "[Deploy] Auto-deploy skipped — no deploy script at #{deploy_script}"
    return
  end

  LOG.info "[Deploy] Auto-deploying card ##{card_number} to #{env_key} (triggered by [deploy] tag)"
  mark_deploying(env_key, worktree_path: worktree_path)

  deploy_env = {}
  aws_profile = config.dig(env_key, "aws_profile")
  deploy_env["AWS_PROFILE"] = aws_profile if aws_profile

  run_deploy(deploy_env, deploy_script, env_key, worktree_path: worktree_path, card_number: card_number, agent_name: agent_name)
end

# Resolve which environment to deploy to from the intent.
def resolve_deploy_environment(deploy_intent, state, card_number)
  if deploy_intent.is_a?(String) && !deploy_intent.empty?
    deploy_intent
  else
    existing = state.find { |_k, v| v["card_number"] == card_number && v["status"] == "occupied" }&.first
    LOG.info "[Deploy] Auto-deploy skipped — card ##{card_number} not currently deployed to any environment" unless existing
    existing
  end
end

# Execute deploy script with terraform lock retry logic.
def run_deploy(deploy_env, deploy_script, env_key, worktree_path:, card_number:, agent_name:)
  stdout, stderr, status = Open3.capture3(deploy_env, deploy_script, env_key, chdir: worktree_path)

  if status.success?
    deploy_to_environment(env_key, worktree_path: worktree_path, deployed_by: "#{agent_name} [deploy]")
    LOG.info "[Deploy] Auto-deploy to #{env_key} succeeded for card ##{card_number}"
  elsif terraform_lock_error?(stdout, stderr)
    retry_deploy_after_lock_fix(deploy_env, deploy_script, env_key, worktree_path: worktree_path, card_number: card_number, agent_name: agent_name)
  else
    record_deploy_failure(env_key, worktree_path: worktree_path, stdout: stdout, stderr: stderr)
    LOG.error "[Deploy] Auto-deploy to #{env_key} failed for card ##{card_number}"
  end
end

# Retry deploy after clearing terraform lock.
def retry_deploy_after_lock_fix(deploy_env, deploy_script, env_key, worktree_path:, card_number:, agent_name:)
  lock_file = File.join(worktree_path, "infrastructure/#{env_key}/.terraform.lock.hcl")
  FileUtils.rm_f(lock_file)
  Open3.capture3("terraform", "init", "-upgrade", chdir: File.join(worktree_path, "infrastructure/#{env_key}"))
  stdout2, stderr2, status2 = Open3.capture3(deploy_env, deploy_script, env_key, chdir: worktree_path)
  if status2.success?
    deploy_to_environment(env_key, worktree_path: worktree_path, deployed_by: "#{agent_name} [deploy]")
    LOG.info "[Deploy] Auto-deploy to #{env_key} succeeded (after terraform lock fix) for card ##{card_number}"
  else
    record_deploy_failure(env_key, worktree_path: worktree_path, stdout: stdout2, stderr: stderr2)
    LOG.error "[Deploy] Auto-deploy to #{env_key} failed (after retry) for card ##{card_number}"
  end
end

# Detect Terraform provider lock file checksum mismatch errors.
def terraform_lock_error?(stdout, stderr)
  combined = "#{stdout}\n#{stderr}"
  combined.include?("checksums previously recorded in the dependency lock file")
end

# Clear all environments occupied by a given card number (called on PR merge).
def clear_deployment_for_card(card_number)
  state = load_deployment_state
  cleared = []

  state.each do |env_key, info|
    next unless info["card_number"] == card_number && info["status"] == "occupied"

    state[env_key] = { "status" => "available", "cleared_at" => Time.now.iso8601, "last_card" => card_number }
    cleared << env_key
  end

  if cleared.any?
    save_deployment_state(state)
    DEPLOYMENT_STATE.replace(state)
    LOG.info "[Deploy] Cleared #{cleared.join(", ")} — card ##{card_number} merged"
  end

  cleared
end

# Return environments with status "available", optionally filtered by project.
def available_environments(project: nil)
  config = DEPLOYMENTS_CONFIG["environments"] || {}
  state = load_deployment_state

  config.select do |env_key, env_config|
    next false if project && env_config["project"] != project

    info = state[env_key]
    info.nil? || info["status"] == "available"
  end.keys
end

# Full deployment status for API / waybar.
def deployment_status
  config = DEPLOYMENTS_CONFIG["environments"] || {}
  state = load_deployment_state

  config.map do |env_key, env_config|
    info = state[env_key] || { "status" => "available" }
    url = resolve_deployment_url(env_config, info["card_tags"])
    { "env" => env_key, "label" => env_config["label"], "url" => url, "project" => env_config["project"] }.merge(info)
  end
end

# Resolve the correct URL for an environment based on card tags.
# If the card has a tag matching a key in the environment's "urls" map, use that URL.
# Otherwise fall back to the default "url".
def resolve_deployment_url(env_config, card_tags)
  urls = env_config["urls"] || {}
  if card_tags && urls.any?
    card_tags.each { |tag| return urls[tag] if urls[tag] }
  end
  env_config["url"]
end
