# frozen_string_literal: true

# Fizzy comment handler — routes incoming comments to the appropriate dispatch path.
#
# This is the main routing logic for Fizzy card comments:
# - Deploy shortcuts (dev01, dev02, etc.)
# - Cancel commands
# - Cross-agent mentions (@Galen on Kaylee's card)
# - Follow-up comments on existing worktrees
# - New mentions on untracked cards
#
# See also: dispatch_followup_comment at the bottom for the extracted dispatch helper.

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

  # If an agent is mentioned but not local to this machine, ignore
  if mentioned_agent && !local_agent_names.include?(mentioned_agent)
    LOG.info "[Fizzy] Ignoring mention of non-local agent #{mentioned_agent}"
    return [200, { status: "ignored", reason: "non-local agent mentioned" }.to_json]
  end

  mentioned = !mentioned_agent.nil?

  creator_name = eventable.dig("creator", "name")
  creator_id = eventable.dig("creator", "id")
  creator_is_agent = comment_from_agent?(creator_name)
  event_creator_name = payload.dig("creator", "name")
  creator_is_agent ||= comment_from_agent?(event_creator_name)

  # Ignore comments created via API (likely by us via fizzy CLI)
  source = eventable["source"] || payload["source"]
  is_api_sourced = source && source != "web"

  # --- Authorization check ---
  unless creator_is_agent || is_api_sourced
    unless AUTHORIZED_USER_IDS.include?(creator_id)
      notify_unauthorized("comment_created", creator_name, "card #{card_internal_id}")
      return [200, { status: "ignored", reason: "unauthorized" }.to_json]
    end
    record_human_comment(card_internal_id)

    # --- Cancel detection ---
    cancel_keywords = %w[cancel stop halt abort kill ❌]
    return handle_cancel_command(eventable, card_internal_id) if cancel_keywords.include?(plain_text.strip.downcase)
  end

  # --- Agent comment validation ---
  if creator_is_agent || is_api_sourced
    card_info = load_card_map[card_internal_id]
    card_assigned_agent = card_info&.dig("agent")

    agent_is_assigned = card_assigned_agent && card_assigned_agent.downcase == (creator_name || "").downcase
    agent_is_mentioned = mentioned_agent && mentioned_agent.downcase == (creator_name || "").downcase

    unless agent_is_assigned || agent_is_mentioned
      LOG.info "Blocking agent comment from #{creator_name} on card #{card_internal_id}: not assigned and not mentioned"
      return [200, { status: "ignored", reason: "agent not assigned or mentioned" }.to_json]
    end

    # Agent-to-agent loop prevention
    if mentioned_agent && mentioned_agent.downcase != (creator_name || "").downcase
      unless agent_dispatch_allowed?(card_internal_id)
        LOG.info "Blocking agent-to-agent dispatch on card #{card_internal_id}: depth limit reached (#{creator_name} → @#{mentioned_agent})"
        return [200, { status: "ignored", reason: "agent-to-agent depth limit" }.to_json]
      end
      LOG.info "Allowing agent-to-agent dispatch on card #{card_internal_id}: #{creator_name} → @#{mentioned_agent}"
    elsif !mentioned_agent
      LOG.info "Ignoring self-comment from #{creator_name} on card #{card_internal_id}"
      return [200, { status: "ignored", reason: "self-comment" }.to_json]
    end
  end

  comment_id = eventable["id"]
  card_info = load_card_map[card_internal_id]

  return [200, { status: "ignored", reason: "not relevant" }.to_json] unless mentioned || card_info

  # Get project config
  project_config, project_key = resolve_fizzy_project(card_info, card_internal_id, eventable)
  return [200, { status: "ignored", reason: "no matching project" }.to_json] unless project_config

  # Parse inline tags
  tags = parse_inline_tags(plain_text)
  deploy_intent = tags[:deploy_intent]
  LOG.info "[Deploy] Detected [deploy#{":#{deploy_intent}" unless deploy_intent == :auto}] tag on card #{card_internal_id}" if deploy_intent

  # [worktree:branch-name] override — validate directory exists
  worktree_override = nil
  if tags[:worktree_override]
    override_branch = tags[:worktree_override]
    repo_path_for_override = project_config["repo_path"]
    candidate = File.join(File.dirname(repo_path_for_override), "#{File.basename(repo_path_for_override)}--#{override_branch}")
    if File.directory?(candidate)
      worktree_override = { "branch" => override_branch, "worktree" => candidate }
      LOG.info "Worktree override requested: #{override_branch} -> #{candidate}"
    else
      LOG.warn "Worktree override branch '#{override_branch}' not found at #{candidate}, ignoring"
    end
  end

  card_tags = eventable.dig("card", "tags") || []
  model = detect_model(project_config, text: plain_text)
  effort = detect_effort(project_config, tags: card_tags, text: plain_text)
  cli_provider_override = detect_cli_provider(text: plain_text, tags: card_tags)
  plain_text = tags[:clean_text]

  # --- Determine agent ---
  agent_name, is_cross_agent_mention = resolve_comment_agent(
    mentioned_agent: mentioned_agent, card_info: card_info, card_internal_id: card_internal_id,
    eventable: eventable, project_config: project_config, creator_is_agent: creator_is_agent
  )
  return [200, { status: "ignored", reason: "no assigned agent" }.to_json] unless agent_name

  # Per-card comment cooldown
  cooldown_key = "card-#{card_info ? (card_info["number"] || card_internal_id) : card_internal_id}-#{agent_name.downcase}"
  if on_comment_cooldown?(cooldown_key)
    LOG.info "Skipping comment on #{cooldown_key} — within #{COMMENT_COOLDOWN}s cooldown"
    return [200, { status: "ignored", reason: "comment cooldown" }.to_json]
  end
  touch_comment_cooldown(cooldown_key)

  comment_vars = {
    "COMMENT_CREATOR" => creator_name || "Unknown",
    "COMMENT_ID" => comment_id.to_s,
    "COMMENT_BODY" => plain_text
  }

  # --- Cross-agent mention path ---
  if is_cross_agent_mention
    return handle_cross_agent_mention(
      agent_name: agent_name, card_info: card_info, card_internal_id: card_internal_id,
      comment_vars: comment_vars, plain_text: plain_text, model: model, effort: effort,
      project_config: project_config, project_key: project_key, comment_id: comment_id,
      creator_is_agent: creator_is_agent, cli_provider_override: cli_provider_override,
      eventable: eventable
    )
  end

  # --- Follow-up on existing card or new mention ---
  if card_info || worktree_override
    handle_existing_card_comment(
      card_info: card_info, worktree_override: worktree_override, card_internal_id: card_internal_id,
      comment_vars: comment_vars, plain_text: plain_text, model: model, effort: effort,
      project_config: project_config, project_key: project_key, agent_name: agent_name,
      comment_id: comment_id, creator_is_agent: creator_is_agent, deploy_intent: deploy_intent,
      cli_provider_override: cli_provider_override, eventable: eventable
    )
  else
    handle_new_mention(
      agent_name: agent_name, card_internal_id: card_internal_id, eventable: eventable,
      comment_vars: comment_vars, plain_text: plain_text, model: model, effort: effort,
      project_config: project_config, project_key: project_key, comment_id: comment_id,
      creator_is_agent: creator_is_agent, cli_provider_override: cli_provider_override
    )
  end
end

# --- Comment sub-handlers (extracted for readability) ---

def handle_cancel_command(eventable, card_internal_id)
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
  [200, { status: "cancelled", card: card_number_for_cancel || card_internal_id, sessions_killed: killed }.to_json]
end

def resolve_fizzy_project(card_info, card_internal_id, eventable)
  if card_info
    if card_info["project"]
      project_key = card_info["project"]
      project_config = PROJECTS[project_key] || DEFAULT_PROJECT
    else
      card_tags = eventable.dig("card", "tags") || []
      project_result = identify_project_by_tags(card_tags)
      if project_result
        project_key, project_config = project_result
        card_info["project"] = project_key
        map = load_card_map
        map[card_internal_id] = card_info
        save_card_map(map)
        LOG.info "Backfilled project '#{project_key}' for card #{card_internal_id} in card map"
      else
        LOG.warn "No project found for card #{card_internal_id}"
        return [nil, nil]
      end
    end
  else
    card_tags = eventable.dig("card", "tags") || []
    project_result = identify_project_by_tags(card_tags)
    if project_result
      project_key, project_config = project_result
    else
      LOG.warn "No project found for mentioned card #{card_internal_id}"
      return [nil, nil]
    end
  end

  [project_config, project_key]
end

def resolve_comment_agent(mentioned_agent:, card_info:, card_internal_id:, eventable:, project_config:, creator_is_agent:)
  card_assigned_agent = card_info&.dig("agent")

  # Resolve assigned agent from payload or API if missing
  if card_assigned_agent.nil?
    card_assignees = eventable.dig("card", "assignees") || []
    webhook_agent = card_assignees.map { |a| a["name"] }.find { |name| local_agent_names.include?(name) }

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
      map = load_card_map
      map[card_internal_id] ||= {}
      map[card_internal_id]["agent"] = webhook_agent
      save_card_map(map)
      LOG.info "Backfilled agent '#{webhook_agent}' into card map for #{card_internal_id}"
    end
  end

  if mentioned_agent
    agent_name = mentioned_agent
    is_cross_agent_mention = !card_assigned_agent || card_assigned_agent != mentioned_agent
  else
    unless card_assigned_agent
      LOG.info "Skipping card #{card_internal_id} — no assigned agent and no mention"
      return [nil, false]
    end
    agent_name = card_assigned_agent
    is_cross_agent_mention = false
  end

  [agent_name, is_cross_agent_mention]
end

# Handle cross-agent mention (agent tagged on another agent's card)
def handle_cross_agent_mention(agent_name:, card_info:, card_internal_id:, comment_vars:, plain_text:, model:, effort:,
                               project_config:, project_key:, comment_id:, creator_is_agent:, cli_provider_override:, eventable:)
  card_assigned_agent = card_info&.dig("agent")

  # Skip card creation/assignment announcements
  if creator_is_agent && (plain_text.match?(/created\s+card\s+#?\d+/i) || plain_text.match?(/assigned\s+.*card\s+#?\d+/i) || plain_text.match?(/card\s+#?\d+.*assigned/i))
    LOG.info "Ignoring cross-agent mention from #{comment_vars["COMMENT_CREATOR"]} on card #{card_internal_id} — Fizzy card creation/assignment (handled by webhook)"
    return [200, { status: "ignored", reason: "card creation announcement" }.to_json]
  end

  card_number = card_info&.dig("number")
  card_number ||= resolve_card_number(card_internal_id, repo_path: project_config["repo_path"]) if card_number.nil?

  card_key = "card-#{card_number || card_internal_id}-#{agent_name.downcase}"
  if creator_is_agent && session_active?(card_key)
    return [200, { status: "ignored", reason: "session wait timeout" }.to_json] unless wait_for_session?(card_key)
  elsif session_active?(card_key)
    return [200, { status: "ignored", reason: "session already active" }.to_json]
  end

  LOG.info "Cross-agent mention: #{agent_name} tagged on #{card_assigned_agent}'s card ##{card_number || card_internal_id} (project: #{project_key})"
  record_agent_dispatch(card_internal_id) if creator_is_agent

  # React in background
  Thread.new do
    if card_number
      run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--comment", comment_id.to_s, "--content", "👀",
              chdir: project_config["repo_path"], env: fizzy_env_for(agent_name))
    end
  rescue StandardError => e
    LOG.warn "Could not add reaction to comment: #{e.message}"
  end

  # Create cross-agent review worktree
  repo_path = project_config["repo_path"]
  review_branch = "#{agent_name.downcase}/fizzy-#{card_number}-#{slugify(card_info&.dig("title") || eventable.dig("card", "title") || "review")}"
  review_worktree_path = File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{review_branch.tr("/", "-")}")

  debounced_repo_fetch(repo_path)

  if File.directory?(review_worktree_path)
    worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)
    FileUtils.rm_rf(review_worktree_path) unless worktree_list.include?(review_worktree_path)
  end

  if File.directory?(review_worktree_path)
    LOG.info "Reusing existing cross-agent review worktree at #{review_worktree_path}"
  else
    card_branch = card_info&.dig("branch")
    branch_exists = card_branch && system("git", "rev-parse", "--verify", card_branch, chdir: repo_path, out: File::NULL, err: File::NULL)
    base_ref = branch_exists ? card_branch : "origin/#{get_default_branch(repo_path)}"

    run_cmd("git", "branch", "-D", review_branch, chdir: repo_path) if system("git", "rev-parse", "--verify", review_branch, chdir: repo_path, out: File::NULL, err: File::NULL)

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
                         brain_context: build_brain_context(agent_name: agent_name, card_number: card_number, project_key: project_key, comment_body: plain_text, source: :fizzy),
                         card_context: card_context,
                         agent_name: agent_name)

  pid, log_file = run_agent(prompt, project_config: project_config, chdir: review_worktree_path,
                                    log_name: "review-#{agent_name.downcase}-#{card_number || card_internal_id}", model: model, effort: effort, agent_name: agent_name,
                                    card_number: card_number, comment_id: comment_id,
                                    source: :fizzy, source_context: { card_number: card_number }, cli_provider: cli_provider_override)
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: agent_name)

  [200, { status: "cross_agent_review", agent: agent_name, card_agent: card_assigned_agent,
          card: card_number, card_internal_id: card_internal_id, project: project_key, worktree: review_worktree_path }.to_json]
end

# Handle comment on a card that's already in the card map (or has a worktree override)
def handle_existing_card_comment(card_info:, worktree_override:, card_internal_id:, comment_vars:, plain_text:, model:, effort:,
                                 project_config:, project_key:, agent_name:, comment_id:, creator_is_agent:, deploy_intent:, cli_provider_override:, eventable:)
  effective_info = worktree_override ? (card_info || {}).merge(worktree_override) : card_info
  card_number = effective_info["number"]
  worktree = effective_info["worktree"]

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

  # Find worktree if missing
  if !(worktree && File.directory?(worktree)) && card_number
    found = find_worktree_for_card(card_number, repo_path: project_config["repo_path"])
    if found
      worktree = found[:worktree]
      map = load_card_map
      map[card_internal_id] ||= {}
      map[card_internal_id].merge!("worktree" => worktree, "branch" => found[:branch])
      save_card_map(map)
      LOG.info "Found worktree by card number scan: #{worktree}"
    end
  end

  work_dir = worktree && File.directory?(worktree) ? worktree : project_config["repo_path"]
  card_key = "card-#{card_number || card_internal_id}"

  # Session management (wait, supersede, or queue)
  if creator_is_agent && session_active?(card_key)
    return [200, { status: "ignored", reason: "session wait timeout" }.to_json] unless wait_for_session?(card_key)
  elsif session_active?(card_key)
    prev = find_supersedable_session(card_key)
    if prev
      LOG.info "Superseding session on card #{card_number || card_internal_id} (pid: #{prev[:pid]}) — human follow-up within #{SUPERSEDE_WINDOW}s"
      kill_session(prev[:session_key])
    else
      # Queue and wait
      Thread.new do
        run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--comment", comment_id.to_s, "--content", "👍", chdir: work_dir,
                                                                                                                           env: fizzy_env_for(agent_name))
      rescue StandardError => e
        LOG.warn "Could not add reaction to queued comment: #{e.message}"
      end

      Thread.new do
        unless wait_for_session?(card_key)
          LOG.warn "Giving up on queued follow-up for card #{card_number || card_internal_id}"
          next
        end
        dispatch_followup_comment(
          card_key: card_key, card_number: card_number, card_internal_id: card_internal_id,
          work_dir: work_dir, project_config: project_config, project_key: project_key,
          comment_vars: comment_vars, plain_text: plain_text, model: model,
          agent_name: agent_name, comment_id: comment_id, eventable: eventable,
          deploy_intent: deploy_intent, cli_provider: cli_provider_override
        )
      end

      return [200, { status: "queued", card: card_number, card_internal_id: card_internal_id, reason: "waiting for active session" }.to_json]
    end
  end

  LOG.info "Follow-up comment on card #{card_number || card_internal_id} (project: #{project_key}), worktree: #{work_dir}"

  Thread.new do
    run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--comment", comment_id.to_s, "--content", "👍", chdir: work_dir,
                                                                                                                       env: fizzy_env_for(agent_name))
  rescue StandardError => e
    LOG.warn "Could not add reaction to comment: #{e.message}"
  end

  result = dispatch_followup_comment(
    card_key: card_key, card_number: card_number, card_internal_id: card_internal_id,
    work_dir: work_dir, project_config: project_config, project_key: project_key,
    comment_vars: comment_vars, plain_text: plain_text, model: model,
    agent_name: agent_name, comment_id: comment_id, eventable: eventable,
    deploy_intent: deploy_intent, cli_provider: cli_provider_override
  )
  [200, result.to_json]
end

# Handle mention on a card with no existing card_info (exploration)
def handle_new_mention(agent_name:, card_internal_id:, eventable:, comment_vars:, plain_text:, model:, effort:,
                       project_config:, project_key:, comment_id:, creator_is_agent:, cli_provider_override:)
  card_data = eventable["card"] || {}
  card_number = card_data["number"]
  card_title = card_data["title"] || "exploration"

  if card_number.nil?
    map_entry = load_card_map[card_internal_id]
    card_number = if map_entry && map_entry["number"]
                    map_entry["number"]
                  else
                    resolve_card_number(card_internal_id, repo_path: project_config["repo_path"])
                  end
  end

  LOG.info "#{agent_name} mentioned on card (internal_id: #{card_internal_id}, project: #{project_key}), creating exploration worktree"
  record_agent_dispatch(card_internal_id) if creator_is_agent

  card_key = "card-#{card_number || card_internal_id}"
  return [200, { status: "ignored", reason: "session already active" }.to_json] if session_active?(card_key)

  Thread.new do
    if card_number
      run_cmd("fizzy", "reaction", "create", "--card", card_number.to_s, "--comment", comment_id.to_s, "--content", "👀",
              chdir: project_config["repo_path"], env: fizzy_env_for(agent_name))
    end
  rescue StandardError => e
    LOG.warn "Could not add reaction to comment: #{e.message}"
  end

  repo_path = project_config["repo_path"]

  # Check for existing worktree in card map or on disk
  existing_map_entry = load_card_map[card_internal_id]
  if existing_map_entry && existing_map_entry["branch"] && existing_map_entry["worktree"] && File.directory?(existing_map_entry["worktree"])
    branch = existing_map_entry["branch"]
    worktree_path = existing_map_entry["worktree"]
    LOG.info "Reusing existing worktree from card map: #{worktree_path}"
  elsif card_number
    found = find_worktree_for_card(card_number, repo_path: repo_path)
    if found
      worktree_path = found[:worktree]
      branch = found[:branch]
      LOG.info "Found existing worktree by card number scan: #{worktree_path}"
    end
  end

  unless worktree_path && File.directory?(worktree_path)
    branch = card_number ? "fizzy-#{card_number}-#{slugify(card_title)}" : "fizzy-explore-#{card_internal_id[0..7]}"
    debounced_repo_fetch(repo_path)
    worktree_path = create_or_reuse_worktree(repo_path: repo_path, branch: branch)
  end

  map = load_card_map
  map[card_internal_id] = {
    "number" => card_number, "branch" => branch, "worktree" => worktree_path,
    "project" => project_key, "agent" => agent_name
  }
  save_card_map(map)

  card_tags = eventable.dig("card", "tags") || []
  planning_info = detect_planning_mode(text: plain_text, tags: card_tags, card_internal_id: card_internal_id, card_number: card_number)

  prompt = if planning_info
             render_planning_prompt(PROMPT_MENTION,
                                    comment_vars.merge("CARD_INTERNAL_ID" => card_internal_id, "CARD_ID" => planning_info[:card_id],
                                                       "CARD_NUMBER" => card_number || "N/A", "CARD_NUMBER_TEXT" => card_number ? " (##{card_number})" : "", "BRANCH" => branch),
                                    brain_context: build_brain_context(agent_name: agent_name, card_title: card_title, card_number: card_number, project_key: project_key, comment_body: plain_text, source: :fizzy),
                                    card_context: prefetch_card_context(card_number, repo_path: worktree_path, agent_name: agent_name),
                                    agent_name: agent_name)
           else
             render_prompt(PROMPT_MENTION,
                           comment_vars.merge("CARD_INTERNAL_ID" => card_internal_id, "CARD_ID" => card_number || card_internal_id,
                                              "CARD_NUMBER" => card_number || "N/A", "CARD_NUMBER_TEXT" => card_number ? " (##{card_number})" : "", "BRANCH" => branch),
                           brain_context: build_brain_context(agent_name: agent_name, card_title: card_title, card_number: card_number, project_key: project_key, comment_body: plain_text, source: :fizzy),
                           card_context: prefetch_card_context(card_number, repo_path: worktree_path, agent_name: agent_name),
                           agent_name: agent_name)
           end

  pid, log_file = run_agent(prompt, project_config: project_config, chdir: worktree_path, log_name: "mention-#{card_number || card_internal_id}", model: model, effort: effort, agent_name: agent_name, card_number: card_number, comment_id: comment_id,
                                    source: :fizzy, source_context: { card_number: card_number }, cli_provider: cli_provider_override)
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: agent_name)
  [200, { status: "responded", card_internal_id: card_internal_id, card_number: card_number, branch: branch, worktree: worktree_path, project: project_key }.to_json]
end

# Dispatch a follow-up comment to the agent.
def dispatch_followup_comment(card_key:, card_number:, card_internal_id:, work_dir:, project_config:, project_key:, comment_vars:, plain_text:,
                              model:, agent_name:, comment_id:, eventable:, deploy_intent: nil, cli_provider: nil)
  card_tags = eventable.dig("card", "tags") || []
  effort = detect_effort(project_config, tags: card_tags, text: plain_text)

  is_worktree = work_dir != project_config["repo_path"]
  resolved = resolve_project_cli_config(project_config, cli_provider_override: cli_provider, agent_name: agent_name)
  should_resume = is_worktree && resolved["resume_flag"]

  if should_resume
    prompt = render_resume_prompt(
      comment_body: plain_text, comment_creator: comment_vars["COMMENT_CREATOR"],
      comment_id: comment_id, card_number: card_number, agent_name: agent_name
    )
    LOG.info "[Resume] Using lean prompt for follow-up on card #{card_number || card_internal_id}"
  else
    planning_info = detect_planning_mode(text: plain_text, tags: card_tags, card_internal_id: card_internal_id, card_number: card_number)

    prompt = if planning_info
               card_id = planning_info[:card_id]
               if work_dir == project_config["repo_path"]
                 render_planning_prompt(PROMPT_FOLLOWUP_NO_WORKTREE,
                                        comment_vars.merge("CARD_INTERNAL_ID" => card_internal_id, "CARD_ID" => card_id),
                                        brain_context: build_brain_context(agent_name: agent_name, project_key: project_key, comment_body: plain_text, source: :fizzy),
                                        card_context: prefetch_card_context(card_number, repo_path: project_config["repo_path"], agent_name: agent_name),
                                        agent_name: agent_name)
               else
                 render_planning_prompt(PROMPT_FOLLOWUP_WORKTREE,
                                        comment_vars.merge("CARD_NUMBER" => card_number, "CARD_ID" => card_id),
                                        brain_context: build_brain_context(agent_name: agent_name, card_number: card_number, project_key: project_key, comment_body: plain_text, source: :fizzy),
                                        card_context: prefetch_card_context(card_number, repo_path: work_dir, agent_name: agent_name),
                                        agent_name: agent_name)
               end
             elsif work_dir != project_config["repo_path"]
               render_prompt(PROMPT_FOLLOWUP_WORKTREE,
                             comment_vars.merge("CARD_NUMBER" => card_number, "CARD_ID" => card_number),
                             brain_context: build_brain_context(agent_name: agent_name, card_number: card_number, project_key: project_key, comment_body: plain_text, source: :fizzy),
                             card_context: prefetch_card_context(card_number, repo_path: work_dir, agent_name: agent_name),
                             agent_name: agent_name)
             else
               render_prompt(PROMPT_FOLLOWUP_NO_WORKTREE,
                             comment_vars.merge("CARD_INTERNAL_ID" => card_internal_id, "CARD_ID" => card_internal_id),
                             brain_context: build_brain_context(agent_name: agent_name, project_key: project_key, comment_body: plain_text, source: :fizzy),
                             card_context: prefetch_card_context(card_number, repo_path: project_config["repo_path"], agent_name: agent_name),
                             agent_name: agent_name)
             end
  end

  pid, log_file = run_agent(prompt, project_config: project_config, chdir: work_dir, log_name: "followup-#{card_number || card_internal_id}", model: model, effort: effort, agent_name: agent_name, card_number: card_number, comment_id: comment_id,
                                    source: :fizzy, source_context: { card_number: card_number, card_internal_id: card_internal_id, deploy_intent: deploy_intent }, cli_provider: cli_provider, resume: is_worktree)
  register_session(card_key, pid, log_file: log_file, supersede_key: card_key, agent_name: agent_name)

  Thread.new { move_card_to_column(card_number, "right_now", project_config: project_config, agent_name: agent_name) }

  { status: "follow_up", card: card_number, card_internal_id: card_internal_id, worktree: work_dir, project: project_key }
end
