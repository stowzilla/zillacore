# frozen_string_literal: true

# Discord draft delivery system.
#
# Response files land in draft/ with a .meta.json sidecar containing delivery info.
# After successful posting, both files move to posted/.
# A poller thread recovers orphaned drafts (e.g. after a server restart).

DISCORD_DRAFT_DIR  = File.join(BRAINIAC_DIR, "tmp", "discord", "draft")
DISCORD_POSTED_DIR = File.join(BRAINIAC_DIR, "tmp", "discord", "posted")
FileUtils.mkdir_p(DISCORD_DRAFT_DIR)
FileUtils.mkdir_p(DISCORD_POSTED_DIR)

# Shared thread map: when multiple agents are mentioned in the same message,
# the first to deliver creates the thread and stores its ID here so the rest
# post into the same thread instead of creating duplicates.
DISCORD_SHARED_THREADS = {}
DISCORD_SHARED_THREADS_MUTEX = Mutex.new

# Shared logic for posting a draft response file to Discord and moving it to posted/.
# Used by both the monitoring thread (happy path) and the poller (recovery path).
def deliver_discord_draft(response_file, meta_file)
  return false unless File.exist?(meta_file)

  lock_file = "#{meta_file}.lock"
  begin
    File.open(lock_file, File::CREAT | File::EXCL | File::WRONLY) {} # rubocop:disable Lint/EmptyBlock
  rescue Errno::EEXIST
    return false
  end

  meta = JSON.parse(File.read(meta_file))
  bot_token = resolve_bot_token(meta["agent_key"], meta["agent_name"])

  unless bot_token
    FileUtils.rm_f(lock_file)
    return false
  end

  unless File.exist?(response_file)
    FileUtils.rm_f(lock_file)
    return false
  end

  deliver_response_content(response_file, meta, bot_token)
  archive_delivered_draft(response_file, meta_file, lock_file, meta["agent_name"])
  true
rescue StandardError => e
  LOG.error "[Discord] Failed to deliver draft #{meta_file}: #{e.message}"
  File.delete(lock_file) if lock_file && File.exist?(lock_file)
  false
end

def resolve_bot_token(agent_key, agent_name)
  token = DISCORD_BOTS_MUTEX.synchronize { DISCORD_BOTS.dig(agent_key, :token) }
  token ||= (AGENT_REGISTRY.dig(agent_key, "env") || {})["DISCORD_BOT_TOKEN"]
  LOG.warn "[Discord:#{agent_name}] No bot token found for #{agent_key}, cannot deliver draft" unless token
  token
end

def deliver_response_content(response_file, meta, bot_token)
  channel_id = meta["channel_id"]
  message_id = meta["message_id"]
  agent_key = meta["agent_key"]
  agent_name = meta["agent_name"]
  response = File.read(response_file).strip

  if response.empty?
    add_discord_reaction(channel_id, message_id, "😶", token: bot_token) if message_id
    send_discord_message(channel_id, "_#{agent_name} had nothing to say._", token: bot_token)
  elsif meta["is_dm"] || meta["is_thread"] || message_id.nil?
    deliver_to_dm_or_forum(response, channel_id, message_id, agent_name, meta, bot_token)
  else
    deliver_to_channel_thread(response, channel_id, message_id, agent_key, agent_name, meta["clean_content"] || "", bot_token)
  end
end

def archive_delivered_draft(response_file, meta_file, lock_file, agent_name)
  FileUtils.mv(response_file, File.join(DISCORD_POSTED_DIR, File.basename(response_file))) if File.exist?(response_file)
  FileUtils.mv(meta_file, File.join(DISCORD_POSTED_DIR, File.basename(meta_file)))
  FileUtils.rm_f(lock_file)
  LOG.info "[Discord:#{agent_name}] Draft delivered and moved to posted/"
end

# --- Delivery to DMs, threads, and forum channels ---

def deliver_to_dm_or_forum(response, channel_id, message_id, agent_name, meta, bot_token)
  if message_id.nil? && forum_channel?(channel_id, token: bot_token)
    title = meta["forum_title"] || "#{agent_name} — #{Time.now.strftime("%b %d, %Y")}"
    if meta["forum_reply_to_latest"]
      latest_thread = find_latest_forum_thread(channel_id, token: bot_token)
      if latest_thread
        send_long_discord_message(latest_thread["id"], response, token: bot_token)
      else
        LOG.warn "[Discord:#{agent_name}] No existing thread found, creating new forum post"
        create_forum_post(channel_id, title: title, content: response, token: bot_token)
      end
    else
      create_forum_post(channel_id, title: title, content: response, token: bot_token)
    end
  else
    send_long_discord_message(channel_id, response, token: bot_token)
  end
end

# --- Delivery to channel messages (creates or joins a thread) ---

def deliver_to_channel_thread(response, channel_id, message_id, agent_key, agent_name, clean_content, bot_token)
  thread_id = nil
  created_thread = false

  DISCORD_SHARED_THREADS_MUTEX.synchronize do
    thread_id = DISCORD_SHARED_THREADS[message_id]

    # Tier 2: Ask Discord if a thread already exists on this message.
    unless thread_id
      original_msg = discord_api(:get, "/channels/#{channel_id}/messages/#{message_id}", token: bot_token)
      if original_msg&.dig("thread", "id")
        thread_id = original_msg["thread"]["id"]
        DISCORD_SHARED_THREADS[message_id] = thread_id
        LOG.info "[Discord:#{agent_name}] Discovered existing thread #{thread_id} on message #{message_id} via API"
      end
    end

    # Tier 3: No thread exists anywhere — create one.
    unless thread_id
      display_name = agent_display_name(agent_key)
      thread = create_discord_thread(channel_id, message_id, name: "#{display_name}: #{clean_content[0..80]}", token: bot_token)
      if thread && thread["id"]
        thread_id = thread["id"]
        DISCORD_SHARED_THREADS[message_id] = thread_id
        created_thread = true
        LOG.info "[Discord:#{agent_name}] Created shared thread #{thread_id} for message #{message_id}"
      end
    end
  end

  if thread_id
    LOG.info "[Discord:#{agent_name}] Joining shared thread #{thread_id} for message #{message_id}" unless created_thread

    # Propagate dispatch depth to the thread
    parent_depth_key = "discord-#{channel_id}"
    thread_depth_key = "discord-#{thread_id}"
    parent_info = AGENT_DISPATCH_DEPTH[parent_depth_key]
    unless AGENT_DISPATCH_DEPTH[thread_depth_key]
      if parent_info
        AGENT_DISPATCH_DEPTH[thread_depth_key] = { count: 0, last_human_at: parent_info[:last_human_at] }
        LOG.info "[Discord:#{agent_name}] Propagated dispatch depth from channel #{channel_id} to thread #{thread_id}"
      else
        record_human_comment(thread_depth_key)
      end
    end

    send_discord_typing(thread_id, token: bot_token)
    send_long_discord_message(thread_id, response, token: bot_token)
  else
    LOG.warn "[Discord:#{agent_name}] Thread creation failed, falling back to reply"
    send_long_discord_message(channel_id, response, token: bot_token, reply_to: message_id)
  end
end

# --- Draft Poller ---

DISCORD_DRAFT_POLLER_INTERVAL = 5   # seconds
DISCORD_DRAFT_MIN_AGE = 30          # seconds — don't race the monitoring thread

def start_discord_draft_poller
  Thread.new do
    LOG.info "[Discord] Draft poller started, checking #{DISCORD_DRAFT_DIR} every #{DISCORD_DRAFT_POLLER_INTERVAL}s"
    loop do
      sleep DISCORD_DRAFT_POLLER_INTERVAL
      begin
        # Clean up stale lock files (older than 60s) left by crashed deliveries
        Dir.glob(File.join(DISCORD_DRAFT_DIR, "*.lock")).each do |lock_file|
          File.delete(lock_file) if (Time.now - File.mtime(lock_file)) > 60
        end

        Dir.glob(File.join(DISCORD_DRAFT_DIR, "*.meta.json")).each do |meta_file|
          next if (Time.now - File.mtime(meta_file)) < DISCORD_DRAFT_MIN_AGE

          response_file = if meta_file.end_with?(".md.meta.json")
                            meta_file.sub(".md.meta.json", ".md")
                          else
                            meta_file.sub(".meta.json", ".md")
                          end
          next unless File.exist?(response_file)

          LOG.info "[Discord] Poller recovering orphaned draft: #{File.basename(meta_file)}"
          deliver_discord_draft(response_file, meta_file)
        end
      rescue StandardError => e
        LOG.error "[Discord] Draft poller error: #{e.message}"
      end
    end
  end
end
