# frozen_string_literal: true

# Shared helpers: project identification, card map, run_cmd, run_agent, signatures, model detection.

require "English"
CLI_PROVIDERS_DIR = File.join(BRAINIAC_DIR, "cli-providers")

# --trust-all-tools alone doesn't bypass the non-interactive deny list in kiro-cli 1.29.8+.
# Adding --trust-tools with explicit tool names ensures write/exec tools are approved.
TRUSTED_TOOLS = "execute_bash,fs_write,fs_read,code,grep,glob,web_search,web_fetch,use_subagent,use_aws"

def add_trust_tools!(cmd, agent_cli_args)
  return if agent_cli_args.include?("--trust-tools")

  cmd.push("--trust-tools", TRUSTED_TOOLS)
end

# Clean up all worktrees associated with a card: the primary worktree and any
# cross-agent review worktrees (e.g. glados-fizzy-123-*, threepio-fizzy-123-*).
# Safe: skips worktrees with uncommitted changes.
def cleanup_card_worktrees(card_number, repo_path:, primary_worktree: nil, primary_branch: nil)
  return unless card_number

  repo_dir = File.dirname(repo_path)
  repo_base = File.basename(repo_path)
  cleaned = 0

  # Collect all worktree dirs for this card: primary + cross-agent review
  candidates = Dir.glob(File.join(repo_dir, "#{repo_base}--*fizzy-#{card_number}-*")).select { |d| File.directory?(d) }
  candidates << primary_worktree if primary_worktree && File.directory?(primary_worktree) && !candidates.include?(primary_worktree)

  candidates.uniq.each do |wt_path|
    status_output, = Open3.capture3("git", "status", "--porcelain", chdir: wt_path)
    if status_output.strip.empty?
      branch_name = File.basename(wt_path).sub("#{repo_base}--", "")
      begin
        run_cmd("git", "worktree", "remove", wt_path, "--force", chdir: repo_path)
        run_cmd("git", "branch", "-D", branch_name, chdir: repo_path)
        cleaned += 1
        LOG.info "Cleaned up worktree #{wt_path} (branch: #{branch_name})"
      rescue StandardError => e
        LOG.warn "Failed to clean up worktree #{wt_path}: #{e.message}"
      end
    else
      LOG.warn "Worktree #{wt_path} has uncommitted changes — skipping cleanup"
    end
  end

  LOG.info "Card ##{card_number}: cleaned up #{cleaned} worktree(s)" if cleaned.positive?
end

# Resolve CLI config for a project by merging provider defaults with project overrides.
# Priority: project-level keys > provider file > DEFAULT_PROJECT
def resolve_project_cli_config(project_config)
  provider_config = {}
  if (provider_name = project_config["cli_provider"])
    provider_file = File.join(CLI_PROVIDERS_DIR, "#{provider_name}.json")
    if File.exist?(provider_file)
      raw = JSON.parse(File.read(provider_file))
      provider_config = {
        "agent_cli" => raw["binary"],
        "agent_cli_args" => raw["default_args"],
        "agent_model_flag" => raw["model_flag"],
        "allowed_models" => raw["models"]
      }
    end
  end

  DEFAULT_PROJECT.merge(provider_config).merge(project_config)
end

# Copy gitignored files matching .worktreeinclude patterns from repo to worktree.
# Symlink directories matching .worktreelink patterns instead of copying.
# Both files use .gitignore syntax. Only gitignored files/dirs are processed.
def apply_worktree_includes(repo_path, worktree_path)
  copied = 0
  linked = 0

  [".worktreeinclude", ".worktreelink"].each do |filename|
    config_file = File.join(repo_path, filename)
    next unless File.exist?(config_file)

    symlink_mode = filename == ".worktreelink"
    patterns = File.readlines(config_file).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
    next if patterns.empty?

    patterns.each do |pattern|
      Dir.glob(pattern, File::FNM_DOTMATCH, base: repo_path).each do |match|
        src = File.join(repo_path, match)
        dest = File.join(worktree_path, match)
        next if File.exist?(dest) || File.symlink?(dest)

        # Only process gitignored files/dirs
        _, _, st = Open3.capture3("git", "check-ignore", "-q", match, chdir: repo_path)
        next unless st.success?

        FileUtils.mkdir_p(File.dirname(dest))

        if symlink_mode && File.directory?(src)
          FileUtils.ln_s(src, dest)
          linked += 1
          LOG.info "Symlinked #{match} from main repo"
        elsif File.file?(src)
          FileUtils.cp(src, dest)
          copied += 1
        end
      end
    end
  end

  LOG.info "Worktree include: copied #{copied} file(s), symlinked #{linked} dir(s) for #{worktree_path}" if copied.positive? || linked.positive?
end

# Run a project-level hook script from .brainiac/<hook_name> if it exists.
# Passes REPO_PATH (and optionally WORKTREE_PATH) as environment variables.
def run_project_hook(repo_path, hook_name, extra_env: {})
  hook = File.join(repo_path, ".brainiac", hook_name)
  return unless File.exist?(hook)

  env = { "REPO_PATH" => repo_path }.merge(extra_env)
  LOG.info "Running .brainiac/#{hook_name} hook for #{repo_path}"
  output, status = Open3.capture2e(env, "bash", hook, chdir: repo_path)
  if status.success?
    LOG.info ".brainiac/#{hook_name} completed successfully"
  else
    LOG.warn ".brainiac/#{hook_name} failed (exit #{status.exitstatus}): #{output.strip}"
  end
end

def default_project_key
  # Find the project marked as default
  default = PROJECTS.find { |_key, config| config["default"] == true }
  default ? default[0] : nil
end

def identify_project_by_tags(tags)
  return nil if PROJECTS.empty?

  tag_names = tags.map { |t| (t.is_a?(Hash) ? t["name"] : t).to_s.downcase }

  PROJECTS.each do |project_key, config|
    project_tags = (config["fizzy_tags"] || []).map(&:downcase)
    return [project_key, config] if tag_names.intersect?(project_tags)
  end

  # Fall back to default project if configured
  default_key = default_project_key
  if default_key
    LOG.info "No project matched tags [#{tag_names.join(", ")}], falling back to default project '#{default_key}'"
    return [default_key, PROJECTS[default_key]]
  end

  nil
end

def identify_project_by_repo(repo_full_name)
  return nil if PROJECTS.empty?

  PROJECTS.each do |project_key, config|
    return [project_key, config] if config["github_repo"] == repo_full_name
  end

  # Fall back to default project if configured
  default_key = default_project_key
  if default_key
    LOG.info "No project matched GitHub repo '#{repo_full_name}', falling back to default project '#{default_key}'"
    return [default_key, PROJECTS[default_key]]
  end

  nil
end

def resolve_card_number(internal_id, repo_path:)
  env = default_fizzy_env
  [nil, "--indexed-by closed"].each do |extra_flag|
    cmd = ["fizzy", "card", "list", "--all"]
    cmd << extra_flag if extra_flag
    output, status = Open3.capture2(env, *cmd, chdir: repo_path)
    next unless status.success?

    data = JSON.parse(output)["data"] || []
    match = data.find { |c| c["id"] == internal_id }
    if match
      LOG.info "Resolved card number #{match["number"]} for internal_id #{internal_id}"
      return match["number"]
    end
  end

  LOG.warn "Could not resolve card number for internal_id #{internal_id}"
  nil
rescue StandardError => e
  LOG.warn "resolve_card_number failed for #{internal_id}: #{e.message}"
  nil
end

def load_card_map
  return {} unless File.exist?(CARD_MAP_FILE)

  JSON.parse(File.read(CARD_MAP_FILE))
rescue JSON::ParserError
  {}
end

def save_card_map(map)
  File.write(CARD_MAP_FILE, JSON.pretty_generate(map))
end

def slugify(title, max_length: 40)
  title.downcase.gsub(/[^a-z0-9\s-]/, "").strip.gsub(/\s+/, "-").slice(0, max_length).chomp("-")
end

def verify_signature!(request, payload_body, board_key: nil)
  signature = request.env["HTTP_X_WEBHOOK_SIGNATURE"]
  halt 403, { error: "Missing signature" }.to_json unless signature
  secret = board_key ? board_webhook_secret(board_key) : FIZZY_WEBHOOK_SECRET
  halt 403, { error: "No webhook secret configured" }.to_json unless secret
  computed = OpenSSL::HMAC.hexdigest("sha256", secret, payload_body)
  halt 403, { error: "Invalid signature" }.to_json unless Rack::Utils.secure_compare(signature, computed)
end

def verify_github_signature!(request, payload_body)
  signature = request.env["HTTP_X_HUB_SIGNATURE_256"]
  halt 403, { error: "Missing GitHub signature" }.to_json unless signature
  secret = github_webhook_secret
  halt 500, { error: "GitHub webhook secret not configured" }.to_json unless secret
  computed = "sha256=#{OpenSSL::HMAC.hexdigest("sha256", secret, payload_body)}"
  halt 403, { error: "Invalid GitHub signature" }.to_json unless Rack::Utils.secure_compare(signature, computed)
end

def run_cmd(*cmd, chdir:, env: {})
  LOG.info "Running: #{cmd.join(" ")} (in #{chdir})"
  stdout, stderr, status = Open3.capture3(env, *cmd, chdir: chdir)
  raise "Command failed (#{cmd.first}): #{stderr}" unless status.success?

  stdout
end

# Trust the version manager config in a directory (supports mise and asdf)
def trust_version_manager(path, chdir:)
  if system("which mise >/dev/null 2>&1")
    run_cmd("mise", "trust", path, chdir: chdir)
  elsif system("which asdf >/dev/null 2>&1")
    LOG.info "asdf detected — no explicit trust needed for #{path}"
  else
    LOG.info "No version manager (mise/asdf) found — skipping trust for #{path}"
  end
rescue StandardError => e
  LOG.warn "Could not trust version manager in #{path}: #{e.message}"
end

# Cards that have been merged to main — skip Needs Review moves for these.
# Keyed by card number (string), value is Time. Entries expire after 10 minutes.
MERGED_CARDS = {}
MERGED_CARDS_MUTEX = Mutex.new

def mark_card_merged(card_number)
  MERGED_CARDS_MUTEX.synchronize { MERGED_CARDS[card_number.to_s] = Time.now }
end

def card_merged?(card_number)
  MERGED_CARDS_MUTEX.synchronize do
    ts = MERGED_CARDS[card_number.to_s]
    ts && (Time.now - ts < 600)
  end
end

# Pre-fetch a Fizzy card's body and comments so the agent doesn't have to.
# Returns a formatted string suitable for injection into the prompt, or ''
# if the fetch fails (agent can still fetch manually as a fallback).
PREFETCH_COMMENT_LIMIT = 15
COMMENT_BODY_TRUNCATE_LENGTH = 500
CARD_CONTEXT_CACHE = {}
CARD_CONTEXT_CACHE_TTL = 60 # seconds

def prefetch_card_context(card_number, repo_path:, agent_name: nil)
  return "" unless card_number

  # Return cached context if fresh enough
  cache_key = "#{card_number}-#{agent_name}"
  cached = CARD_CONTEXT_CACHE[cache_key]
  if cached && (Time.now - cached[:at]) < CARD_CONTEXT_CACHE_TTL
    LOG.info "Using cached card context for ##{card_number} (#{(Time.now - cached[:at]).to_i}s old)"
    return cached[:context]
  end

  env = fizzy_env_for(agent_name)
  parts = []

  card_parts = fetch_card_details(card_number, repo_path: repo_path, env: env)
  return "" if card_parts.nil?

  parts.concat(card_parts)
  parts.concat(fetch_card_comments(card_number, repo_path: repo_path, env: env))
  return "" if parts.empty?

  context = parts.join("\n")
  result = <<~CARD_CONTEXT
    ## Card Context (pre-fetched — do NOT re-fetch this)
    #{context}

  CARD_CONTEXT

  CARD_CONTEXT_CACHE[cache_key] = { context: result, at: Time.now }
  CARD_CONTEXT_CACHE.delete_if { |_, v| (Time.now - v[:at]) > CARD_CONTEXT_CACHE_TTL * 5 } if CARD_CONTEXT_CACHE.size > 50
  result
rescue StandardError => e
  LOG.warn "prefetch_card_context failed for card ##{card_number}: #{e.message}"
  ""
end

# Fetch card details from Fizzy. Returns array of text parts, or nil on failure.
def fetch_card_details(card_number, repo_path:, env:)
  card_output = run_cmd("fizzy", "card", "show", card_number.to_s, chdir: repo_path, env: env)
  card_data = begin
    JSON.parse(card_output)["data"]
  rescue StandardError
    nil
  end
  return [] unless card_data

  parts = []
  parts << "## Card ##{card_number}: #{card_data["title"]}"
  parts << "Status: #{card_data["status"]}" if card_data["status"]
  tags = (card_data["tags"] || []).map { |t| t.is_a?(Hash) ? t["name"] : t }
  parts << "Tags: #{tags.join(", ")}" unless tags.empty?
  body = card_data.dig("body", "plain_text") || card_data["body"]
  parts << "\n#{body}" if body && !body.to_s.strip.empty?
  parts
rescue StandardError => e
  LOG.warn "Could not pre-fetch card ##{card_number}: #{e.message}"
  nil
end

# Fetch recent comments for a card. Returns array of text parts.
def fetch_card_comments(card_number, repo_path:, env:)
  comments_output = run_cmd("fizzy", "comment", "list", "--card", card_number.to_s, chdir: repo_path, env: env)
  comments_data = JSON.parse(comments_output)["data"] || []
  return [] if comments_data.empty?

  parts = []
  total = comments_data.size
  comments_data = comments_data.last(PREFETCH_COMMENT_LIMIT)
  parts << "\n## Comments#{" (last #{PREFETCH_COMMENT_LIMIT} of #{total})" if total > PREFETCH_COMMENT_LIMIT}"
  comments_data.each do |c|
    author = c.dig("creator", "name") || "Unknown"
    body = c.dig("body", "plain_text") || ""
    cid = c["id"]
    next if body.strip.empty?

    body = "#{body[0...COMMENT_BODY_TRUNCATE_LENGTH]}… [truncated]" if body.length > COMMENT_BODY_TRUNCATE_LENGTH
    parts << "\n### #{author} (comment ID: #{cid})\n#{body}"
  end
  parts
rescue StandardError => e
  LOG.warn "Could not pre-fetch comments for card ##{card_number}: #{e.message}"
  []
end

def scrub_invalid_attachments!(dir)
  attachments_dir = File.join(dir, ".fizzy-attachments")
  return unless File.directory?(attachments_dir)

  Dir.glob(File.join(attachments_dir, "*")).each do |file_path|
    next unless File.file?(file_path)

    file_type, _status = Open3.capture2("file", "--brief", "--mime-type", file_path)
    unless file_type.strip.start_with?("image/")
      LOG.warn "Removing invalid attachment #{file_path} (detected as: #{file_type.strip})"
      FileUtils.rm_f(file_path)
    end
  end
rescue StandardError => e
  LOG.error "Error scrubbing attachments in #{dir}: #{e.message}"
end

# Extract the last N meaningful lines from an agent log for crash reporting.
def extract_crash_snippet(log_file, max_lines: 20)
  return nil unless log_file && File.exist?(log_file)

  lines = File.readlines(log_file).map { |l| l.gsub(/\e\[[0-9;]*[a-zA-Z]/, "").rstrip }.reject(&:empty?).last(max_lines)
  lines&.join("\n")
rescue StandardError => e
  LOG.warn "[CrashNotify] Could not read log: #{e.message}"
  nil
end

# Notify the originating channel that an agent crashed.
# source: :fizzy, :github, :discord
# source_context: hash with channel-specific info needed to post the notification
def notify_agent_crash(exit_status:, log_file:, agent_name:, source:, source_context:, project_config:)
  agent_display = agent_name || "Agent"
  snippet = extract_crash_snippet(log_file)
  snippet_block = snippet ? "\n```\n#{snippet[-1500..]}\n```" : ""

  case source
  when :fizzy
    card_number = source_context[:card_number]
    return unless card_number

    repo_path = project_config&.dig("repo_path") || Dir.pwd
    body = "<p>💥 <strong>#{agent_display} crashed</strong> (exit code #{exit_status})</p>" \
           "<p>Log: <code>#{log_file}</code></p>"
    if snippet
      escaped = snippet[-1500..].gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      body += "<pre>#{escaped}</pre>"
    end
    begin
      run_cmd("fizzy", "comment", "create", "--card", card_number.to_s, "--body", body,
              chdir: repo_path, env: fizzy_env_for(agent_display))
      LOG.info "[CrashNotify] Posted crash comment on Fizzy card ##{card_number}"
    rescue StandardError => e
      LOG.error "[CrashNotify] Failed to post Fizzy crash comment: #{e.message}"
    end

  when :github
    pr_number = source_context[:pr_number]
    repo_name = source_context[:repo_name]
    return unless pr_number && repo_name

    work_dir = source_context[:work_dir] || Dir.pwd
    comment_body = "💥 **#{agent_display} crashed** (exit code #{exit_status})\n\nLog: `#{log_file}`#{snippet_block}"
    begin
      run_cmd("gh", "pr", "comment", pr_number.to_s, "--repo", repo_name, "--body", comment_body, chdir: work_dir)
      LOG.info "[CrashNotify] Posted crash comment on GitHub PR ##{pr_number}"
    rescue StandardError => e
      LOG.error "[CrashNotify] Failed to post GitHub crash comment: #{e.message}"
    end

  when :discord
    channel_id = source_context[:channel_id]
    message_id = source_context[:message_id]
    bot_token = source_context[:bot_token]
    return unless channel_id && bot_token

    message = "💥 **#{agent_display} crashed** (exit code #{exit_status})\nLog: `#{log_file}`#{snippet_block}"
    send_discord_message(channel_id, message, token: bot_token, reply_to: message_id)
    LOG.info "[CrashNotify] Posted crash message to Discord channel #{channel_id}"
  end
rescue StandardError => e
  LOG.error "[CrashNotify] Unexpected error: #{e.message}"
end

# Append an italic PR/branch footer to the agent's most recent Fizzy comment.
def append_fizzy_comment_footer(card_number, project_config:, agent_name: nil)
  repo_path = project_config["repo_path"]
  project_config["github_repo"]
  env = fizzy_env_for(agent_name)

  # Find branch and tracked PRs from card_map
  card_map = load_card_map
  card_info = card_map.values.find { |v| v["number"] == card_number }
  branch = card_info&.dig("branch")
  return unless branch

  prs = card_info&.dig("prs") || []

  # Build footer parts
  parts = []
  parts << "Branch: <code>#{branch}</code>"
  prs.each { |pr| parts << "PR: <a href=\"#{pr["url"]}\">##{pr["number"]}</a>" }
  return if parts.empty?

  footer_html = "<p style=\"margin-top:12px;font-size:0.85em;color:#888;\"><em>#{parts.join(" · ")}</em></p>"

  # Find agent's most recent comment
  begin
    output = run_cmd("fizzy", "comment", "list", "--card", card_number.to_s, chdir: repo_path, env: env)
    comments = (JSON.parse(output)["data"] || []).reverse
    agent_display = fizzy_display_name(agent_name)
    comment = comments.find { |c| c.dig("creator", "name") == agent_display && c.dig("body", "html")&.include?("<") }
    return unless comment

    existing_html = comment.dig("body", "html") || ""
    # Don't double-append if footer already present
    return if existing_html.include?("Branch: <code>#{branch}</code>")

    # Strip Fizzy's outer wrapper — it re-wraps on update
    inner = existing_html.sub(/\A\s*<div class="action-text-content">\s*/m, "").sub(%r{\s*</div>\s*\z}m, "")
    updated_html = "#{inner}\n#{footer_html}"
    run_cmd("fizzy", "comment", "update", comment["id"], "--card", card_number.to_s,
            "--body", updated_html, chdir: repo_path, env: env)
    LOG.info "[Footer] Appended PR/branch footer to comment #{comment["id"]} on card ##{card_number}"
  rescue StandardError => e
    LOG.warn "[Footer] Could not append footer to card ##{card_number}: #{e.message}"
  end
end

def move_card_to_column(card_number, column_name, project_config:, agent_name: nil)
  return unless card_number

  board_key = board_key_for_project(project_config)
  column_id = (board_key && board_column_id(board_key, column_name)) || DEFAULT_COLUMN_IDS[column_name]
  return unless column_id

  repo_path = project_config["repo_path"]
  env = fizzy_env_for(agent_name || AI_AGENT_NAME)
  run_cmd("fizzy", "card", "column", card_number.to_s, "--column", column_id, chdir: repo_path, env: env)
  record_self_move(card_number)
  LOG.info "[Column] Moved card ##{card_number} to #{column_name} (#{column_id})"
rescue StandardError => e
  LOG.warn "[Column] Failed to move card ##{card_number} to #{column_name}: #{e.message}"
end

def run_agent(prompt, project_config:, chdir: nil, log_name: "agent", model: nil, effort: nil, agent_name: nil, card_number: nil, comment_id: nil,
              source: nil, source_context: {}, skip_column_move: false)
  resolved = resolve_project_cli_config(project_config)
  chdir ||= resolved["repo_path"]
  model ||= resolved["agent_model"]
  effort ||= resolved["agent_effort"]
  agent_config_name = agent_name&.downcase&.gsub(/[^a-z0-9-]/, "-")

  ensure_fizzy_yaml!(chdir, project_config)
  Thread.new { scrub_invalid_attachments!(chdir) }

  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
  log_file = File.join(chdir, "tmp/agent-#{log_name}-#{timestamp}.log")
  FileUtils.mkdir_p(File.dirname(log_file))

  prompt_file = write_agent_prompt_file(prompt, log_name, timestamp)
  cmd = build_agent_cmd(resolved, agent_config_name: agent_config_name, model: model, effort: effort)
  spawn_env = agent_env_for(agent_name)

  LOG.info "Running #{resolved["agent_cli"]} in #{chdir}, logging to #{log_file}"
  LOG.info "Prompt written to #{prompt_file}"
  LOG.info "Command: #{cmd.join(" ")}"
  LOG.info "Injecting #{spawn_env.size} env var(s) for agent #{agent_name}: #{spawn_env.keys.join(", ")}" unless spawn_env.empty?

  head_before = nil
  project_key_for_restart = PROJECTS.find { |_k, v| v == project_config }&.first
  if project_key_for_restart == "brainiac"
    head_before, = Open3.capture2("git", "rev-parse", "HEAD", chdir: chdir)
    head_before = head_before.strip
  end

  pid = spawn(spawn_env, *cmd,
              chdir: chdir,
              in: prompt_file,
              out: [log_file, "w"],
              err: %i[child out])

  Thread.new do
    Process.wait(pid)
    handle_agent_completion(
      pid: pid, agent_cli: resolved["agent_cli"], agent_config_name: agent_config_name,
      agent_name: agent_name, log_file: log_file, log_name: log_name,
      prompt_file: prompt_file, chdir: chdir, source: source,
      source_context: source_context, project_config: project_config,
      card_number: card_number, skip_column_move: skip_column_move,
      head_before: head_before, project_key_for_restart: project_key_for_restart
    )
  end

  LOG.info "#{resolved["agent_cli"]} started (pid: #{pid}, agent: #{agent_config_name || "default"}, " \
           "model: #{model || "default"}), tail -f #{log_file}"

  [pid, log_file]
end

# Ensure .fizzy.yaml is present in the working directory (worktrees need a copy).
def ensure_fizzy_yaml!(chdir, project_config)
  fizzy_yaml_dest = File.join(chdir, ".fizzy.yaml")
  return if File.exist?(fizzy_yaml_dest)

  fizzy_yaml_src = File.join(project_config["repo_path"], ".fizzy.yaml")
  return unless File.exist?(fizzy_yaml_src)

  FileUtils.cp(fizzy_yaml_src, fizzy_yaml_dest)
  LOG.info "Copied .fizzy.yaml to #{chdir}"
end

# Write agent prompt to a temp file, return path.
def write_agent_prompt_file(prompt, log_name, timestamp)
  prompt_dir = File.join(BRAINIAC_DIR, "tmp")
  FileUtils.mkdir_p(prompt_dir)
  prompt_file = File.join(prompt_dir, "prompt-#{log_name}-#{timestamp}.md")
  File.write(prompt_file, prompt)
  prompt_file
end

# Build the CLI command array for an agent invocation.
def build_agent_cmd(resolved, agent_config_name: nil, model: nil, effort: nil)
  cmd = [resolved["agent_cli"]]
  cmd.push("--agent", agent_config_name) if agent_config_name
  cmd.concat(resolved["agent_cli_args"].split)
  add_trust_tools!(cmd, resolved["agent_cli_args"])
  cmd.push(resolved["agent_model_flag"], model) if resolved["agent_model_flag"] && !resolved["agent_model_flag"].empty? && model
  cmd.push(resolved["agent_effort_flag"], effort) if resolved["agent_effort_flag"] && !resolved["agent_effort_flag"].empty? && effort
  cmd
end

def handle_agent_completion(**ctx)
  agent_exit_status = $CHILD_STATUS.exitstatus
  agent_signaled = $CHILD_STATUS.signaled?
  LOG.info "#{ctx[:agent_cli]} finished (pid: #{ctx[:pid]}, exit: #{agent_exit_status})"

  if ctx[:source] && agent_exit_status && agent_exit_status != 0 && !agent_signaled
    notify_agent_crash(
      exit_status: agent_exit_status, log_file: ctx[:log_file],
      agent_name: ctx[:agent_name], source: ctx[:source], source_context: ctx[:source_context],
      project_config: ctx[:project_config]
    )
  end

  fizzy_card = ctx[:card_number] || ctx[:source_context][:card_number]
  handle_fizzy_post_session(fizzy_card, agent_exit_status, agent_signaled, ctx[:agent_name], ctx[:chdir], ctx[:source], ctx[:source_context],
                            ctx[:project_config], ctx[:skip_column_move])
  handle_plan_finalization(ctx[:prompt_file], ctx[:agent_name], ctx[:project_config])

  qmd_out, qmd_status = Open3.capture2e("qmd", "update")
  if qmd_status.success?
    LOG.info "[Brain] qmd update completed after #{ctx[:agent_config_name] || "agent"} session"
  else
    LOG.warn "[Brain] qmd update failed: #{qmd_out.strip}"
  end

  skill_candidate = detect_skill_candidate(ctx[:log_file])
  if skill_candidate[:extract]
    LOG.info "[Skills] Session qualifies for skill extraction " \
             "(#{skill_candidate[:tool_calls]} tool calls, #{skill_candidate[:error_patterns]} error patterns) " \
             "— agent was nudged via reflection prompt"
  end

  brain_push(message: "#{ctx[:agent_config_name] || "agent"}: #{ctx[:log_name]}")
  check_brainiac_restart(ctx[:head_before], ctx[:chdir], ctx[:project_key_for_restart], ctx[:agent_config_name])
end

def handle_fizzy_post_session(fizzy_card, exit_status, signaled, agent_name, chdir, source, source_context, project_config, skip_column_move)
  return unless source == :fizzy && fizzy_card && exit_status&.zero? && !signaled

  unless skip_column_move || card_merged?(fizzy_card)
    move_card_to_column(fizzy_card, "needs_review", project_config: project_config, agent_name: agent_name)
  end

  append_fizzy_comment_footer(fizzy_card, project_config: project_config, agent_name: agent_name)

  return unless source_context[:deploy_intent]

  auto_deploy_after_session(
    deploy_intent: source_context[:deploy_intent],
    card_internal_id: source_context[:card_internal_id] || load_card_map.find { |_, v| v["number"] == fizzy_card }&.first,
    card_number: fizzy_card,
    worktree_path: chdir,
    agent_name: agent_name
  )
end

def handle_plan_finalization(prompt_file, agent_name, project_config)
  return unless File.exist?(prompt_file)

  prompt_content = File.read(prompt_file)
  card_id_match = prompt_content.match(/CARD_ID.*?(\d+|discord-[\w-]+)/)
  return unless card_id_match

  card_id = card_id_match[1]
  plan_file = File.join(PLANS_DIR, "card-#{card_id}-plan.md")
  return unless File.exist?(plan_file)

  LOG.info "[Planning] Plan file detected for card #{card_id}, finalizing..."
  card_num = card_id.match?(/^\d+$/) ? card_id.to_i : nil
  project_key = PROJECTS.find { |_k, v| v == project_config }&.first

  result = finalize_plan(
    card_id: card_id, card_number: card_num,
    agent_name: agent_name || AI_AGENT_NAME,
    project_key: project_key, repo_path: project_config["repo_path"]
  )

  if result[:success]
    LOG.info "[Planning] Plan finalized: #{result[:tasks].size} tasks created"
  else
    LOG.error "[Planning] Failed to finalize plan: #{result[:error]}"
  end
end

def check_brainiac_restart(head_before, chdir, project_key_for_restart, agent_config_name)
  return unless project_key_for_restart == "brainiac" && head_before

  head_after, = Open3.capture2("git", "rev-parse", "HEAD", chdir: chdir)
  git_status, = Open3.capture2("git", "status", "--porcelain", chdir: chdir)
  if head_after.strip != head_before || !git_status.strip.empty?
    queue_brainiac_restart(agent_config_name || "agent")
  else
    LOG.info "[Brainiac] #{agent_config_name || "agent"} session on brainiac had no changes — skipping restart"
  end
end

def authorized?(payload)
  creator_id = payload.dig("creator", "id")
  AUTHORIZED_USER_IDS.include?(creator_id)
end

def human_mentioned?(user_id)
  return false unless FIZZY_CONFIG["authorized_users"]

  user = FIZZY_CONFIG["authorized_users"].find { |u| u["id"] == user_id }
  user && user["human"]
end

def detect_model(project_config, tags: [], text: "")
  resolved = resolve_project_cli_config(project_config)
  allowed_models = resolved["allowed_models"] || {}
  return resolved["agent_model"] if allowed_models.empty?

  if (match = text.match(/\[(\w+)\]/))
    key = match[1].downcase
    return allowed_models[key] if allowed_models.key?(key)
  end

  tags.each do |tag|
    key = (tag.is_a?(Hash) ? tag["name"] : tag).to_s.downcase
    return allowed_models[key] if allowed_models.key?(key)
  end

  resolved["agent_model"]
end

# Detect effort level from inline tags [effort:high] or Fizzy card tags (effort-high).
# Returns the effort level string (e.g. "high") or nil.
# If the requested level isn't supported by the current model, returns the closest
# lower level from allowed_efforts.
def detect_effort(project_config, tags: [], text: "")
  resolved = resolve_project_cli_config(project_config)
  allowed = resolved["allowed_efforts"] || %w[low medium high xhigh max]

  # Inline tag: [effort:high]
  if (match = text.match(/\[effort:(\w+)\]/i))
    level = match[1].downcase
    return resolve_effort_level(level, allowed) if allowed.include?(level)
  end

  # Fizzy card tags: effort-high, effort-max
  tags.each do |tag|
    name = (tag.is_a?(Hash) ? tag["name"] : tag).to_s.downcase
    if name.start_with?("effort-")
      level = name.sub("effort-", "")
      return resolve_effort_level(level, allowed) if allowed.include?(level)
    end
  end

  resolved["agent_effort"]
end

# If a level isn't in allowed_efforts, return the closest lower level.
def resolve_effort_level(level, allowed)
  all_levels = %w[low medium high xhigh max]
  return level if allowed.include?(level)

  idx = all_levels.index(level)
  return nil unless idx

  # Walk down to find closest supported lower level
  idx.downto(0) { |i| return all_levels[i] if allowed.include?(all_levels[i]) }
  nil
end

def notify_unauthorized(action, creator_name, card_info)
  msg = "Unauthorized: #{creator_name} triggered #{action} on #{card_info}"
  LOG.warn msg
  system("#{NOTIFICATION_COMMAND} '#{msg}'") if NOTIFICATION_COMMAND
end
