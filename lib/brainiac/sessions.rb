# frozen_string_literal: true

# Session tracking, deduplication, cooldowns, and agent dispatch depth.

# --- Deduplication ---

PROCESSED_EVENTS = {}
PROCESSED_EVENTS_MAX = 1000

def already_processed?(event_id)
  return false unless event_id
  return true if PROCESSED_EVENTS[event_id]

  PROCESSED_EVENTS[event_id] = Time.now
  if PROCESSED_EVENTS.size > PROCESSED_EVENTS_MAX
    oldest = PROCESSED_EVENTS.keys.first(PROCESSED_EVENTS.size - PROCESSED_EVENTS_MAX)
    oldest.each { |k| PROCESSED_EVENTS.delete(k) }
  end
  false
end

# --- Active sessions ---

ACTIVE_SESSIONS = {}
ACTIVE_SESSIONS_MUTEX = Mutex.new
RECENT_SESSIONS = []
RECENT_SESSIONS_MAX = 10

# --- Self-move tracking (suppress webhook echoes from our own column moves) ---

SELF_MOVES = {}
SELF_MOVES_MUTEX = Mutex.new

def record_self_move(card_number)
  SELF_MOVES_MUTEX.synchronize { SELF_MOVES[card_number.to_s] = Time.now }
end

def self_move_recent?(card_number, window: 120)
  SELF_MOVES_MUTEX.synchronize do
    t = SELF_MOVES[card_number.to_s]
    t && (Time.now - t) < window
  end
end

# Archive a completed session for menu bar display. Call inside ACTIVE_SESSIONS_MUTEX.
def archive_session(card_key, info)
  RECENT_SESSIONS.unshift({
                            card_key: card_key, agent_name: info[:agent_name],
                            log_file: info[:log_file], started_at: info[:started_at],
                            finished_at: Time.now
                          })
  RECENT_SESSIONS.pop while RECENT_SESSIONS.size > RECENT_SESSIONS_MAX
end

def recently_completed?(card_key, window: 120)
  ACTIVE_SESSIONS_MUTEX.synchronize do
    RECENT_SESSIONS.any? do |s|
      s[:card_key] == card_key && (Time.now - s[:finished_at]) < window
    end
  end
end

def session_active?(card_key)
  ACTIVE_SESSIONS_MUTEX.synchronize do
    info = ACTIVE_SESSIONS[card_key]
    return false unless info

    begin
      Process.kill(0, info[:pid])
      true
    rescue Errno::ESRCH, Errno::EPERM
      archive_session(card_key, info)
      ACTIVE_SESSIONS.delete(card_key)
      false
    end
  end
end

SESSION_WAIT_INTERVAL = 15
SESSION_WAIT_MAX      = 600

def wait_for_session?(card_key)
  return true unless session_active?(card_key)

  LOG.info "Waiting for active session on #{card_key} to finish..."
  elapsed = 0
  while session_active?(card_key) && elapsed < SESSION_WAIT_MAX
    sleep SESSION_WAIT_INTERVAL
    elapsed += SESSION_WAIT_INTERVAL
    LOG.info "Still waiting on #{card_key} (#{elapsed}s elapsed)"
  end

  if session_active?(card_key)
    LOG.warn "Timed out waiting for session on #{card_key} after #{SESSION_WAIT_MAX}s"
    false
  else
    LOG.info "Session on #{card_key} finished after ~#{elapsed}s, proceeding"
    true
  end
end

# Recursively collect all descendant processes of a given PID via /proc.
# Returns array of hashes: { pid:, ppid:, cmd:, elapsed_seconds: }
def child_processes_for(pid)
  children_map = build_proc_children_map
  descendants = []
  queue = [pid]

  while (current = queue.shift)
    (children_map[current] || []).each do |child_pid|
      queue << child_pid
      cmdline = read_proc_cmdline(child_pid)
      elapsed = read_proc_elapsed(child_pid)
      descendants << { pid: child_pid, ppid: current, cmd: cmdline, elapsed_seconds: elapsed }
    end
  end
  descendants
rescue StandardError => e
  LOG.warn "Failed to enumerate child processes for PID #{pid}: #{e.message}"
  []
end

# Build a ppid→children map from /proc in one pass.
def build_proc_children_map
  children_map = Hash.new { |h, k| h[k] = [] }
  Dir.glob("/proc/[0-9]*/stat").each do |stat_path|
    content = begin
      File.read(stat_path)
    rescue StandardError
      next
    end
    close_paren = content.rindex(")")
    next unless close_paren

    prefix_pid = content[0...content.index("(")].strip.to_i
    fields_after = content[(close_paren + 2)..].split
    ppid = fields_after[1].to_i
    children_map[ppid] << prefix_pid
  end
  children_map
end

# Read command line for a given PID from /proc.
def read_proc_cmdline(pid)
  File.read("/proc/#{pid}/cmdline").tr("\0", " ").strip
rescue StandardError
  "(unknown)"
end

# Calculate elapsed seconds since process start from /proc/stat.
def read_proc_elapsed(pid)
  stat_content = File.read("/proc/#{pid}/stat")
rescue StandardError
  0
else
  cp = stat_content.rindex(")")
  starttime_ticks = begin
    stat_content[(cp + 2)..].split[19].to_i
  rescue StandardError
    0
  end
  clk_tck = 100
  uptime = begin
    File.read("/proc/uptime").split[0].to_f
  rescue StandardError
    0
  end
  start_seconds = starttime_ticks.to_f / clk_tck
  (uptime - start_seconds).to_i.clamp(0, Float::INFINITY).to_i
end

def register_session(card_key, pid, log_file: nil, message_id: nil, channel_id: nil, supersede_key: nil, draft_files: nil, agent_name: nil)
  ACTIVE_SESSIONS_MUTEX.synchronize do
    ACTIVE_SESSIONS[card_key] = {
      pid: pid, started_at: Time.now, log_file: log_file,
      message_id: message_id, channel_id: channel_id, supersede_key: supersede_key,
      draft_files: draft_files, agent_name: agent_name
    }
  end
end

# --- Session supersede (Discord follow-up within window kills previous run) ---

SUPERSEDE_WINDOW = 60 # seconds

# Find an active session for the same supersede key (agent+channel) started within the window.
# Returns the session info hash (with :session_key added) or nil.
def find_supersedable_session(supersede_key)
  ACTIVE_SESSIONS_MUTEX.synchronize do
    ACTIVE_SESSIONS.each do |key, info|
      next unless info[:supersede_key] == supersede_key
      next if (Time.now - info[:started_at]) > SUPERSEDE_WINDOW

      begin
        Process.kill(0, info[:pid])
        return info.merge(session_key: key)
      rescue Errno::ESRCH, Errno::EPERM
        next
      end
    end
  end
  nil
end

# Kill a session's process. Returns true if killed.
def kill_session(session_key)
  ACTIVE_SESSIONS_MUTEX.synchronize do
    info = ACTIVE_SESSIONS[session_key]
    return false unless info

    # Kill child processes first (bottom-up), then the parent
    children = child_processes_for(info[:pid])
    children.reverse_each do |child|
      Process.kill("KILL", child[:pid])
    rescue StandardError
      nil
    end
    begin
      Process.kill("KILL", info[:pid])
    rescue Errno::ESRCH, Errno::EPERM
      # already gone
    end
    archive_session(session_key, info)
    ACTIVE_SESSIONS.delete(session_key)
    true
  end
end

# --- Comment cooldown ---

COMMENT_COOLDOWN = 60
LAST_COMMENT_TIMES = {}

def on_comment_cooldown?(card_key)
  last = LAST_COMMENT_TIMES[card_key]
  last && (Time.now - last) < COMMENT_COOLDOWN
end

def touch_comment_cooldown(card_key)
  LAST_COMMENT_TIMES[card_key] = Time.now
end

# --- Deploy cooldown (debounce rapid PR pushes) ---

DEPLOY_COOLDOWN = 30
LAST_DEPLOY_TIMES = {}

def on_deploy_cooldown?(env_key)
  last = LAST_DEPLOY_TIMES[env_key]
  last && (Time.now - last) < DEPLOY_COOLDOWN
end

def touch_deploy_cooldown(env_key)
  LAST_DEPLOY_TIMES[env_key] = Time.now
end

# --- Agent dispatch depth (loop prevention) ---

AGENT_DISPATCH_DEPTH = {}
AGENT_DISPATCH_MAX_DEPTH = 10
AGENT_DISPATCH_WINDOW = 3600

def record_human_comment(card_internal_id)
  AGENT_DISPATCH_DEPTH[card_internal_id] = { count: 0, last_human_at: Time.now }
end

def agent_dispatch_allowed?(card_internal_id)
  info = AGENT_DISPATCH_DEPTH[card_internal_id]
  return false unless info
  return false if (Time.now - info[:last_human_at]) > AGENT_DISPATCH_WINDOW

  info[:count] < AGENT_DISPATCH_MAX_DEPTH
end

def record_agent_dispatch(card_internal_id)
  info = AGENT_DISPATCH_DEPTH[card_internal_id]
  if info
    info[:count] += 1
  else
    AGENT_DISPATCH_DEPTH[card_internal_id] = { count: 1, last_human_at: Time.now }
  end
end
