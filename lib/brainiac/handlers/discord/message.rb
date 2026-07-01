# frozen_string_literal: true

# Discord message handler — the main dispatch function.
#
# Handles incoming messages: authorization, cross-agent routing, project detection,
# worktree management, prompt building, agent spawning, and response monitoring.

# Handle an incoming Discord message for a specific agent bot.
# agent_key: the lowercase agent key (e.g. "galen")
# bot_token: the Discord bot token for this agent
# bot_user_id: the Discord user ID of this bot
def handle_discord_message(message, agent_key, bot_token, bot_user_id)
  channel_id = message["channel_id"]
  message_id = message["id"]
  author = message["author"]
  content = message["content"] || ""
  is_bot = !author["bot"].nil?

  sender_agent_key = detect_sender_agent(author, agent_key) if is_bot
  return if is_bot && !sender_agent_key

  mentions = message["mentions"] || []
  mentioned = mentions.any? { |m| m["id"].to_s == bot_user_id.to_s } ||
              content.match?(/<@!?#{Regexp.escape(bot_user_id.to_s)}>/)
  return if sender_agent_key && !validate_cross_agent_dispatch(sender_agent_key, agent_key, mentioned, content, channel_id)

  is_reply_to_bot, referenced_message = detect_reply_to_bot(message, channel_id, mentioned, bot_token, bot_user_id)
  channel_info, is_thread, is_dm, in_own_thread = detect_channel_context(message, channel_id, mentioned, is_reply_to_bot, bot_token, bot_user_id)
  return if should_stand_down?(in_own_thread, mentioned, is_reply_to_bot, is_bot, agent_key, mentions, content)
  return unless mentioned || in_own_thread || is_dm || is_reply_to_bot

  record_human_comment("discord-#{channel_id}") unless is_bot

  clean_content = prepare_discord_content(content, bot_user_id, message, message_id, agent_key)
  attachment_paths = download_attachments(message, message_id, agent_key)
  clean_content = append_attachments(clean_content, attachment_paths)
  return if clean_content.empty? && attachment_paths.empty?

  reply_context = build_reply_context(referenced_message)
  discord_user = author["username"]
  discord_user_id = author["id"]
  agent_name = agent_display_name(agent_key) || agent_key.capitalize

  channel_info, is_thread, is_dm = ensure_channel_info(channel_info, is_thread, is_dm, channel_id, bot_token)
  parent_channel_id = is_thread ? channel_info&.dig("parent_id") || channel_id : channel_id
  channel_history = fetch_discord_channel_history(channel_id, message_id, token: bot_token, limit: is_thread ? 25 : 10)
  location = is_dm ? "DM" : (is_thread ? "thread" : "channel") # rubocop:disable Style/NestedTernaryOperator
  LOG.info "[Discord:#{agent_name}] Message from #{discord_user} in #{location} #{channel_id}: #{clean_content[0..100]}"

  reload_projects!
  reload_agent_registry!
  reload_discord_config!
  return unless authorize_discord_user(discord_user, discord_user_id, message, channel_id, message_id, agent_name, bot_token)

  tags = parse_inline_tags(clean_content)
  project_key, project_config = resolve_discord_project(tags[:project], parent_channel_id, agent_name, channel_id, message_id, bot_token)

  route_discord_dispatch(
    agent_key: agent_key, agent_name: agent_name, bot_token: bot_token, is_bot: is_bot,
    channel_id: channel_id, message_id: message_id, message: message,
    clean_content: clean_content, clean_content_for_prompt: tags[:clean_text],
    chat_mode: tags[:chat_mode], is_thread: is_thread, is_dm: is_dm,
    channel_info: channel_info, parent_channel_id: parent_channel_id,
    discord_user: discord_user, reply_context: reply_context,
    channel_history: channel_history, project_key: project_key,
    project_config: project_config, attachment_paths: attachment_paths
  )
end

def route_discord_dispatch(agent_key:, agent_name:, bot_token:, is_bot:, channel_id:, message_id:, message:,
                           clean_content:, clean_content_for_prompt:, chat_mode:, is_thread:, is_dm:,
                           channel_info:, parent_channel_id:, discord_user:, reply_context:,
                           channel_history:, project_key:, project_config:, attachment_paths:)
  session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"
  supersede_key = "discord-#{agent_key}-#{channel_id}"
  if session_active?(session_key)
    add_discord_reaction(channel_id, message_id, "⏳", token: bot_token)
    return
  end
  handle_supersede(is_bot, supersede_key, discord_user, agent_name, bot_token)
  Thread.new do
    remove_discord_reaction(channel_id, message_id, "🛑", token: bot_token)
    add_discord_reaction(channel_id, message_id, "👀", token: bot_token)
  end

  begin
    project_context = build_discord_project_context(project_key, project_config, agent_name)

    dispatch_discord_session(
      agent_key: agent_key, agent_name: agent_name, bot_token: bot_token,
      channel_id: channel_id, message_id: message_id, message: message,
      clean_content: clean_content, clean_content_for_prompt: clean_content_for_prompt,
      chat_mode: chat_mode, is_thread: is_thread, is_dm: is_dm,
      channel_info: channel_info, parent_channel_id: parent_channel_id,
      discord_user: discord_user, reply_context: reply_context,
      channel_history: channel_history, project_key: project_key,
      project_config: project_config, project_context: project_context,
      session_key: session_key, supersede_key: supersede_key,
      attachment_paths: attachment_paths, is_bot: is_bot
    )
  rescue StandardError => e
    LOG.error "[Discord:#{agent_name}] Dispatch failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    Thread.new do
      remove_discord_reaction(channel_id, message_id, "👀", token: bot_token)
      add_discord_reaction(channel_id, message_id, "❌", token: bot_token)
    end
    error_msg = "⚠️ Something went wrong while preparing your request:\n```\n#{e.message.lines.first(3).join.strip}\n```"
    send_discord_message(channel_id, error_msg, token: bot_token, reply_to: message_id)
  end
end

def ensure_channel_info(channel_info, is_thread, is_dm, channel_id, bot_token)
  return [channel_info, is_thread, is_dm] if channel_info

  channel_info = discord_api(:get, "/channels/#{channel_id}", token: bot_token)
  is_thread = channel_info && [11, 12].include?(channel_info["type"])
  is_dm = channel_info && channel_info["type"] == 1
  [channel_info, is_thread, is_dm]
end

def prepare_discord_content(content, bot_user_id, _message, _message_id, _agent_key)
  content.gsub(/<@!?#{bot_user_id}>/, "").strip
end

def append_attachments(clean_content, attachment_paths)
  return clean_content if attachment_paths.empty?

  clean_content += "\n\n" unless clean_content.empty?
  clean_content + attachment_paths.join("\n")
end

def dispatch_discord_session(agent_key:, agent_name:, bot_token:, channel_id:, message_id:, message:,
                             clean_content:, clean_content_for_prompt:, chat_mode:, is_thread:, is_dm:,
                             channel_info:, parent_channel_id:, discord_user:, reply_context:,
                             channel_history:, project_key:, project_config:, project_context:,
                             session_key:, supersede_key:, attachment_paths:, is_bot:)
  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
  response_dir = File.join(BRAINIAC_DIR, "tmp")
  response_basename = "discord-response-#{timestamp}-#{agent_key}-#{message_id}"
  response_file = File.join(DISCORD_DRAFT_DIR, "#{response_basename}.md")

  root_message = find_root_message(message, channel_id, bot_token)
  card_id = is_thread ? "discord-#{parent_channel_id}-#{channel_id}" : "discord-#{channel_id}-#{root_message[:id]}"
  thread_root_context = build_thread_root_context(is_thread, root_message, parent_channel_id, channel_id, bot_token)
  planning_info = detect_planning_mode(text: clean_content, tags: [], card_internal_id: card_id, card_number: nil)
  brain_context = build_brain_context(agent_name: agent_name, card_title: clean_content, comment_body: clean_content)

  should_resume, thread_worktree_path, thread_cli_provider, thread_model, thread_effort = manage_discord_worktree(
    agent_key: agent_key, agent_name: agent_name, channel_id: channel_id, message_id: message_id,
    is_thread: is_thread, is_dm: is_dm, project_config: project_config, clean_content: clean_content,
    chat_mode: chat_mode, bot_token: bot_token
  )

  prompt = build_discord_prompt(
    should_resume: should_resume, thread_worktree_path: thread_worktree_path,
    planning_info: planning_info, clean_content_for_prompt: clean_content_for_prompt,
    discord_user: discord_user, channel_name: channel_info&.dig("name") || channel_id, reply_context: reply_context,
    channel_history: channel_history, thread_root_context: thread_root_context,
    project_context: project_context, response_file: response_file, card_id: card_id,
    brain_context: brain_context, agent_name: agent_name
  )

  work_dir = chat_mode_fallback(agent_key, agent_name, message_id, chat_mode, thread_worktree_path) ||
             (project_config ? project_config["repo_path"] : Dir.pwd)
  prompt_file = File.join(response_dir, "discord-prompt-#{timestamp}-#{agent_key}-#{message_id}.md")
  File.write(prompt_file, prompt)

  model, effort, cli_provider_override = resolve_discord_overrides(
    clean_content, project_config, thread_model, thread_effort, thread_cli_provider
  )

  meta_file = File.join(DISCORD_DRAFT_DIR, "#{response_basename}.meta.json")
  write_discord_meta(meta_file,
                     channel_id: channel_id, message_id: message_id, agent_key: agent_key,
                     agent_name: agent_name, is_dm: is_dm, is_thread: is_thread,
                     clean_content: clean_content,
                     explicit_model: explicit_model_tag?(clean_content, project_config) ? model : nil,
                     explicit_effort: clean_content.match?(/\[effort:\w+\]/i) ? effort : nil)

  spawn_discord_agent(
    agent_key: agent_key, agent_name: agent_name, bot_token: bot_token,
    channel_id: channel_id, message_id: message_id, discord_user: discord_user,
    work_dir: work_dir, prompt_file: prompt_file, response_file: response_file,
    meta_file: meta_file, model: model, effort: effort, should_resume: should_resume,
    cli_provider_override: cli_provider_override, project_config: project_config,
    session_key: session_key, supersede_key: supersede_key,
    attachment_paths: attachment_paths, timestamp: timestamp, response_dir: response_dir
  )
end

def chat_mode_fallback(agent_key, agent_name, message_id, chat_mode, thread_worktree_path)
  return thread_worktree_path unless chat_mode && !thread_worktree_path

  chat_tmp_dir = File.join(BRAINIAC_DIR, "tmp", "chat", "#{agent_key}-#{message_id}")
  FileUtils.mkdir_p(chat_tmp_dir)
  LOG.info "[Discord:#{agent_name}] Chat mode fallback tmp dir at #{chat_tmp_dir}"
  chat_tmp_dir
end

def resolve_discord_overrides(clean_content, project_config, thread_model, thread_effort, thread_cli_provider)
  cli_provider = detect_cli_provider(text: clean_content) || thread_cli_provider
  has_explicit_model = explicit_model_tag?(clean_content, project_config)
  has_explicit_effort = clean_content.match?(/\[effort:\w+\]/i)

  model = if has_explicit_model
            detect_model(project_config, text: clean_content)
          elsif thread_model
            thread_model
          else
            project_config ? detect_model(project_config, text: clean_content) : nil
          end

  effort = if has_explicit_effort
             detect_effort(project_config, text: clean_content)
           elsif thread_effort
             thread_effort
           else
             project_config ? detect_effort(project_config, text: clean_content) : nil
           end

  [model, effort, cli_provider]
end

def explicit_model_tag?(clean_content, project_config)
  return false unless project_config

  allowed_models = resolve_project_cli_config(project_config)["allowed_models"] || {}
  model_tag_match = clean_content.match(/\[(\w+)\]/i)
  model_tag_match && allowed_models.key?(model_tag_match[1].downcase)
end

def write_discord_meta(meta_file, channel_id:, message_id:, agent_key:, agent_name:, is_dm:, is_thread:,
                       clean_content:, explicit_model:, explicit_effort:)
  File.write(meta_file, JSON.pretty_generate({
                                               channel_id: channel_id, message_id: message_id,
                                               agent_key: agent_key, agent_name: agent_name,
                                               is_dm: is_dm, is_thread: is_thread,
                                               clean_content: clean_content[0..80],
                                               cli_provider: detect_cli_provider(text: clean_content),
                                               model: explicit_model, effort: explicit_effort,
                                               created_at: Time.now.iso8601
                                             }))
end

def spawn_discord_agent(agent_key:, agent_name:, bot_token:, channel_id:, message_id:, discord_user:,
                        work_dir:, prompt_file:, response_file:, meta_file:, model:, effort:,
                        should_resume:, cli_provider_override:, project_config:,
                        session_key:, supersede_key:, attachment_paths:, timestamp:, response_dir:)
  agent_config_name = agent_key.downcase.gsub(/[^a-z0-9-]/, "-")
  log_file = File.join(response_dir, "discord-agent-#{timestamp}-#{agent_key}-#{message_id}.log")

  resolved = resolve_project_cli_config(project_config || DEFAULT_PROJECT,
                                        cli_provider_override: cli_provider_override, agent_name: agent_name)
  cmd = build_agent_cli_cmd(resolved, agent_config_name, model, effort, should_resume, prompt_file)

  resume_note = should_resume ? ", resuming" : ""
  LOG.info "[Discord:#{agent_name}] Dispatching for #{discord_user} " \
           "(model: #{model || "default"}, effort: #{effort || "default"}, cli: #{resolved["agent_cli"]}#{resume_note}), tail -f #{log_file}"
  LOG.info "[Discord:#{agent_name}] Command: #{cmd.join(" ")}"

  spawn_env = {}
  agent_env = agent_env_for(agent_name)
  unless agent_env.empty?
    spawn_env.merge!(agent_env)
    LOG.info "[Discord:#{agent_name}] Injecting #{agent_env.size} env var(s): #{agent_env.keys.join(", ")}"
  end

  head_before, status_before = capture_brainiac_state(project_config, work_dir)
  prompt_mode = resolved["prompt_mode"] || "stdin"

  pid = spawn(spawn_env, *cmd,
              chdir: work_dir,
              **(prompt_mode == "stdin" ? { in: prompt_file } : {}),
              out: [log_file, "w"],
              err: %i[child out])

  register_session(session_key, pid, log_file: log_file,
                                     message_id: message_id, channel_id: channel_id,
                                     supersede_key: supersede_key,
                                     draft_files: [response_file, meta_file],
                                     agent_name: agent_name)

  monitor_discord_agent(
    pid: pid, session_key: session_key, agent_name: agent_name,
    agent_config_name: agent_config_name, channel_id: channel_id,
    message_id: message_id, bot_token: bot_token, response_file: response_file,
    meta_file: meta_file, prompt_file: prompt_file, log_file: log_file,
    attachment_paths: attachment_paths, project_config: project_config,
    head_before: head_before, status_before: status_before
  )
end

def build_agent_cli_cmd(resolved, agent_config_name, model, effort, should_resume, prompt_file)
  agent_flag = resolved.key?("agent_flag") ? resolved["agent_flag"] : "--agent"
  prompt_mode = resolved["prompt_mode"] || "stdin"

  cmd = [resolved["agent_cli"]]
  cmd.push(agent_flag, agent_config_name) if agent_flag
  cmd.concat(resolved["agent_cli_args"].split)
  if model && resolved["agent_model_flag"] && !resolved["agent_model_flag"].empty?
    allowed = resolved["allowed_models"] || {}
    cmd.push(resolved["agent_model_flag"], model) if allowed.value?(model) || allowed.key?(model)
  end
  cmd.push(resolved["agent_effort_flag"], effort) if resolved["agent_effort_flag"] && !resolved["agent_effort_flag"].empty? && effort
  cmd.push(resolved["resume_flag"]) if should_resume && resolved["resume_flag"]
  cmd.push(resolved["prompt_flag"], prompt_file) if prompt_mode == "flag" && resolved["prompt_flag"]
  cmd
end

def capture_brainiac_state(project_config, work_dir)
  return [nil, nil] unless project_config

  pk = PROJECTS.find { |_k, v| v == project_config }&.first
  pk == "brainiac" ? capture_git_state(work_dir) : [nil, nil]
end

# --- Private helpers for handle_discord_message ---

def detect_sender_agent(author, agent_key)
  sender_id = author["id"]
  sender_agent_key = nil

  DISCORD_BOTS_MUTEX.synchronize do
    DISCORD_BOTS.each do |key, info|
      if info[:user_id] == sender_id && key != agent_key
        sender_agent_key = key
        break
      end
    end
  end

  unless sender_agent_key
    user_mappings = DISCORD_CONFIG["user_mappings"] || {}
    user_mappings.each do |name, discord_id|
      if discord_id == sender_id
        sender_agent_key = name.downcase
        break
      end
    end
  end

  LOG.info "[Discord:#{agent_key}] Ignoring unknown bot: id=#{sender_id}, username=#{author["username"]}" unless sender_agent_key

  sender_agent_key
end

def validate_cross_agent_dispatch(sender_agent_key, agent_key, mentioned, content, channel_id) # rubocop:disable Naming/PredicateMethod
  return false unless mentioned

  if content.match?(/created\s+card\s+#?\d+/i) || content.match?(/assigned\s+.*card\s+#?\d+/i) || content.match?(/card\s+#?\d+.*assigned/i)
    sender_display = agent_display_name(sender_agent_key) || sender_agent_key.capitalize
    agent_display = agent_display_name(agent_key) || agent_key.capitalize
    LOG.info "[Discord:#{agent_display}] Ignoring cross-agent mention from #{sender_display} — Fizzy card creation/assignment (handled by webhook)"
    return false
  end

  depth_key = "discord-#{channel_id}"
  unless agent_dispatch_allowed?(depth_key)
    sender_display = agent_display_name(sender_agent_key) || sender_agent_key.capitalize
    agent_display = agent_display_name(agent_key) || agent_key.capitalize
    LOG.info "[Discord:#{agent_display}] Blocking cross-agent dispatch from #{sender_display} — depth limit reached"
    return false
  end
  record_agent_dispatch(depth_key)
  true
end

def detect_reply_to_bot(message, channel_id, mentioned, bot_token, bot_user_id)
  is_reply_to_bot = false
  referenced_message = nil

  if message["message_reference"]
    ref_msg_id = message.dig("message_reference", "message_id")
    ref_channel = message.dig("message_reference", "channel_id") || channel_id
    if ref_msg_id
      referenced_message = discord_api(:get, "/channels/#{ref_channel}/messages/#{ref_msg_id}", token: bot_token)
      is_reply_to_bot = !mentioned && referenced_message && referenced_message.dig("author", "id") == bot_user_id
    end
  end

  [is_reply_to_bot, referenced_message]
end

def detect_channel_context(_message, channel_id, mentioned, is_reply_to_bot, bot_token, bot_user_id)
  channel_info = nil
  is_thread = false
  is_dm = false
  in_own_thread = false

  if !mentioned && !is_reply_to_bot
    channel_info = discord_api(:get, "/channels/#{channel_id}", token: bot_token)
    is_thread = channel_info && [11, 12].include?(channel_info["type"])
    is_dm = channel_info && channel_info["type"] == 1
    in_own_thread = is_thread && channel_info["owner_id"] == bot_user_id
  end

  [channel_info, is_thread, is_dm, in_own_thread]
end

def should_stand_down?(in_own_thread, mentioned, is_reply_to_bot, is_bot, agent_key, mentions, content)
  return false unless in_own_thread && !mentioned && !is_reply_to_bot && !is_bot

  other_bot_mentioned = false
  DISCORD_BOTS_MUTEX.synchronize do
    DISCORD_BOTS.each do |key, info|
      next if key == agent_key
      next unless info[:user_id]
      next unless mentions.any? { |m| m["id"].to_s == info[:user_id].to_s } ||
                  content.match?(/<@!?#{Regexp.escape(info[:user_id].to_s)}>/)

      other_bot_mentioned = true
      break
    end
  end

  unless other_bot_mentioned
    user_mappings = DISCORD_CONFIG["user_mappings"] || {}
    user_mappings.each_value do |discord_id|
      next unless mentions.any? { |m| m["id"].to_s == discord_id.to_s } ||
                  content.match?(/<@!?#{Regexp.escape(discord_id.to_s)}>/)

      other_bot_mentioned = true
      break
    end
  end

  if other_bot_mentioned
    agent_display = agent_display_name(agent_key) || agent_key.capitalize
    LOG.info "[Discord:#{agent_display}] Standing down in own thread — human is directing message to another agent"
  end

  other_bot_mentioned
end

def download_attachments(message, message_id, agent_key)
  attachments = message["attachments"] || []
  paths = []
  agent_display = agent_display_name(agent_key) || agent_key.capitalize

  attachments.each do |att|
    url = att["url"]
    filename = att["filename"]
    content_type = att["content_type"] || ""
    next unless content_type.start_with?("image/")

    temp_dir = File.join(BRAINIAC_DIR, "tmp", "discord", "attachments")
    FileUtils.mkdir_p(temp_dir)
    temp_path = File.join(temp_dir, "#{message_id}-#{filename}")

    begin
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      response = http.get(uri.path + (uri.query ? "?#{uri.query}" : ""))

      if response.code.to_i == 200
        File.binwrite(temp_path, response.body)
        paths << temp_path
        LOG.info "[Discord:#{agent_display}] Downloaded attachment: #{filename} (#{content_type})"
      else
        LOG.warn "[Discord:#{agent_display}] Failed to download attachment #{filename}: HTTP #{response.code}"
      end
    rescue StandardError => e
      LOG.error "[Discord:#{agent_display}] Error downloading attachment #{filename}: #{e.message}"
    end
  end
  paths
end

def build_reply_context(referenced_message)
  return "" unless referenced_message && referenced_message["content"]

  ref_author = referenced_message.dig("author", "username") || "unknown"
  ref_text = referenced_message["content"].strip
  return "" if ref_text.empty?

  "**Replying to #{ref_author}:**\n> #{ref_text}\n\n"
end

def authorize_discord_user(discord_user, discord_user_id, message, channel_id, message_id, agent_name, bot_token) # rubocop:disable Naming/PredicateMethod
  authorized_users = DISCORD_CONFIG["authorized_user_ids"] || []

  authorized_roles = if DISCORD_CONFIG["role_mappings"]
                       DISCORD_CONFIG["role_mappings"].values
                     elsif DISCORD_CONFIG["authorized_role_ids"].is_a?(Hash)
                       DISCORD_CONFIG["authorized_role_ids"].values
                     else
                       DISCORD_CONFIG["authorized_role_ids"] || []
                     end
  authorized_roles = authorized_roles.map(&:to_s)

  return true if authorized_users.empty? && authorized_roles.empty?

  user_authorized = authorized_users.include?(discord_user_id)
  member_roles = message.dig("member", "roles") || []

  if member_roles.empty? && message["guild_id"]
    guild_member = fetch_guild_member(message["guild_id"], discord_user_id, token: bot_token)
    member_roles = guild_member["roles"] || [] if guild_member
  end

  role_authorized = member_roles.intersect?(authorized_roles)

  unless user_authorized || role_authorized
    LOG.info "[Discord:#{agent_name}] Unauthorized user #{discord_user} (#{discord_user_id}), roles: #{member_roles.inspect}"
    add_discord_reaction(channel_id, message_id, "🚫", token: bot_token)
    return false
  end

  true
end

def resolve_discord_project(inline_project_key, parent_channel_id, agent_name, channel_id, message_id, bot_token)
  if inline_project_key && PROJECTS.key?(inline_project_key)
    project_key = inline_project_key
    project_config = PROJECTS[inline_project_key]
    LOG.info "[Discord:#{agent_name}] Using inline project: #{project_key} (#{project_config["repo_path"]})"
  else
    if inline_project_key && !PROJECTS.key?(inline_project_key)
      LOG.warn "[Discord:#{agent_name}] Unknown inline project '#{inline_project_key}', " \
               "falling back to channel mapping. Available: #{PROJECTS.keys.join(", ")}"
      Thread.new { add_discord_reaction(channel_id, message_id, "⚠️", token: bot_token) }
    end
    project_key, project_config, _mapping = find_project_for_discord_channel(parent_channel_id)
    if project_key
      LOG.info "[Discord:#{agent_name}] Using channel-mapped project: #{project_key}"
    else
      LOG.info "[Discord:#{agent_name}] No project context (no inline tag or channel mapping)"
    end
  end
  [project_key, project_config]
end

def handle_supersede(is_bot, supersede_key, discord_user, agent_name, bot_token)
  return if is_bot

  prev = find_supersedable_session(supersede_key)
  return unless prev

  LOG.info "[Discord:#{agent_name}] Superseding previous session #{prev[:session_key]} (pid: #{prev[:pid]}) for follow-up from #{discord_user}"
  kill_session(prev[:session_key])
  if prev[:message_id] && prev[:channel_id]
    Thread.new do
      remove_discord_reaction(prev[:channel_id], prev[:message_id], "👀", token: bot_token)
      add_discord_reaction(prev[:channel_id], prev[:message_id], "❌", token: bot_token)
    end
  end
  (prev[:draft_files] || []).each { |f| FileUtils.rm_f(f) }
end

def build_discord_project_context(project_key, project_config, agent_name)
  if project_config
    repo_path = project_config["repo_path"]
    debounced_repo_fetch(repo_path)
    default_branch = get_default_branch(repo_path)
    lines = ["## Project Context", "Project: #{project_key}", "Source directory: `#{repo_path}`",
             "Default branch: `#{default_branch}`"]
    lines << "GitHub: #{project_config["github_repo"]}" if project_config["github_repo"]
    lines << ""
    lines << "This is the project's source code directory. When asked to modify, inspect, or work on this project, " \
             "go directly to `#{repo_path}` — do NOT search for it."
    lines << ""
    lines << "### All registered projects"
    PROJECTS.each { |key, cfg| lines << "- **#{key}**: `#{cfg["repo_path"]}`" }
    LOG.info "[Discord:#{agent_name}] Built project context for #{project_key} (#{repo_path})"
  else
    lines = ["## Project Context", "No specific project mapped to this channel.", "",
             "### Registered projects (use `[project:name]` to target one)"]
    PROJECTS.each { |key, cfg| lines << "- **#{key}**: `#{cfg["repo_path"]}`" }
    LOG.info "[Discord:#{agent_name}] No project context - showing available projects"
  end
  lines.join("\n")
end

def build_thread_root_context(is_thread, root_message, parent_channel_id, channel_id, bot_token)
  return "" unless is_thread

  root_content = root_message[:content]
  root_author = root_message[:author]

  if root_content.nil? || root_content.empty?
    parent_msg = fetch_discord_message(parent_channel_id, channel_id, token: bot_token, log_errors: false)
    if parent_msg && parent_msg["content"] && !parent_msg["content"].strip.empty?
      root_content = parent_msg["content"].strip
      root_author = parent_msg.dig("author", "username") || "unknown"
    end
  end

  return "" unless root_content && !root_content.empty?

  "### Original Message (thread starter)\n#{root_author || "unknown"}: #{root_content}\n\n"
end

def manage_discord_worktree(agent_key:, agent_name:, channel_id:, message_id:, is_thread:, is_dm:, project_config:, clean_content:, chat_mode:,
                            bot_token:)
  should_resume = false
  thread_worktree_path = nil
  thread_cli_provider = nil
  thread_model = nil
  thread_effort = nil

  # Pre-create thread for channel messages with a project
  pre_created_thread_id = nil
  if !is_thread && !is_dm && project_config
    pre_created_thread_id = pre_create_discord_thread(agent_key, agent_name, channel_id, message_id, clean_content, bot_token)
  end

  effective_thread_id = is_thread ? channel_id : pre_created_thread_id
  thread_map_key = "#{agent_key}:#{effective_thread_id}" if effective_thread_id

  if project_config && thread_map_key
    thread_map = DISCORD_THREAD_MAP_MUTEX.synchronize { load_discord_thread_map }
    existing = thread_map[thread_map_key]

    if existing && (existing["chat_mode"] || (existing["worktree"] && File.directory?(existing["worktree"])))
      # Reuse existing thread worktree or chat dir
      thread_worktree_path = existing["worktree"]
      thread_cli_provider = existing["cli_provider"]
      thread_model = existing["model"]
      thread_effort = existing["effort"]
      chat_mode = true if existing["chat_mode"]
      should_resume = thread_resume?(project_config, clean_content, thread_cli_provider, agent_name)
      label = existing["chat_mode"] ? "chat mode tmp dir" : "thread worktree"
      LOG.info "[Discord:#{agent_name}] Reusing #{label} at #{thread_worktree_path} (resume: #{should_resume})"
    elsif chat_mode
      LOG.info "[Discord:#{agent_name}] Chat mode — skipping worktree creation"
    else
      # First worktree creation for this thread
      thread_worktree_path, thread_cli_provider, thread_model, thread_effort =
        create_thread_worktree(agent_key, agent_name, effective_thread_id, project_config, clean_content, existing)
      save_thread_map_entry(thread_map_key, thread_worktree_path,
                            branch: "discord-#{agent_key}-#{effective_thread_id[-8..]}",
                            project_config: project_config, effective_thread_id: effective_thread_id,
                            cli_provider: thread_cli_provider, model: thread_model, effort: thread_effort)
    end
  end

  # Chat mode: create tmp dir if no worktree yet
  if chat_mode && !thread_worktree_path && thread_map_key
    thread_worktree_path, thread_cli_provider, thread_model, thread_effort =
      create_chat_mode_dir(agent_key, agent_name, effective_thread_id, project_config, clean_content, thread_map_key)
  end

  [should_resume, thread_worktree_path, thread_cli_provider, thread_model, thread_effort]
end

def pre_create_discord_thread(agent_key, agent_name, channel_id, message_id, clean_content, bot_token)
  display_name = agent_display_name(agent_key)
  thread = create_discord_thread(channel_id, message_id, name: "#{display_name}: #{clean_content[0..80]}", token: bot_token)

  unless thread && thread["id"]
    LOG.warn "[Discord:#{agent_name}] Failed to pre-create thread — will run without worktree isolation"
    return nil
  end

  thread_id = thread["id"]
  DISCORD_SHARED_THREADS_MUTEX.synchronize { DISCORD_SHARED_THREADS[message_id] = thread_id }

  parent_depth_key = "discord-#{channel_id}"
  thread_depth_key = "discord-#{thread_id}"
  parent_info = AGENT_DISPATCH_DEPTH[parent_depth_key]
  if parent_info
    AGENT_DISPATCH_DEPTH[thread_depth_key] = { count: 0, last_human_at: parent_info[:last_human_at] }
  else
    record_human_comment(thread_depth_key)
  end

  LOG.info "[Discord:#{agent_name}] Pre-created thread #{thread_id} for worktree isolation"
  thread_id
end

def thread_resume?(project_config, clean_content, thread_cli_provider, agent_name)
  effective_provider = detect_cli_provider(text: clean_content) || thread_cli_provider
  resolved = resolve_project_cli_config(project_config, cli_provider_override: effective_provider, agent_name: agent_name)
  resolved["resume_flag"] ? true : false
end

def detect_thread_overrides(project_config, clean_content, fallback_cli: nil, fallback_model: nil, fallback_effort: nil)
  cli = detect_cli_provider(text: clean_content) || fallback_cli
  model = (project_config ? detect_model(project_config, text: clean_content) : nil) || fallback_model
  effort = (project_config ? detect_effort(project_config, text: clean_content) : nil) || fallback_effort
  [cli, model, effort]
end

def create_thread_worktree(agent_key, agent_name, effective_thread_id, project_config, clean_content, existing)
  repo_path = project_config["repo_path"]
  thread_slug = effective_thread_id[-8..]
  branch = "discord-#{agent_key}-#{thread_slug}"

  debounced_repo_fetch(repo_path)
  worktree_path = create_or_reuse_worktree(repo_path: repo_path, branch: branch)

  cli, model, effort = detect_thread_overrides(
    project_config, clean_content,
    fallback_cli: existing&.dig("cli_provider"),
    fallback_model: existing&.dig("model"),
    fallback_effort: existing&.dig("effort")
  )

  LOG.info "[Discord:#{agent_name}] Created thread worktree at #{worktree_path}"
  [worktree_path, cli, model, effort]
end

def create_chat_mode_dir(agent_key, agent_name, effective_thread_id, project_config, clean_content, thread_map_key)
  chat_tmp_dir = File.join(BRAINIAC_DIR, "tmp", "chat", "#{agent_key}-#{effective_thread_id}")
  FileUtils.mkdir_p(chat_tmp_dir)

  cli, model, effort = detect_thread_overrides(project_config, clean_content)

  save_thread_map_entry(thread_map_key, chat_tmp_dir,
                        chat_mode: true, project_config: project_config,
                        effective_thread_id: effective_thread_id,
                        cli_provider: cli, model: model, effort: effort)

  LOG.info "[Discord:#{agent_name}] Created chat mode tmp dir at #{chat_tmp_dir}"
  [chat_tmp_dir, cli, model, effort]
end

def save_thread_map_entry(thread_map_key, worktree_path, project_config:, effective_thread_id:,
                          cli_provider: nil, model: nil, effort: nil, branch: nil, chat_mode: false)
  DISCORD_THREAD_MAP_MUTEX.synchronize do
    map = load_discord_thread_map
    entry = { "worktree" => worktree_path,
              "project" => PROJECTS.find { |_k, v| v == project_config }&.first,
              "channel_id" => effective_thread_id, "cli_provider" => cli_provider,
              "model" => model, "effort" => effort, "created_at" => Time.now.iso8601 }
    entry["branch"] = branch if branch
    entry["chat_mode"] = true if chat_mode
    map[thread_map_key] = entry
    save_discord_thread_map(map)
  end
end

def build_discord_prompt(should_resume:, thread_worktree_path:, planning_info:, clean_content_for_prompt:,
                         discord_user:, channel_name:, reply_context:, channel_history:, thread_root_context:,
                         project_context:, response_file:, card_id:, brain_context:, agent_name:)
  if should_resume && thread_worktree_path
    return render_discord_resume_prompt(
      message_body: clean_content_for_prompt, discord_user: discord_user,
      response_file: response_file, agent_name: agent_name, card_id: card_id
    )
  end

  template_vars = {
    "DISCORD_USER" => discord_user, "CHANNEL_NAME" => channel_name,
    "MESSAGE_BODY" => clean_content_for_prompt, "REPLY_CONTEXT" => reply_context,
    "CHANNEL_HISTORY" => channel_history, "THREAD_ROOT_CONTEXT" => thread_root_context,
    "PROJECT_CONTEXT" => project_context, "RESPONSE_FILE" => response_file,
    "COMMENT_CREATOR" => discord_user, "DISCORD_MENTION_ROSTER" => discord_mention_roster
  }

  if planning_info
    LOG.info "[Discord:#{agent_name}] Planning mode detected for #{discord_user}"
    template_vars["CARD_ID"] = planning_info[:card_id]
    template_vars["MESSAGE_BODY"] = clean_content_for_prompt.sub(/\[plan\]/i, "").strip
    render_planning_prompt(PROMPT_DISCORD, template_vars,
                           brain_context: brain_context, agent_name: agent_name, channel: :discord)
  else
    template_vars["CARD_ID"] = card_id
    render_prompt(PROMPT_DISCORD, template_vars,
                  brain_context: brain_context, agent_name: agent_name, channel: :discord)
  end
end

def monitor_discord_agent(pid:, session_key:, agent_name:, agent_config_name:, channel_id:, message_id:,
                          bot_token:, response_file:, meta_file:, prompt_file:, log_file:,
                          attachment_paths:, project_config:, head_before:, status_before:)
  Thread.new do
    Process.wait(pid)
    exit_status = $CHILD_STATUS

    session_cancelled = ACTIVE_SESSIONS_MUTEX.synchronize { !ACTIVE_SESSIONS.key?(session_key) }

    if exit_status.signaled? || session_cancelled
      handle_cancelled_session(exit_status, session_cancelled, agent_name, message_id,
                               response_file, meta_file, prompt_file, attachment_paths)
      next
    end

    handle_completed_session(
      exit_status: exit_status, agent_name: agent_name, agent_config_name: agent_config_name,
      channel_id: channel_id, message_id: message_id, bot_token: bot_token,
      response_file: response_file, meta_file: meta_file, log_file: log_file,
      project_config: project_config, head_before: head_before, status_before: status_before
    )

    schedule_temp_cleanup(prompt_file, attachment_paths)
  rescue StandardError => e
    LOG.error "[Discord:#{agent_name}] Error monitoring agent: #{e.message}"
    add_discord_reaction(channel_id, message_id, "❌", token: bot_token)
  end
end

def handle_cancelled_session(exit_status, session_cancelled, agent_name, message_id,
                             response_file, meta_file, prompt_file, attachment_paths)
  reason = session_cancelled ? "cancelled" : "superseded (signal: #{exit_status.termsig})"
  LOG.info "[Discord:#{agent_name}] Agent was #{reason} for message #{message_id}"
  [response_file, meta_file].each { |f| FileUtils.rm_f(f) }
  schedule_temp_cleanup(prompt_file, attachment_paths)
end

def handle_completed_session(exit_status:, agent_name:, agent_config_name:, channel_id:, message_id:,
                             bot_token:, response_file:, meta_file:, log_file:,
                             project_config:, head_before:, status_before:)
  LOG.info "[Discord:#{agent_name}] Agent finished for message #{message_id} (exit: #{exit_status.exitstatus})"

  # Only report a crash if the agent didn't produce a response. If the response file exists,
  # the agent completed its primary task — the crash happened during post-task reflection
  # (e.g. kiro-cli hitting "Tool approval required" after an API error in the reflection phase).
  if exit_status.exitstatus && exit_status.exitstatus != 0 && !File.exist?(response_file)
    notify_agent_crash(
      exit_status: exit_status.exitstatus, log_file: log_file,
      agent_name: agent_name, source: :discord,
      source_context: { channel_id: channel_id, message_id: message_id, bot_token: bot_token },
      project_config: project_config
    )
  elsif exit_status.exitstatus && exit_status.exitstatus != 0
    LOG.warn "[Discord:#{agent_name}] Agent exited with code #{exit_status.exitstatus} but response file exists — " \
             "likely crashed during post-task reflection. Suppressing crash notification."
    log_post_task_crash_diagnostics(log_file, agent_name)
  end

  extract_response_from_log(response_file, meta_file, log_file, exit_status, agent_name, agent_config_name, message_id)
  deliver_discord_response(agent_name, channel_id, message_id, bot_token, response_file, meta_file)
  update_brain_after_session(agent_name, message_id)
  check_brainiac_restart(agent_name, project_config, head_before, status_before)
end

def deliver_discord_response(agent_name, channel_id, message_id, bot_token, response_file, meta_file)
  remove_discord_reaction(channel_id, message_id, "👀", token: bot_token)
  sleep 0.5

  delivered = deliver_discord_draft(response_file, meta_file)
  return if delivered

  response_basename_check = File.basename(response_file)
  already_posted = File.exist?(File.join(DISCORD_POSTED_DIR, response_basename_check))
  return if already_posted

  LOG.warn "[Discord:#{agent_name}] No response produced for message #{message_id}"
  add_discord_reaction(channel_id, message_id, "😶", token: bot_token)
end

def update_brain_after_session(agent_name, message_id)
  qmd_out, qmd_status = Open3.capture2e("qmd", "update")
  if qmd_status.success?
    LOG.info "[Brain] qmd update completed after #{agent_name} Discord session"
  else
    LOG.warn "[Brain] qmd update failed: #{qmd_out.strip}"
  end

  brain_push(message: "#{agent_name}: discord-#{message_id}")
end

def check_brainiac_restart(agent_name, project_config, head_before, status_before)
  return unless project_config && head_before

  project_key = PROJECTS.find { |_k, v| v == project_config }&.first
  return unless project_key == "brainiac"

  head_after, status_after = capture_git_state(project_config["repo_path"])
  if head_after != head_before || status_after != status_before
    queue_brainiac_restart(agent_name)
  else
    LOG.info "[Brainiac] #{agent_name} Discord session on brainiac had no changes — skipping restart"
  end
end

def schedule_temp_cleanup(prompt_file, attachment_paths)
  Thread.new do
    sleep 300
    [prompt_file, *attachment_paths].each { |f| FileUtils.rm_f(f) }
  end
end

def extract_response_from_log(response_file, meta_file, log_file, exit_status, agent_name, agent_config_name, message_id)
  return if File.exist?(response_file) || !File.exist?(log_file)

  log_content = File.read(log_file)

  if exit_status.exitstatus != 0 && log_content.match?(/InternalServerError|Encountered an unexpected error|Failed to receive the next message/i)
    LOG.warn "[Discord:#{agent_name}] Agent hit an upstream error for message #{message_id}"
    File.write(response_file, "_Sorry, I hit a temporary error on the backend. Please try again._")
  elsif log_content.match?(/Opening browser\.\.\.|Press \(\^\) \+ C to cancel/)
    LOG.error "[Discord:#{agent_name}] Auth failure detected — re-authenticate with: kiro-cli --agent #{agent_config_name} chat"
    FileUtils.rm_f(meta_file)
  else
    clean_output = log_content
                   .gsub(/\e\[[0-9;]*[a-zA-Z]|\e\[\?[0-9;]*[a-zA-Z]/, "")
                   .gsub(/\e\][^\a]*\a/, "")
                   .delete("\r")
                   .gsub(/^.*?(using tool:.*?)$/m, "")
                   .gsub(/^.*?✓.*?$/m, "")
                   .gsub(/^.*?▸.*?$/m, "")
                   .gsub(/^.*?Loading\.\.\..*?$/m, "")
                   .gsub(/^.*?Completed in.*?$/m, "")
                   .strip

    if !clean_output.empty? && clean_output.length > 20
      File.write(response_file, clean_output)
      LOG.info "[Discord:#{agent_name}] Extracted response from log (#{clean_output.length} chars)"
    end
  end
end

# Diagnostic logging for when an agent exits non-zero but already wrote its response.
# Extracts the last tool call, the error messages, and context from the log tail.
def log_post_task_crash_diagnostics(log_file, agent_name)
  return unless log_file && File.exist?(log_file)

  content = File.read(log_file)
  lines = content.lines.map { |l| l.gsub(/\e\[[0-9;]*[a-zA-Z]/, "").rstrip }

  # Find the last tool call that succeeded
  last_tool_idx = lines.rindex { |l| l.include?("using tool:") }
  last_tool = last_tool_idx ? lines[last_tool_idx].strip : "unknown"

  # Find error lines
  error_lines = lines.grep(/^error:|Tool approval required|Failed to receive/i)

  # Count total tool calls
  tool_count = lines.count { |l| l.include?("using tool:") }

  # Log size as a proxy for conversation length
  log_size_kb = (File.size(log_file) / 1024.0).round(1)

  LOG.warn "[Discord:#{agent_name}] Post-task crash diagnostics:"
  LOG.warn "[Discord:#{agent_name}]   Log size: #{log_size_kb}KB, tool calls: #{tool_count}"
  LOG.warn "[Discord:#{agent_name}]   Last successful tool: #{last_tool[0..120]}"
  error_lines.each { |l| LOG.warn "[Discord:#{agent_name}]   Error: #{l.strip[0..200]}" }
rescue StandardError => e
  LOG.warn "[Discord:#{agent_name}] Could not read crash diagnostics: #{e.message}"
end
