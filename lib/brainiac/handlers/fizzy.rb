# frozen_string_literal: true

# --- Card duplicate detection (card_published / card_triaged) ---

def handle_card_published(payload)
  eventable = payload["eventable"] || {}
  card_number = eventable["number"]
  title = eventable["title"] || ""
  creator_name = payload.dig("creator", "name")
  creator_id = payload.dig("creator", "id")
  tags = eventable["tags"] || []

  # Creator-based routing: only the machine whose local human created the card
  # handles dedup. Requires `"local": true` on the human in fizzy.json authorized_users.
  # If no local humans are configured, skip dedup entirely to avoid duplicate warnings
  # from multiple machines.
  local_humans = FIZZY_CONFIG.fetch("authorized_users", []).select { |u| u["human"] && u["local"] }
  if local_humans.empty?
    LOG.info "[CardIndex] No local humans configured — skipping dedup, indexing only"
    CARD_INDEX.index_card(number: card_number, title: title, creator_name: creator_name, creator_id: creator_id, tags: tags) if card_number
    CARD_INDEX.save
    CARD_INDEX.schedule_qmd_reindex
    return [200, { status: "indexed", card: card_number }.to_json]
  end
  is_local_creator = local_humans.any? { |u| u["id"] == creator_id }

  unless is_local_creator
    LOG.info "[CardIndex] Ignoring card ##{card_number} — creator '#{creator_name}' is not a local human"
    # Still index it so we can compare against it later
    CARD_INDEX.index_card(number: card_number, title: title, creator_name: creator_name, creator_id: creator_id, tags: tags) if card_number
    CARD_INDEX.save
    CARD_INDEX.schedule_qmd_reindex
    return [200, { status: "indexed", card: card_number }.to_json]
  end

  # Check for duplicates before indexing
  similar = CARD_INDEX.find_similar_cards(title, exclude_number: card_number, tags: tags) if card_number

  # Index the new card
  CARD_INDEX.index_card(number: card_number, title: title, creator_name: creator_name, creator_id: creator_id, tags: tags) if card_number
  CARD_INDEX.save
  CARD_INDEX.schedule_qmd_reindex

  if similar&.any?
    best = similar.first
    LOG.info "[CardIndex] Potential duplicate: ##{card_number} '#{title}' ≈ ##{best[:number]} '#{best[:title]}' (score: #{best[:score].round(2)})"

    # Post a comment on the new card warning about the potential duplicate
    project_result = identify_project_by_tags(tags)
    if project_result
      _project_key, project_config = project_result
      repo_path = project_config["repo_path"]

      Thread.new do
        method_label = { trigram: "📝", semantic: "🧠", both: "📝🧠" }
        dupes = similar.map do |s|
          icon = method_label[s[:method]] || "📝"
          "##{s[:number]} \"#{s[:title]}\" (#{(s[:score] * 100).round}% #{icon})"
        end.join("\n- ")
        body = "⚠️ **Possible duplicate detected:**\n- #{dupes}\n\n_📝 = text similarity, 🧠 = semantic similarity_"
        run_cmd("fizzy", "comment", "create", "--card", card_number.to_s, "--body", body, chdir: repo_path, env: default_fizzy_env)
        LOG.info "[CardIndex] Posted duplicate warning on card ##{card_number}"
      rescue StandardError => e
        LOG.warn "[CardIndex] Failed to post duplicate warning: #{e.message}"
      end
    end

    [200, { status: "duplicate_detected", card: card_number, similar: similar.map { |s| { number: s[:number], score: s[:score].round(2) } } }.to_json]
  else
    LOG.info "[CardIndex] Card ##{card_number} '#{title}' indexed, no duplicates found"
    [200, { status: "indexed", card: card_number }.to_json]
  end
end

def get_default_branch(repo_path)
  default_branch = run_cmd("git", "rev-parse", "--abbrev-ref", "HEAD", chdir: repo_path).strip
  begin
    run_cmd("git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD", chdir: repo_path).strip.sub("origin/",
                                                                                                      "")
  rescue StandardError
    default_branch
  end
end

# --- Debounced repo git fetch ---
# Avoids fetching the same repo multiple times within a short window (e.g. rapid card assignments).
# Uses fetch instead of checkout+pull so the main repo's working tree is never touched —
# worktrees branch from origin/<default> directly, avoiding conflicts with local changes.
REPO_LAST_FETCH = {}
REPO_FETCH_DEBOUNCE = 300 # 5 minutes

def debounced_repo_fetch(repo_path)
  last = REPO_LAST_FETCH[repo_path]
  if last && (Time.now - last) < REPO_FETCH_DEBOUNCE
    LOG.info "Skipping git fetch for #{repo_path} — fetched #{(Time.now - last).to_i}s ago"
    return
  end

  run_cmd("git", "fetch", "origin", chdir: repo_path)

  REPO_LAST_FETCH[repo_path] = Time.now
end

def handle_card_assigned(payload)
  eventable = payload["eventable"] || {}
  assignees = eventable["assignees"] || []

  # Check if any LOCAL agent was assigned. Only agents marked "local" in the
  # registry (or discovered from kiro-cli configs) should pick up assignments.
  # This prevents multiple machines from dispatching the same card.
  local_names = local_agent_names
  assigned_agent = assignees.map { |a| a["name"] }.find { |name| local_names.include?(name) }

  assignee_names = assignees.map { |a| a["name"] }.join(", ")
  LOG.info "[Fizzy] Card assigned to: [#{assignee_names}], local agents: [#{local_names.join(", ")}]"

  unless assigned_agent
    LOG.info "[Fizzy] No local agent matched. Assignees: [#{assignee_names}], Local: [#{local_names.join(", ")}]"
    return [200, { status: "ignored", reason: "wrong assignee" }.to_json]
  end

  unless authorized?(payload)
    creator_name = payload.dig("creator", "name") || "Unknown"
    notify_unauthorized("card_assigned", creator_name, "card ##{eventable["number"]}")
    return [200, { status: "ignored", reason: "unauthorized" }.to_json]
  end

  card_number = eventable["number"]
  card_internal_id = eventable["id"]
  title = eventable["title"] || "untitled"
  tags = eventable["tags"] || []

  # Identify project by tags
  project_result = identify_project_by_tags(tags)
  unless project_result
    LOG.warn "No project found for card ##{card_number} with tags: #{tags.map { |t| t.is_a?(Hash) ? t["name"] : t }.join(", ")}"
    return [200, { status: "ignored", reason: "no matching project" }.to_json]
  end

  project_key, project_config = project_result
  repo_path = project_config["repo_path"]

  branch = "fizzy-#{card_number}-#{slugify(title)}"
  model = detect_model(project_config, tags: tags)
  effort = detect_effort(project_config, tags: tags)

  card_key = "card-#{card_number}"
  if session_active?(card_key)
    LOG.info "Skipping card ##{card_number} — agent session already active"
    return [200, { status: "ignored", reason: "session already active" }.to_json]
  end

  LOG.info "Card ##{card_number} assigned to #{assigned_agent} for project '#{project_key}', creating worktree: #{branch} (model: #{model || "default"})"

  # React in background — don't block the dispatch path
  Thread.new do
    emoji = "👍"
    run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--content", emoji, chdir: repo_path, env: fizzy_env_for(assigned_agent))
    LOG.info "Added #{emoji} reaction to card ##{card_number} as #{assigned_agent}"
  rescue StandardError => e
    LOG.warn "Could not add reaction to card: #{e.message}"
  end

  # Fetch latest from origin before creating worktree (doesn't touch working tree)
  debounced_repo_fetch(repo_path)

  # Create worktree (handle existing branch)
  worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{branch}")

  # Get current worktree list once
  worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)

  # Check if worktree directory exists but is orphaned (not tracked by git)
  if File.directory?(worktree_path)
    is_tracked = worktree_list.include?(worktree_path)

    if is_tracked
      LOG.info "Worktree directory #{worktree_path} is tracked by git"
    else
      LOG.warn "Orphaned worktree directory found at #{worktree_path}, removing it"
      begin
        FileUtils.rm_rf(worktree_path)
        LOG.info "Successfully removed orphaned directory"
      rescue StandardError => e
        LOG.error "Failed to remove orphaned directory: #{e.message}"
        raise
      end
    end
  end

  # Check if branch already exists
  branch_exists = system("git", "rev-parse", "--verify", branch, chdir: repo_path, out: File::NULL, err: File::NULL)

  if branch_exists
    LOG.info "Branch #{branch} already exists, checking for existing worktree"

    # Check if worktree already exists for this branch (refresh the list after potential cleanup)
    worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)

    # Parse worktree list - format is: worktree <path>\nHEAD <sha>\nbranch <ref>\n\n
    has_worktree = worktree_list.lines.any? { |line| line.strip == "worktree #{worktree_path}" }

    if has_worktree && File.directory?(worktree_path)
      LOG.info "Reusing existing worktree at #{worktree_path}"
    else
      # Branch exists but no worktree, create worktree from existing branch
      LOG.info "Creating worktree from existing branch #{branch}"
      run_cmd("git", "worktree", "add", worktree_path, branch, chdir: repo_path)
    end
  else
    # Branch doesn't exist, create new branch and worktree from origin
    LOG.info "Creating new branch #{branch} and worktree"
    default_branch = get_default_branch(repo_path)
    run_cmd("git", "worktree", "add", "-b", branch, worktree_path, "origin/#{default_branch}", chdir: repo_path)
  end

  # Trust version manager in the new worktree
  trust_version_manager(worktree_path, chdir: worktree_path)

  # Copy gitignored files and symlink directories per .worktreeinclude / .worktreelink
  apply_worktree_includes(repo_path, worktree_path)

  # Run project-level worktree-setup hook for anything .worktreeinclude/.worktreelink doesn't cover
  run_project_hook(repo_path, "worktree-setup", extra_env: { "WORKTREE_PATH" => worktree_path })

  map = load_card_map
  map[card_internal_id] = {
    "number" => card_number,
    "branch" => branch,
    "worktree" => worktree_path,
    "project" => project_key,
    "agent" => assigned_agent
  }
  save_card_map(map)

  agent_name = assigned_agent

  card_context = prefetch_card_context(card_number, repo_path: repo_path, agent_name: agent_name)

  # Detect planning mode
  planning_info = detect_planning_mode(
    text: title,
    tags: tags,
    card_internal_id: card_internal_id,
    card_number: card_number
  )

  prompt = if planning_info
             # Planning mode
             card_id = planning_info[:card_id]
             LOG.info "[Planning] Planning mode active for card ##{card_number}"

             render_planning_prompt(PROMPT_CARD_ASSIGNED,
                                    { "CARD_NUMBER" => card_number,
                                      "CARD_TITLE" => title,
                                      "BRANCH" => branch,
                                      "CARD_ID" => card_id,
                                      "COMMENT_CREATOR" => assigned_agent },
                                    brain_context: build_brain_context(agent_name: agent_name, card_title: title, card_number: card_number, project_key: project_key,
                                                                       source: :fizzy),
                                    card_context: card_context,
                                    agent_name: agent_name)
           else
             render_prompt(PROMPT_CARD_ASSIGNED,
                           { "CARD_NUMBER" => card_number,
                             "CARD_TITLE" => title,
                             "BRANCH" => branch,
                             "CARD_ID" => card_number,
                             "COMMENT_CREATOR" => assigned_agent },
                           brain_context: build_brain_context(agent_name: agent_name, card_title: title, card_number: card_number, project_key: project_key,
                                                              source: :fizzy),
                           card_context: card_context,
                           agent_name: agent_name)
           end

  pid, log_file = run_agent(prompt, project_config: project_config, chdir: worktree_path, log_name: "assigned-#{card_number}", model: model, effort: effort, agent_name: agent_name,
                                    card_number: card_number, source: :fizzy, source_context: { card_number: card_number })
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: assigned_agent)

  # Move card to Right Now — agent is starting work
  Thread.new { move_card_to_column(card_number, "right_now", project_config: project_config, agent_name: assigned_agent) }

  [200, { status: "processed", card: card_number, branch: branch, project: project_key, agent: assigned_agent }.to_json]
end

# Deploy a card's worktree to a dev environment via comment shortcut.
# Comment is just "dev02" etc. — no agent dispatch, reactions only.
def handle_deploy_comment(eventable, env_key, card_internal_id)
  comment_id = eventable["id"]
  card_info = load_card_map[card_internal_id]

  # Validate environment exists in deployments config (check early, before any worktree work)
  deploy_config = DEPLOYMENTS_CONFIG["environments"] || {}
  unless deploy_config.key?(env_key)
    LOG.warn "[Deploy] Unknown environment: #{env_key}"
    return [200, { status: "ignored", reason: "unknown environment" }.to_json]
  end

  # Check environment ownership — only deploy if this machine owns the env
  env_owner = deploy_config[env_key]["owner"]
  unless env_owner && env_owner.downcase == AI_AGENT_NAME.downcase
    LOG.info "[Deploy] Skipping #{env_key} — owner is #{env_owner.inspect}, this machine is #{AI_AGENT_NAME}"
    return [200, { status: "ignored", reason: env_owner ? "owned by #{env_owner}" : "no owner configured" }.to_json]
  end

  worktree = card_info&.dig("worktree")
  card_number = card_info&.dig("number")

  # If worktree doesn't exist locally, try to clone the branch from origin
  if worktree.nil? || !File.directory?(worktree)
    result = clone_branch_for_deploy(eventable, card_internal_id, card_info)
    unless result
      LOG.warn "[Deploy] Could not resolve or clone branch for card #{card_internal_id}"
      return [200, { status: "ignored", reason: "no worktree and could not clone branch" }.to_json]
    end
    worktree = result[:worktree]
    card_number = result[:card_number]
  end

  deploy_script = File.join(worktree, "scripts", "deploy.sh")
  unless File.exist?(deploy_script)
    LOG.warn "[Deploy] No deploy script at #{deploy_script}"
    return [200, { status: "ignored", reason: "no deploy script" }.to_json]
  end

  LOG.info "[Deploy] Deploying card ##{card_number} worktree to #{env_key}"

  # Mark environment as deploying (for waybar yellow/orange border)
  mark_deploying(env_key, worktree_path: worktree)

  # React with 🚀 (deploying) and run deploy in background
  Thread.new do
    # Add pending reaction
    run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s,
            "--comment", comment_id.to_s, "--content", "🚀",
            chdir: worktree, env: default_fizzy_env)

    # Build deploy environment (inject AWS_PROFILE if configured)
    deploy_env = {}
    aws_profile = DEPLOYMENTS_CONFIG.dig("environments", env_key, "aws_profile")
    deploy_env["AWS_PROFILE"] = aws_profile if aws_profile

    # Run deploy (with terraform lock file retry)
    stdout, stderr, status = Open3.capture3(deploy_env, "./scripts/deploy.sh", env_key, chdir: worktree)

    if !status.success? && terraform_lock_error?(stdout, stderr)
      LOG.info "[Deploy] Terraform lock file mismatch for card ##{card_number} — retrying with init -upgrade"
      infra_dir = File.join(worktree, "infrastructure", env_key)
      lock_file = File.join(infra_dir, ".terraform.lock.hcl")
      FileUtils.rm_f(lock_file)
      Open3.capture3(deploy_env, "terraform", "init", "-upgrade", chdir: infra_dir) if File.directory?(infra_dir)
      stdout, stderr, status = Open3.capture3(deploy_env, "./scripts/deploy.sh", env_key, chdir: worktree)
    end

    if status.success?
      LOG.info "[Deploy] Successfully deployed card ##{card_number} to #{env_key}"
      run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s,
              "--comment", comment_id.to_s, "--content", "✅",
              chdir: worktree, env: default_fizzy_env)
      deploy_to_environment(env_key, worktree_path: worktree, deployed_by: "fizzy-comment")
    else
      LOG.error "[Deploy] Failed deploying card ##{card_number} to #{env_key}: #{stderr}"
      run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s,
              "--comment", comment_id.to_s, "--content", "❌",
              chdir: worktree, env: default_fizzy_env)
      record_deploy_failure(env_key, worktree_path: worktree, stdout: stdout, stderr: stderr)
    end
  rescue StandardError => e
    LOG.error "[Deploy] Error deploying card ##{card_number} to #{env_key}: #{e.message}"
    begin
      run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s,
              "--comment", comment_id.to_s, "--content", "❌",
              chdir: worktree, env: default_fizzy_env)
    rescue StandardError => inner
      LOG.warn "[Deploy] Could not add failure reaction: #{inner.message}"
    end
  end

  [200, { status: "deploying", card: card_number, env: env_key }.to_json]
end

# Clone a remote branch locally for deploy when the worktree doesn't exist on this machine.
# Returns { worktree:, card_number: } on success, nil on failure.
def clone_branch_for_deploy(eventable, card_internal_id, card_info)
  # Resolve project from card tags
  card_tags = eventable.dig("card", "tags") || []
  project_result = identify_project_by_tags(card_tags)
  unless project_result
    LOG.warn "[Deploy] Cannot identify project for card #{card_internal_id}"
    return nil
  end
  project_key, project_config = project_result
  repo_path = project_config["repo_path"]

  # Resolve card number
  card_number = card_info&.dig("number")
  card_number ||= resolve_card_number(card_internal_id, repo_path: repo_path)
  unless card_number
    LOG.warn "[Deploy] Cannot resolve card number for #{card_internal_id}"
    return nil
  end

  # Fetch latest and find the branch on origin matching fizzy-<card_number>-*
  debounced_repo_fetch(repo_path)
  branches = run_cmd("git", "branch", "-r", "--list", "origin/fizzy-#{card_number}-*", chdir: repo_path).strip
  branch = branches.lines.map(&:strip).first&.sub("origin/", "")
  unless branch
    LOG.warn "[Deploy] No remote branch matching fizzy-#{card_number}-* found"
    return nil
  end

  # Create worktree from the remote branch
  worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{branch}")

  unless File.directory?(worktree_path)
    branch_exists_locally = system("git", "rev-parse", "--verify", branch, chdir: repo_path, out: File::NULL, err: File::NULL)
    if branch_exists_locally
      run_cmd("git", "worktree", "add", worktree_path, branch, chdir: repo_path)
    else
      run_cmd("git", "worktree", "add", "--track", "-b", branch, worktree_path, "origin/#{branch}", chdir: repo_path)
    end

    trust_version_manager(worktree_path, chdir: worktree_path)
    apply_worktree_includes(repo_path, worktree_path)
    run_project_hook(repo_path, "worktree-setup", extra_env: { "WORKTREE_PATH" => worktree_path })
  end

  # Update card map
  map = load_card_map
  map[card_internal_id] ||= {}
  map[card_internal_id].merge!("number" => card_number, "branch" => branch, "worktree" => worktree_path, "project" => project_key)
  save_card_map(map)

  LOG.info "[Deploy] Cloned branch #{branch} into worktree #{worktree_path} for card ##{card_number}"
  { worktree: worktree_path, card_number: card_number }
rescue StandardError => e
  LOG.error "[Deploy] Failed to clone branch for card #{card_internal_id}: #{e.message}"
  nil
end

def handle_comment(payload)
  eventable = payload["eventable"] || {}
  plain_text = eventable.dig("body", "plain_text") || ""
  card_internal_id = eventable.dig("card", "id")

  # --- Deploy shortcut: comment is just "dev02" (or any dev\d+) ---
  return handle_deploy_comment(eventable, plain_text.strip.downcase, card_internal_id) if plain_text.strip.match?(/\Adev\d+\z/i)

  # Detect which agent (if any) is @mentioned in the comment
  mentioned_agent = detect_mentioned_agent(plain_text)

  # Check if any humans are @mentioned — if so, skip agent dispatch
  mentioned_user_ids = detect_mentioned_user_ids(plain_text)
  if mentioned_user_ids.any? { |id| human_mentioned?(id) }
    LOG.info "[Fizzy] Human @mentioned in comment, skipping agent dispatch"
    return [200, { status: "ignored", reason: "human mentioned" }.to_json]
  end

  # If an agent is mentioned but not local to this machine, ignore the comment.
  # This prevents multiple machines from dispatching the same agent mention.
  if mentioned_agent && !local_agent_names.include?(mentioned_agent)
    LOG.info "[Fizzy] Ignoring mention of non-local agent #{mentioned_agent}"
    return [200, { status: "ignored", reason: "non-local agent mentioned" }.to_json]
  end

  mentioned = !mentioned_agent.nil?

  creator_name = eventable.dig("creator", "name")
  creator_id = eventable.dig("creator", "id")
  creator_is_agent = comment_from_agent?(creator_name)

  # Also check the top-level event creator in case the payload structure differs
  event_creator_name = payload.dig("creator", "name")
  creator_is_agent ||= comment_from_agent?(event_creator_name)

  # Ignore comments created via API (likely by us via fizzy CLI)
  source = eventable["source"] || payload["source"]
  is_api_sourced = source && source != "web"

  # --- Authorization check (must happen before agent logic) ---
  # Human comments must be from authorized users
  unless creator_is_agent || is_api_sourced
    unless AUTHORIZED_USER_IDS.include?(creator_id)
      notify_unauthorized("comment_created", creator_name, "card #{card_internal_id}")
      return [200, { status: "ignored", reason: "unauthorized" }.to_json]
    end
    # Human comment — reset the dispatch depth counter for this card
    record_human_comment(card_internal_id)

    # --- Cancel detection (human-only, before any dispatch logic) ---
    cancel_keywords = %w[cancel stop halt abort kill ❌]
    if cancel_keywords.include?(plain_text.strip.downcase)
      killed = 0
      card_number_for_cancel = load_card_map.dig(card_internal_id, "number")
      prefixes = ["card-#{card_internal_id}"]
      prefixes << "card-#{card_number_for_cancel}" if card_number_for_cancel

      ACTIVE_SESSIONS_MUTEX.synchronize do
        ACTIVE_SESSIONS.keys.select { |k| prefixes.any? { |p| k == p || k.start_with?("#{p}-") } }.each do |key|
          info = ACTIVE_SESSIONS[key]
          next unless info

          begin
            Process.kill("KILL", info[:pid])
            LOG.info "[Fizzy] Cancelled session #{key} (PID: #{info[:pid]})"
          rescue Errno::ESRCH, Errno::EPERM => e
            LOG.warn "[Fizzy] Could not kill #{key}: #{e.message}"
          end
          archive_session(key, info)
          ACTIVE_SESSIONS.delete(key)
          killed += 1
        end
      end

      # Add 🛑 reaction to the cancel comment
      comment_id_for_cancel = eventable["id"]
      card_info_for_cancel = load_card_map[card_internal_id]
      if card_info_for_cancel && card_number_for_cancel && comment_id_for_cancel
        repo = (card_info_for_cancel["project"] && PROJECTS.dig(card_info_for_cancel["project"], "repo_path")) || DEFAULT_PROJECT["repo_path"]
        Thread.new do
          run_cmd("fizzy", "reaction", "create", "--card", card_number_for_cancel.to_s, "--comment", comment_id_for_cancel.to_s, "--content", "🛑",
                  chdir: repo, env: default_fizzy_env)
        rescue StandardError => e
          LOG.warn "[Fizzy] Could not add 🛑 reaction: #{e.message}"
        end
      end

      LOG.info "[Fizzy] Cancel command received for card #{card_number_for_cancel || card_internal_id}: killed #{killed} session(s)"
      return [200, { status: "cancelled", card: card_number_for_cancel || card_internal_id, sessions_killed: killed }.to_json]
    end
  end

  # --- Agent comment validation ---
  # Agents can only act on cards where they're assigned or explicitly @mentioned.
  # This prevents agents from hijacking unrelated cards.
  if creator_is_agent || is_api_sourced
    card_info = load_card_map[card_internal_id]
    card_assigned_agent = card_info&.dig("agent")

    # Agent is allowed if:
    # 1. They're assigned to this card, OR
    # 2. They're explicitly @mentioned in this comment
    agent_is_assigned = card_assigned_agent && card_assigned_agent.downcase == (creator_name || "").downcase
    agent_is_mentioned = mentioned_agent && mentioned_agent.downcase == (creator_name || "").downcase

    unless agent_is_assigned || agent_is_mentioned
      LOG.info "Blocking agent comment from #{creator_name} on card #{card_internal_id}: not assigned and not mentioned"
      return [200, { status: "ignored", reason: "agent not assigned or mentioned" }.to_json]
    end

    # --- Agent-to-agent loop prevention ---
    # If the agent is @mentioning a *different* agent, check dispatch depth
    if mentioned_agent && mentioned_agent.downcase != (creator_name || "").downcase
      unless agent_dispatch_allowed?(card_internal_id)
        LOG.info "Blocking agent-to-agent dispatch on card #{card_internal_id}: depth limit reached (#{creator_name} → @#{mentioned_agent})"
        return [200, { status: "ignored", reason: "agent-to-agent depth limit" }.to_json]
      end
      LOG.info "Allowing agent-to-agent dispatch on card #{card_internal_id}: #{creator_name} → @#{mentioned_agent}"
      # Fall through — this agent mention will be processed below
    elsif !mentioned_agent
      # Agent comment with no @mention — this is a self-comment, ignore it
      LOG.info "Ignoring self-comment from #{creator_name} on card #{card_internal_id}"
      return [200, { status: "ignored", reason: "self-comment" }.to_json]
    end
    # If mentioned_agent == creator_name, that's the agent mentioning themselves,
    # which is weird but harmless — let it through (will be handled as self-comment below)
  end

  comment_id = eventable["id"]
  card_info = load_card_map[card_internal_id]

  return [200, { status: "ignored", reason: "not relevant" }.to_json] unless mentioned || card_info

  # Get project config from card_info or detect from tags
  project_config = nil
  project_key = nil

  if card_info
    if card_info["project"]
      project_key = card_info["project"]
      project_config = PROJECTS[project_key] || DEFAULT_PROJECT
    else
      # card_info exists but was registered before project tracking — resolve from tags
      card_tags = eventable.dig("card", "tags") || []
      project_result = identify_project_by_tags(card_tags)
      if project_result
        project_key, project_config = project_result
        # Backfill the project key into the card map
        card_info["project"] = project_key
        map = load_card_map
        map[card_internal_id] = card_info
        save_card_map(map)
        LOG.info "Backfilled project '#{project_key}' for card #{card_internal_id} in card map"
      else
        LOG.warn "No project found for card #{card_internal_id}"
        return [200, { status: "ignored", reason: "no matching project" }.to_json]
      end
    end
  elsif mentioned
    # Try to detect project from card tags
    card_tags = eventable.dig("card", "tags") || []
    project_result = identify_project_by_tags(card_tags)
    if project_result
      project_key, project_config = project_result
    else
      LOG.warn "No project found for mentioned card #{card_internal_id}"
      return [200, { status: "ignored", reason: "no matching project" }.to_json]
    end
  end

  # Check for [deploy] or [deploy:envN] tag — triggers auto-deploy after agent session
  deploy_intent = nil
  if (deploy_match = plain_text.match(/\[deploy(?::([^\]]+))?\]/i))
    deploy_intent = deploy_match[1]&.strip&.downcase || :auto # :auto means "auto-detect env"
    plain_text = plain_text.sub(deploy_match[0], "").strip
    LOG.info "[Deploy] Detected [deploy#{":#{deploy_intent}" unless deploy_intent == :auto}] tag on card #{card_internal_id}"
  end

  # Strip [effort:X] tag from prompt content (detect_effort reads from original text via tags + inline)
  effort_text_for_detection = plain_text
  plain_text = plain_text.sub(/\[effort:\w+\]/i, "").strip

  # Check for [worktree:branch-name] override in comment text — lets you direct
  # Galen to a specific branch/worktree instead of the one in the card map.
  worktree_override = nil
  if (wt_match = plain_text.match(/\[worktree:([^\]]+)\]/))
    override_branch = wt_match[1].strip
    repo_path_for_override = project_config["repo_path"]
    candidate = File.join(File.dirname(repo_path_for_override), "#{File.basename(repo_path_for_override)}--#{override_branch}")
    if File.directory?(candidate)
      worktree_override = { "branch" => override_branch, "worktree" => candidate }
      LOG.info "Worktree override requested: #{override_branch} -> #{candidate}"
    else
      LOG.warn "Worktree override branch '#{override_branch}' not found at #{candidate}, ignoring"
    end
  end

  model = detect_model(project_config, text: plain_text)
  effort = detect_effort(project_config, tags: tags, text: effort_text_for_detection)

  # Determine which agent should handle this comment.
  #
  # Only local agents (marked with "local": true in ~/.brainiac/agents.json or
  # discovered from ~/.kiro/agents/*.json configs) can be dispatched on this machine.
  # Non-local agents are filtered out earlier in the flow.
  #
  # - If @Galen is mentioned and Galen is local, dispatch Galen
  # - If no agent is mentioned but the card is in our card_map, the card's assigned agent handles it
  # - If the mentioned agent differs from the card's assigned agent, it's a cross-agent review
  card_assigned_agent = card_info&.dig("agent")

  # When card_info is nil (card not in map), try to resolve the assigned agent
  # from the webhook payload's card assignees. This handles reactivated cards
  # or cards that were cleared from the map.
  if card_assigned_agent.nil?
    card_assignees = eventable.dig("card", "assignees") || []
    webhook_agent = card_assignees.map { |a| a["name"] }.find { |name| local_agent_names.include?(name) }

    # Webhook payload often lacks assignees — query Fizzy API as fallback
    if webhook_agent.nil? && project_config
      api_card_number = card_info&.dig("number") || eventable.dig("card", "number")
      if api_card_number
        begin
          output = run_cmd("fizzy", "card", "show", api_card_number.to_s, chdir: project_config["repo_path"], env: default_fizzy_env)
          api_assignees = begin
            JSON.parse(output).dig("data", "assignees") || []
          rescue StandardError
            []
          end
          webhook_agent = api_assignees.map { |a| a["name"] }.find { |name| local_agent_names.include?(name) }
          LOG.info "Resolved assigned agent '#{webhook_agent}' via Fizzy API for card ##{api_card_number}" if webhook_agent
        rescue StandardError => e
          LOG.warn "Fizzy API fallback failed for card ##{api_card_number}: #{e.message}"
        end
      end
    end

    if webhook_agent
      card_assigned_agent = webhook_agent
      # Backfill the card map so subsequent comments work without this fallback
      map = load_card_map
      map[card_internal_id] ||= {}
      map[card_internal_id]["agent"] = webhook_agent
      save_card_map(map)
      LOG.info "Backfilled agent '#{webhook_agent}' into card map for #{card_internal_id}"
    end
  end

  if mentioned_agent
    agent_name = mentioned_agent
    # If the mentioned agent differs from the card's assigned agent, this is a
    # cross-agent mention (e.g. "@Galen what do you think?" on Kaylee's card).
    # The mentioned agent should review/discuss, not take over the card's worktree.
    is_cross_agent_mention = !card_assigned_agent || card_assigned_agent != mentioned_agent
  else
    # If no agent is assigned and none was mentioned, don't fall back to the
    # project default — that causes orphaned card map entries to dispatch the
    # wrong agent (e.g. Kaylee getting triggered on Sheogorath's card).
    unless card_assigned_agent
      LOG.info "Skipping card #{card_internal_id} — no assigned agent and no mention"
      return [200, { status: "ignored", reason: "no assigned agent" }.to_json]
    end
    agent_name = card_assigned_agent
    is_cross_agent_mention = false
  end

  # Per-card comment cooldown — suppress rapid-fire near-duplicate triggers.
  # Include agent name in the key so cross-agent mentions don't block each other.
  cooldown_key = "card-#{card_info ? (card_info["number"] || card_internal_id) : card_internal_id}-#{agent_name.downcase}"
  if on_comment_cooldown?(cooldown_key)
    LOG.info "Skipping comment on #{cooldown_key} — within #{COMMENT_COOLDOWN}s cooldown"
    return [200, { status: "ignored", reason: "comment cooldown" }.to_json]
  end
  touch_comment_cooldown(cooldown_key)

  # Common template vars for the triggering comment
  comment_vars = {
    "COMMENT_CREATOR" => creator_name || "Unknown",
    "COMMENT_ID" => comment_id.to_s,
    "COMMENT_BODY" => plain_text
  }

  # --- Cross-agent mention: an agent is tagged on a card owned by a different agent ---
  # e.g. Kaylee is working on card #42, Andy comments "@Galen what do you think?"
  # Galen reviews and responds without touching Kaylee's worktree.
  # Also handles: SecurityBot tagged on Galen's card to audit the code.
  if is_cross_agent_mention
    # Skip dispatch when the comment is a card creation/assignment announcement.
    # The Fizzy webhook handles card assignments — dispatching here too causes
    # the mentioned agent to respond on the *original* card instead of the new one.
    if creator_is_agent && (plain_text.match?(/created\s+card\s+#?\d+/i) || plain_text.match?(/assigned\s+.*card\s+#?\d+/i) || plain_text.match?(/card\s+#?\d+.*assigned/i))
      LOG.info "Ignoring cross-agent mention from #{creator_name} on card #{card_internal_id} — Fizzy card creation/assignment (handled by webhook)"
      return [200, { status: "ignored", reason: "card creation announcement" }.to_json]
    end

    card_number = card_info&.dig("number")

    # Resolve card_number if missing
    if card_number.nil?
      card_number = resolve_card_number(card_internal_id, repo_path: project_config["repo_path"])
      if card_number
        map = load_card_map
        map[card_internal_id] ||= {}
        map[card_internal_id]["number"] = card_number
        save_card_map(map)
      end
    end

    card_key = "card-#{card_number || card_internal_id}-#{agent_name.downcase}"
    if creator_is_agent && session_active?(card_key)
      unless wait_for_session?(card_key)
        LOG.info "Giving up on cross-agent dispatch for #{agent_name} on card #{card_number || card_internal_id} — session didn't finish in time"
        return [200, { status: "ignored", reason: "session wait timeout" }.to_json]
      end
    elsif session_active?(card_key)
      LOG.info "Skipping cross-agent mention for #{agent_name} on card #{card_number || card_internal_id} — session already active"
      return [200, { status: "ignored", reason: "session already active" }.to_json]
    end

    LOG.info "Cross-agent mention: #{agent_name} tagged on #{card_assigned_agent}'s card ##{card_number || card_internal_id} (project: #{project_key})"

    # Record this agent-to-agent dispatch for loop prevention
    record_agent_dispatch(card_internal_id) if creator_is_agent

    # React in background — don't block the dispatch path
    Thread.new do
      if card_number
        run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--comment", comment_id.to_s, "--content", "👀",
                chdir: project_config["repo_path"], env: fizzy_env_for(agent_name))
        LOG.info "Added 👀 reaction to comment ##{comment_id} for #{agent_name}"
      end
    rescue StandardError => e
      LOG.warn "Could not add reaction to comment: #{e.message}"
    end

    # Create a worktree for the cross-agent reviewer so they don't clobber the
    # main repo's working tree (or the assigned agent's worktree).
    repo_path = project_config["repo_path"]
    review_branch = "#{agent_name.downcase}/fizzy-#{card_number}-#{slugify(card_info&.dig("title") || eventable.dig("card", "title") || "review")}"
    review_worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{review_branch.tr("/", "-")}")

    debounced_repo_fetch(repo_path)

    # Reuse existing worktree or create a new one
    if File.directory?(review_worktree_path)
      worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)
      FileUtils.rm_rf(review_worktree_path) unless worktree_list.include?(review_worktree_path)
    end

    if File.directory?(review_worktree_path)
      LOG.info "Reusing existing cross-agent review worktree at #{review_worktree_path}"
    else
      # Branch from the card's branch if it exists, otherwise from origin default
      card_branch = card_info&.dig("branch")
      branch_exists = card_branch && system("git", "rev-parse", "--verify", card_branch, chdir: repo_path, out: File::NULL, err: File::NULL)
      base_ref = branch_exists ? card_branch : "origin/#{get_default_branch(repo_path)}"

      # Delete stale local branch if it exists (from a previous review)
      if system("git", "rev-parse", "--verify", review_branch, chdir: repo_path, out: File::NULL, err: File::NULL)
        run_cmd("git", "branch", "-D", review_branch, chdir: repo_path)
      end

      run_cmd("git", "worktree", "add", "-b", review_branch, review_worktree_path, base_ref, chdir: repo_path)
      trust_version_manager(review_worktree_path, chdir: review_worktree_path)
      apply_worktree_includes(repo_path, review_worktree_path)
      run_project_hook(repo_path, "worktree-setup", extra_env: { "WORKTREE_PATH" => review_worktree_path })
      LOG.info "Created cross-agent review worktree at #{review_worktree_path} (base: #{base_ref})"
    end

    card_context = prefetch_card_context(card_number, repo_path: repo_path, agent_name: agent_name)

    prompt = render_prompt(PROMPT_CROSS_AGENT_REVIEW,
                           comment_vars.merge(
                             "CARD_NUMBER" => card_number || "N/A",
                             "CARD_INTERNAL_ID" => card_internal_id,
                             "CARD_ID" => card_number || card_internal_id,
                             "CARD_AGENT" => card_assigned_agent,
                             "WORKTREE_PATH" => review_worktree_path,
                             "BRANCH" => review_branch
                           ),
                           brain_context: build_brain_context(agent_name: agent_name, card_number: card_number, project_key: project_key, comment_body: plain_text,
                                                              source: :fizzy),
                           card_context: card_context,
                           agent_name: agent_name)

    pid, log_file = run_agent(prompt, project_config: project_config, chdir: review_worktree_path,
                                      log_name: "review-#{agent_name.downcase}-#{card_number || card_internal_id}", model: model, effort: effort, agent_name: agent_name,
                                      card_number: card_number, comment_id: comment_id,
                                      source: :fizzy, source_context: { card_number: card_number })
    register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: agent_name)

    return [200, { status: "cross_agent_review", agent: agent_name, card_agent: card_assigned_agent,
                   card: card_number, card_internal_id: card_internal_id, project: project_key, worktree: review_worktree_path }.to_json]
  end

  if card_info || worktree_override
    # Merge worktree override into card_info if provided
    effective_info = worktree_override ? (card_info || {}).merge(worktree_override) : card_info
    card_number = effective_info["number"]
    worktree = effective_info["worktree"]

    # Resolve card_number if missing from the map entry
    if card_number.nil?
      card_number = resolve_card_number(card_internal_id, repo_path: project_config["repo_path"])
      if card_number
        # Backfill into card map for next time
        map = load_card_map
        map[card_internal_id] ||= {}
        map[card_internal_id]["number"] = card_number
        save_card_map(map)
        LOG.info "Backfilled card number #{card_number} for #{card_internal_id}"
      end
    end

    # If worktree is missing or gone, try to find one by card number on disk
    if !(worktree && File.directory?(worktree)) && card_number
      repo_dir = File.dirname(project_config["repo_path"])
      repo_base = File.basename(project_config["repo_path"])
      candidates = Dir.glob(File.join(repo_dir, "#{repo_base}--fizzy-#{card_number}-*")).select { |d| File.directory?(d) }
      if candidates.any?
        worktree = candidates.first
        branch_name = File.basename(worktree).sub("#{repo_base}--", "")
        # Backfill worktree + branch into card map
        map = load_card_map
        map[card_internal_id] ||= {}
        map[card_internal_id].merge!("worktree" => worktree, "branch" => branch_name)
        save_card_map(map)
        LOG.info "Found worktree by card number scan: #{worktree} (branch: #{branch_name})"
      end
    end

    work_dir = worktree && File.directory?(worktree) ? worktree : project_config["repo_path"]
    card_key = "card-#{card_number || card_internal_id}"

    # If an agent tagged this card's own agent back (e.g. GLaDOS tags @Galen on
    # Galen's card), the original agent may still be running. Wait for it to finish
    # rather than dropping the dispatch — the depth system already validated this.
    if creator_is_agent && session_active?(card_key)
      unless wait_for_session?(card_key)
        LOG.info "Giving up on agent-to-agent dispatch for card #{card_number || card_internal_id} — session didn't finish in time"
        return [200, { status: "ignored", reason: "session wait timeout" }.to_json]
      end
    elsif session_active?(card_key)
      # Supersede: if the human comments within 60s, kill the previous run and start fresh
      prev = find_supersedable_session(card_key)
      if prev
        LOG.info "Superseding session on card #{card_number || card_internal_id} (pid: #{prev[:pid]}) — human follow-up within #{SUPERSEDE_WINDOW}s"
        kill_session(prev[:session_key])
        # Fall through to dispatch fresh below
      else
        # After 60s: queue and wait for the active session to finish, then dispatch
        LOG.info "Queuing follow-up comment on card #{card_number || card_internal_id} — waiting for active session to finish"

        # React immediately so the human knows we saw it
        Thread.new do
          run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--comment", comment_id.to_s, "--content", "👍", chdir: work_dir,
                                                                                                                             env: fizzy_env_for(agent_name))
          LOG.info "Added 👍 reaction to queued comment ##{comment_id} as #{agent_name}"
        rescue StandardError => e
          LOG.warn "Could not add reaction to queued comment: #{e.message}"
        end

        Thread.new do
          unless wait_for_session?(card_key)
            LOG.warn "Giving up on queued follow-up for card #{card_number || card_internal_id} — session didn't finish in time"
            next
          end

          LOG.info "Active session finished, dispatching queued follow-up for card #{card_number || card_internal_id}"
          dispatch_followup_comment(
            card_key: card_key, card_number: card_number, card_internal_id: card_internal_id,
            work_dir: work_dir, project_config: project_config, project_key: project_key,
            comment_vars: comment_vars, plain_text: plain_text, model: model,
            agent_name: agent_name, comment_id: comment_id, eventable: eventable,
            deploy_intent: deploy_intent
          )
        end

        return [200, { status: "queued", card: card_number, card_internal_id: card_internal_id, reason: "waiting for active session" }.to_json]
      end
    end

    LOG.info "Follow-up comment on card #{card_number || card_internal_id} (project: #{project_key}), worktree: #{work_dir}"

    # React in background — don't block the dispatch path
    Thread.new do
      run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--comment", comment_id.to_s, "--content", "👍", chdir: work_dir,
                                                                                                                         env: fizzy_env_for(agent_name))
      LOG.info "Added 👍 reaction to comment ##{comment_id} as #{agent_name}"
    rescue StandardError => e
      LOG.warn "Could not add reaction to comment: #{e.message}"
    end

    result = dispatch_followup_comment(
      card_key: card_key, card_number: card_number, card_internal_id: card_internal_id,
      work_dir: work_dir, project_config: project_config, project_key: project_key,
      comment_vars: comment_vars, plain_text: plain_text, model: model,
      agent_name: agent_name, comment_id: comment_id, eventable: eventable,
      deploy_intent: deploy_intent
    )
    [200, result.to_json]
  else
    # Get card data to extract number and title
    card_data = eventable["card"] || {}
    card_number = card_data["number"]
    card_title = card_data["title"] || "exploration"

    # If card_number is missing from the webhook payload, resolve it via fizzy CLI,
    # falling back to the card map as a cheap cache.
    if card_number.nil?
      map_entry = load_card_map[card_internal_id]
      if map_entry && map_entry["number"]
        card_number = map_entry["number"]
        LOG.info "Resolved card number #{card_number} from card map for internal_id #{card_internal_id}"
      else
        card_number = resolve_card_number(card_internal_id, repo_path: project_config["repo_path"])
      end
    end

    LOG.info "#{agent_name} mentioned on card (internal_id: #{card_internal_id}, project: #{project_key}), creating exploration worktree"

    # Record agent-to-agent dispatch for loop prevention
    record_agent_dispatch(card_internal_id) if creator_is_agent

    card_key = "card-#{card_number || card_internal_id}"
    if session_active?(card_key)
      LOG.info "Skipping mention on card #{card_number || card_internal_id} — agent session already active"
      return [200, { status: "ignored", reason: "session already active" }.to_json]
    end

    # React in background — don't block the dispatch path
    Thread.new do
      if card_number
        run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--comment", comment_id.to_s, "--content", "👀",
                chdir: project_config["repo_path"], env: fizzy_env_for(agent_name))
        LOG.info "Added 👀 reaction to comment ##{comment_id} as #{agent_name}"
      else
        LOG.warn "Could not add reaction: card number not available in webhook payload or card map"
      end
    rescue StandardError => e
      LOG.warn "Could not add reaction to comment: #{e.message}"
    end

    # Create exploration branch and worktree
    repo_path = project_config["repo_path"]

    # Check if the card already has a branch/worktree in the map (e.g. registered
    # by a previous assign event). If so, reuse it rather than spinning up a new one.
    # Also check by card number in case the map entry predates project tracking.
    existing_map_entry = load_card_map[card_internal_id]

    # If the map entry has a valid worktree, use it directly
    if existing_map_entry && existing_map_entry["branch"] && existing_map_entry["worktree"] &&
       File.directory?(existing_map_entry["worktree"])
      branch = existing_map_entry["branch"]
      worktree_path = existing_map_entry["worktree"]
      LOG.info "Reusing existing worktree from card map: #{worktree_path} (branch: #{branch})"
    elsif card_number
      # Map entry missing or stale — scan for any worktree directory matching fizzy-NNN-*
      repo_dir = File.dirname(repo_path)
      repo_base = File.basename(repo_path)
      pattern = File.join(repo_dir, "#{repo_base}--fizzy-#{card_number}-*")
      candidates = Dir.glob(pattern).select { |d| File.directory?(d) }
      if candidates.any?
        worktree_path = candidates.first
        branch = File.basename(worktree_path).sub("#{repo_base}--", "")
        LOG.info "Found existing worktree by card number scan: #{worktree_path} (branch: #{branch})"
      end
    end

    if worktree_path && File.directory?(worktree_path)
      LOG.info "Reusing worktree at #{worktree_path} (branch: #{branch})"

      map = load_card_map
      map[card_internal_id] ||= {}
      map[card_internal_id].merge!("number" => card_number, "branch" => branch, "worktree" => worktree_path, "project" => project_key,
                                   "agent" => agent_name)
      save_card_map(map)

      # Detect planning mode
      card_tags = eventable.dig("card", "tags") || []
      planning_info = detect_planning_mode(
        text: plain_text,
        tags: card_tags,
        card_internal_id: card_internal_id,
        card_number: card_number
      )

      prompt = if planning_info
                 # Planning mode
                 card_id = planning_info[:card_id]
                 LOG.info "[Planning] Planning mode active for mention on card #{card_number || card_internal_id}"

                 render_planning_prompt(PROMPT_MENTION,
                                        comment_vars.merge(
                                          "CARD_INTERNAL_ID" => card_internal_id,
                                          "CARD_ID" => card_id,
                                          "CARD_NUMBER" => card_number || "N/A",
                                          "CARD_NUMBER_TEXT" => card_number ? " (##{card_number})" : "",
                                          "BRANCH" => branch
                                        ),
                                        brain_context: build_brain_context(agent_name: agent_name, card_title: card_title, card_number: card_number, project_key: project_key,
                                                                           comment_body: plain_text, source: :fizzy),
                                        card_context: prefetch_card_context(card_number, repo_path: worktree_path, agent_name: agent_name),
                                        agent_name: agent_name)
               else
                 render_prompt(PROMPT_MENTION,
                               comment_vars.merge(
                                 "CARD_INTERNAL_ID" => card_internal_id,
                                 "CARD_ID" => card_number || card_internal_id,
                                 "CARD_NUMBER" => card_number || "N/A",
                                 "CARD_NUMBER_TEXT" => card_number ? " (##{card_number})" : "",
                                 "BRANCH" => branch
                               ),
                               brain_context: build_brain_context(agent_name: agent_name, card_title: card_title, card_number: card_number, project_key: project_key,
                                                                  comment_body: plain_text, source: :fizzy),
                               card_context: prefetch_card_context(card_number, repo_path: worktree_path, agent_name: agent_name),
                               agent_name: agent_name)
               end

      pid, log_file = run_agent(prompt, project_config: project_config, chdir: worktree_path, log_name: "mention-#{card_number || card_internal_id}", model: model, effort: effort, agent_name: agent_name, card_number: card_number, comment_id: comment_id,
                                        source: :fizzy, source_context: { card_number: card_number })
      register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: agent_name)
      return [200,
              { status: "responded", card_internal_id: card_internal_id, card_number: card_number, branch: branch, worktree: worktree_path,
                project: project_key }.to_json]
    end

    branch = card_number ? "fizzy-#{card_number}-#{slugify(card_title)}" : "fizzy-explore-#{card_internal_id[0..7]}"

    # Fetch latest from origin (doesn't touch working tree)
    debounced_repo_fetch(repo_path)

    # Create worktree (handle existing branch)
    worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{branch}")

    # Get current worktree list once
    worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)

    # Check if worktree directory exists but is orphaned (not tracked by git)
    if File.directory?(worktree_path)
      is_tracked = worktree_list.include?(worktree_path)

      if is_tracked
        LOG.info "Worktree directory #{worktree_path} is tracked by git"
      else
        LOG.warn "Orphaned worktree directory found at #{worktree_path}, removing it"
        begin
          FileUtils.rm_rf(worktree_path)
          LOG.info "Successfully removed orphaned directory"
        rescue StandardError => e
          LOG.error "Failed to remove orphaned directory: #{e.message}"
          raise
        end
      end
    end

    # Check if branch already exists
    branch_exists = system("git", "rev-parse", "--verify", branch, chdir: repo_path, out: File::NULL, err: File::NULL)

    if branch_exists
      LOG.info "Branch #{branch} already exists, checking for existing worktree"

      # Check if worktree already exists for this branch (refresh the list after potential cleanup)
      worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)

      # Parse worktree list - format is: worktree <path>\nHEAD <sha>\nbranch <ref>\n\n
      has_worktree = worktree_list.lines.any? { |line| line.strip == "worktree #{worktree_path}" }

      if has_worktree && File.directory?(worktree_path)
        LOG.info "Reusing existing worktree at #{worktree_path}"
      else
        # Branch exists but no worktree, create worktree from existing branch
        LOG.info "Creating worktree from existing branch #{branch}"
        run_cmd("git", "worktree", "add", worktree_path, branch, chdir: repo_path)
      end
    else
      # Branch doesn't exist, create new branch and worktree from origin
      LOG.info "Creating new exploration branch #{branch} and worktree"
      default_branch = get_default_branch(repo_path)
      run_cmd("git", "worktree", "add", "-b", branch, worktree_path, "origin/#{default_branch}", chdir: repo_path)
    end

    # Trust version manager in the new worktree
    trust_version_manager(worktree_path, chdir: worktree_path)

    # Copy gitignored files and symlink directories per .worktreeinclude / .worktreelink
    apply_worktree_includes(repo_path, worktree_path)

    # Run project-level worktree-setup hook for anything .worktreeinclude/.worktreelink doesn't cover
    run_project_hook(repo_path, "worktree-setup", extra_env: { "WORKTREE_PATH" => worktree_path })

    map = load_card_map
    map[card_internal_id] = {
      "number" => card_number,
      "branch" => branch,
      "worktree" => worktree_path,
      "project" => project_key,
      "agent" => agent_name
    }
    save_card_map(map)

    # Detect planning mode
    card_tags = eventable.dig("card", "tags") || []
    planning_info = detect_planning_mode(
      text: plain_text,
      tags: card_tags,
      card_internal_id: card_internal_id,
      card_number: card_number
    )

    prompt = if planning_info
               # Planning mode
               card_id = planning_info[:card_id]
               LOG.info "[Planning] Planning mode active for mention on card #{card_number || card_internal_id}"

               render_planning_prompt(PROMPT_MENTION,
                                      comment_vars.merge(
                                        "CARD_INTERNAL_ID" => card_internal_id,
                                        "CARD_ID" => card_id,
                                        "CARD_NUMBER" => card_number || "N/A",
                                        "CARD_NUMBER_TEXT" => card_number ? " (##{card_number})" : "",
                                        "BRANCH" => branch
                                      ),
                                      brain_context: build_brain_context(agent_name: agent_name, card_title: card_title, card_number: card_number, project_key: project_key,
                                                                         comment_body: plain_text, source: :fizzy),
                                      card_context: prefetch_card_context(card_number, repo_path: worktree_path, agent_name: agent_name),
                                      agent_name: agent_name)
             else
               render_prompt(PROMPT_MENTION,
                             comment_vars.merge(
                               "CARD_INTERNAL_ID" => card_internal_id,
                               "CARD_ID" => card_number || card_internal_id,
                               "CARD_NUMBER" => card_number || "N/A",
                               "CARD_NUMBER_TEXT" => card_number ? " (##{card_number})" : "",
                               "BRANCH" => branch
                             ),
                             brain_context: build_brain_context(agent_name: agent_name, card_title: card_title, card_number: card_number, project_key: project_key,
                                                                comment_body: plain_text, source: :fizzy),
                             card_context: prefetch_card_context(card_number, repo_path: worktree_path, agent_name: agent_name),
                             agent_name: agent_name)
             end

    pid, log_file = run_agent(prompt, project_config: project_config, chdir: worktree_path, log_name: "mention-#{card_number || card_internal_id}", model: model, effort: effort, agent_name: agent_name, card_number: card_number, comment_id: comment_id,
                                      source: :fizzy, source_context: { card_number: card_number })
    register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: agent_name)
    [200,
     { status: "responded", card_internal_id: card_internal_id, card_number: card_number, branch: branch, worktree: worktree_path,
       project: project_key }.to_json]
  end
end

# Dispatch a follow-up comment to the agent. Extracted so it can be called
# both inline (no active session) and from a queued background thread.
def dispatch_followup_comment(card_key:, card_number:, card_internal_id:, work_dir:, project_config:, project_key:, comment_vars:, plain_text:,
                              model:, agent_name:, comment_id:, eventable:, deploy_intent: nil)
  card_tags = eventable.dig("card", "tags") || []
  planning_info = detect_planning_mode(
    text: plain_text,
    tags: card_tags,
    card_internal_id: card_internal_id,
    card_number: card_number
  )

  prompt = if planning_info
             card_id = planning_info[:card_id]
             LOG.info "[Planning] Planning mode active for card #{card_number || card_internal_id}"

             if work_dir == project_config["repo_path"]
               render_planning_prompt(PROMPT_FOLLOWUP_NO_WORKTREE,
                                      comment_vars.merge("CARD_INTERNAL_ID" => card_internal_id, "CARD_ID" => card_id),
                                      brain_context: build_brain_context(agent_name: agent_name, project_key: project_key, comment_body: plain_text,
                                                                         source: :fizzy),
                                      card_context: prefetch_card_context(card_number, repo_path: project_config["repo_path"],
                                                                                       agent_name: agent_name),
                                      agent_name: agent_name)
             else
               render_planning_prompt(PROMPT_FOLLOWUP_WORKTREE,
                                      comment_vars.merge("CARD_NUMBER" => card_number, "CARD_ID" => card_id),
                                      brain_context: build_brain_context(agent_name: agent_name, card_number: card_number, project_key: project_key, comment_body: plain_text,
                                                                         source: :fizzy),
                                      card_context: prefetch_card_context(card_number, repo_path: work_dir, agent_name: agent_name),
                                      agent_name: agent_name)
             end
           elsif work_dir != project_config["repo_path"]
             render_prompt(PROMPT_FOLLOWUP_WORKTREE,
                           comment_vars.merge("CARD_NUMBER" => card_number, "CARD_ID" => card_number),
                           brain_context: build_brain_context(agent_name: agent_name, card_number: card_number, project_key: project_key, comment_body: plain_text,
                                                              source: :fizzy),
                           card_context: prefetch_card_context(card_number, repo_path: work_dir, agent_name: agent_name),
                           agent_name: agent_name)
           else
             render_prompt(PROMPT_FOLLOWUP_NO_WORKTREE,
                           comment_vars.merge("CARD_INTERNAL_ID" => card_internal_id, "CARD_ID" => card_internal_id),
                           brain_context: build_brain_context(agent_name: agent_name, project_key: project_key, comment_body: plain_text,
                                                              source: :fizzy),
                           card_context: prefetch_card_context(card_number, repo_path: project_config["repo_path"], agent_name: agent_name),
                           agent_name: agent_name)
           end

  pid, log_file = run_agent(prompt, project_config: project_config, chdir: work_dir, log_name: "followup-#{card_number || card_internal_id}", model: model, effort: effort, agent_name: agent_name, card_number: card_number, comment_id: comment_id,
                                    source: :fizzy, source_context: { card_number: card_number, card_internal_id: card_internal_id, deploy_intent: deploy_intent })
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: agent_name)

  # Move card to Right Now — agent is actively working again
  Thread.new { move_card_to_column(card_number, "right_now", project_config: project_config, agent_name: agent_name) }

  { status: "follow_up", card: card_number, card_internal_id: card_internal_id, worktree: work_dir, project: project_key }
end
