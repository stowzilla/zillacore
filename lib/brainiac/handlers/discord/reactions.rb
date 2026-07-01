# frozen_string_literal: true

# Discord reaction handler.
#
# Handles MESSAGE_REACTION_ADD events:
# - ❌ to cancel an active agent session
# - ❔/❓ to peek at the agent's thinking (last 10/20 lines)
# - 🧠 to stream the full thinking log to a thread
# - Non-reserved emojis logged as feedback to the agent's persona

# Strip ANSI escape codes and non-ASCII from log output for Discord display.
def strip_ansi(text)
  text.gsub(/\e\[[0-9;]*[a-zA-Z]/, "")
      .gsub(/\x1b\[[0-9;]*[a-zA-Z]/, "")
      .gsub(/\e\][0-9;]*.*?(\x07|\e\\)/, "")
      .gsub(/\e[=>]/, "")
      .gsub(/\[\?[0-9]+[lh]/, "")
      .gsub("[K", "")
      .encode("ASCII", invalid: :replace, undef: :replace, replace: "")
      .strip
end

def handle_discord_reaction(reaction_data, agent_key, bot_token, bot_user_id)
  channel_id = reaction_data["channel_id"]
  message_id = reaction_data["message_id"]
  user_id = reaction_data["user_id"]
  emoji = reaction_data["emoji"]
  emoji_name = emoji["name"]

  agent_name = agent_display_name(agent_key) || agent_key.capitalize

  # Ignore reactions from bots (including self)
  return if user_id == bot_user_id

  # Handle ❔ or ❓ reactions (thinking file inspection)
  if ["❔", "❓"].include?(emoji_name)
    handle_thinking_peek(agent_key, agent_name, channel_id, message_id, bot_token, line_count: emoji_name == "❔" ? 10 : 20)
    return
  end

  # Handle 🧠 reaction (stream full thinking to thread)
  if emoji_name == "🧠"
    handle_thinking_stream(agent_key, agent_name, channel_id, message_id, bot_token)
    return
  end

  # --- Feedback logging for non-reserved emojis ---
  unless RESERVED_EMOJIS.include?(emoji_name)
    Thread.new do
      log_emoji_feedback(channel_id, message_id, user_id, emoji_name, agent_key, agent_name, bot_token)
    rescue StandardError => e
      LOG.warn "[Discord:#{agent_name}] Feedback logging failed: #{e.message}"
    end
    return
  end

  # Only handle ❌ reactions beyond this point
  return unless emoji_name == "❌"

  handle_cancel_reaction(agent_key, agent_name, channel_id, message_id, bot_token)
end

# --- Thinking Peek (❔/❓) ---

def handle_thinking_peek(agent_key, agent_name, channel_id, message_id, bot_token, line_count:)
  session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"

  ACTIVE_SESSIONS_MUTEX.synchronize do
    session_info = ACTIVE_SESSIONS[session_key]

    unless session_info
      LOG.info "[Discord:#{agent_name}] Thinking peek on #{message_id} but no active session found"
      return
    end

    log_file = session_info[:log_file]
    unless log_file && File.exist?(log_file)
      LOG.warn "[Discord:#{agent_name}] No log file found for session #{session_key}"
      send_discord_message(channel_id, "No thinking file found for this session.", token: bot_token, reply_to: message_id)
      return
    end

    LOG.info "[Discord:#{agent_name}] Reading last #{line_count} lines from #{log_file}"

    lines = File.readlines(log_file).last(line_count)
    thinking_output = strip_ansi(lines.join)

    response = "**Last #{line_count} lines:**\n```\n#{thinking_output}\n```"
    send_discord_message(channel_id, response, token: bot_token, reply_to: message_id)
  end
end

# --- Thinking Stream (🧠) ---

def handle_thinking_stream(agent_key, agent_name, channel_id, message_id, bot_token)
  session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"

  ACTIVE_SESSIONS_MUTEX.synchronize do
    session_info = ACTIVE_SESSIONS[session_key]

    unless session_info
      LOG.info "[Discord:#{agent_name}] 🧠 reaction on #{message_id} but no active session found"
      return
    end

    log_file = session_info[:log_file]
    unless log_file && File.exist?(log_file)
      LOG.warn "[Discord:#{agent_name}] No log file found for session #{session_key}"
      send_discord_message(channel_id, "No thinking file found for this session.", token: bot_token, reply_to: message_id)
      return
    end

    LOG.info "[Discord:#{agent_name}] Creating thread and streaming thinking from #{log_file}"

    thread_response = create_discord_thread(channel_id, message_id, name: "🧠 Thinking Stream", token: bot_token)
    unless thread_response && thread_response["id"]
      LOG.error "[Discord:#{agent_name}] Failed to create thread, response: #{thread_response.inspect}"
      return
    end

    thread_id = thread_response["id"]
    LOG.info "[Discord:#{agent_name}] Thread created: #{thread_id}"

    stream_thinking_to_thread(log_file, thread_id, bot_token)
  end
end

def stream_thinking_to_thread(log_file, thread_id, bot_token)
  thinking_content = strip_ansi(File.read(log_file))

  chunks = []
  current_chunk = ""
  thinking_content.lines.each do |line|
    if current_chunk.length + line.length > 1900
      chunks << current_chunk
      current_chunk = line
    else
      current_chunk += line
    end
  end
  chunks << current_chunk unless current_chunk.empty?

  chunks.each do |chunk|
    send_discord_message(thread_id, "```\n#{chunk}\n```", token: bot_token)
    sleep 0.5
  end
end

# --- Cancel (❌) ---

def handle_cancel_reaction(agent_key, agent_name, channel_id, message_id, bot_token)
  session_key = "discord-#{agent_key}-#{channel_id}-#{message_id}"

  ACTIVE_SESSIONS_MUTEX.synchronize do
    session_info = ACTIVE_SESSIONS[session_key]

    unless session_info
      LOG.info "[Discord:#{agent_name}] ❌ reaction on #{message_id} but no active session found"
      return
    end

    LOG.info "[Discord:#{agent_name}] Cancelling session for message #{message_id} (PID: #{session_info[:pid]})"

    begin
      Process.kill("KILL", session_info[:pid])
      LOG.info "[Discord:#{agent_name}] Killed agent process #{session_info[:pid]}"
    rescue Errno::ESRCH
      LOG.warn "[Discord:#{agent_name}] Process #{session_info[:pid]} already exited"
    rescue Errno::EPERM
      LOG.error "[Discord:#{agent_name}] Permission denied killing process #{session_info[:pid]}"
    end

    ACTIVE_SESSIONS.delete(session_key)

    begin
      remove_discord_reaction(channel_id, message_id, "👀", token: bot_token)
      add_discord_reaction(channel_id, message_id, "🛑", token: bot_token)
    rescue StandardError => e
      LOG.warn "[Discord:#{agent_name}] Failed to update reactions: #{e.message}"
    end

    session_info[:draft_files]&.each { |file| FileUtils.rm_f(file) }
  end
end

# --- Emoji Feedback Logging ---

def log_emoji_feedback(channel_id, message_id, user_id, emoji_name, agent_key, agent_name, bot_token)
  msg = fetch_discord_message(channel_id, message_id, token: bot_token, log_errors: false)
  return unless msg&.dig("author", "bot")

  bot_user_id = DISCORD_BOTS_MUTEX.synchronize { DISCORD_BOTS.dig(agent_key, :user_id) }
  return unless bot_user_id && msg.dig("author", "id") == bot_user_id

  reactor = find_user_by_discord_id(user_id)
  reactor_name = reactor ? reactor["canonical_name"] : user_id

  snippet = (msg["content"] || "")[0, 80].tr("\n", " ").strip
  snippet = "#{snippet}..." if (msg["content"] || "").length > 80

  feedback_dir = File.join(persona_dir_for(agent_name), "people")
  FileUtils.mkdir_p(feedback_dir)
  feedback_file = File.join(feedback_dir, "#{reactor_name.downcase.gsub(/[^a-z0-9]/, "-")}-feedback.md")

  timestamp = Time.now.strftime("%Y-%m-%d %H:%M")
  entry = "- #{timestamp} #{emoji_name} on: \"#{snippet}\" (channel: #{channel_id})\n"

  if File.exist?(feedback_file)
    File.open(feedback_file, "a") { |f| f.write(entry) }
  else
    File.write(feedback_file, "# Feedback from #{reactor_name}\n\n## Reaction Log\n#{entry}")
  end

  LOG.info "[Discord:#{agent_name}] Logged #{emoji_name} feedback from #{reactor_name} on message #{message_id}"
end
