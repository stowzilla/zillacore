# frozen_string_literal: true

# Brainiac Cron — scheduled agent tasks
#
# Runs in a background thread, checks cron jobs every minute,
# dispatches agents with natural language prompts on schedule.

require "English"
require "time"
require "json"

CRON_CONFIG_FILE = File.join(BRAINIAC_DIR, "cron.json")
CRON_JOBS = {}
CRON_JOBS_MUTEX = Mutex.new
CRON_THREAD = { ref: nil }

# Parse cron expression (simplified: supports minute, hour, day, month, weekday)
# Format: "minute hour day month weekday" (e.g., "0 9 * * 1-5" = 9am weekdays)
# Also supports special strings: @hourly, @daily, @weekly, @monthly
# Also supports one-time timestamps: ISO8601 format (e.g., "2026-02-27T09:00:00-05:00")
# Also supports natural language: "tomorrow at 9am", "in 2 hours", "next monday at 3pm"
def parse_cron_expression(expr)
  case expr
  when "@hourly"   then { minute: 0, hour: "*", day: "*", month: "*", weekday: "*" }
  when "@daily"    then { minute: 0, hour: 0, day: "*", month: "*", weekday: "*" }
  when "@weekly"   then { minute: 0, hour: 0, day: "*", month: "*", weekday: 0 }
  when "@monthly"  then { minute: 0, hour: 0, day: 1, month: "*", weekday: "*" }
  else
    # Try parsing as natural language or ISO8601 timestamp for one-time execution
    timestamp = parse_natural_time(expr)
    return { one_time: true, timestamp: timestamp } if timestamp

    parts = expr.split
    return nil unless parts.size == 5

    { minute: parts[0], hour: parts[1], day: parts[2], month: parts[3], weekday: parts[4] }
  end
end

# Parse natural language time expressions into absolute timestamps
def parse_natural_time(expr)
  now = Time.now

  # Try ISO8601 first
  begin
    return Time.parse(expr)
  rescue ArgumentError
    # Not ISO8601, try natural language
  end

  # "tomorrow at HH:MM" or "tomorrow at HHam/pm"
  if expr =~ /^tomorrow\s+at\s+(.+)$/i
    time_str = Regexp.last_match(1)
    tomorrow = now + 86_400
    parsed_time = parse_time_of_day(time_str, tomorrow)
    return parsed_time if parsed_time
  end

  # "in X hours/minutes/days"
  if expr =~ /^in\s+(\d+)\s+(hour|minute|day)s?$/i
    amount = Regexp.last_match(1).to_i
    unit = Regexp.last_match(2).downcase
    case unit
    when "minute" then return now + (amount * 60)
    when "hour"   then return now + (amount * 3600)
    when "day"    then return now + (amount * 86_400)
    end
  end

  # "next monday/tuesday/etc at HH:MM"
  weekdays = { "sunday" => 0, "monday" => 1, "tuesday" => 2, "wednesday" => 3,
               "thursday" => 4, "friday" => 5, "saturday" => 6 }
  if expr =~ /^next\s+(#{weekdays.keys.join("|")})\s+at\s+(.+)$/i
    target_wday = weekdays[Regexp.last_match(1).downcase]
    time_str = Regexp.last_match(2)
    days_ahead = (target_wday - now.wday + 7) % 7
    days_ahead = 7 if days_ahead.zero? # "next monday" means next week if today is monday
    target_date = now + (days_ahead * 86_400)
    parsed_time = parse_time_of_day(time_str, target_date)
    return parsed_time if parsed_time
  end

  nil
end

# Parse time of day (e.g., "9am", "3:30pm", "14:00") and combine with a date
def parse_time_of_day(time_str, date)
  # "9am" or "3pm"
  if time_str =~ /^(\d+)(am|pm)$/i
    hour = convert_meridiem_hour(Regexp.last_match(1).to_i, Regexp.last_match(2).downcase)
    return Time.new(date.year, date.month, date.day, hour, 0, 0, date.utc_offset)
  end

  # "9:30am" or "3:45pm"
  if time_str =~ /^(\d+):(\d+)(am|pm)$/i
    hour = convert_meridiem_hour(Regexp.last_match(1).to_i, Regexp.last_match(3).downcase)
    minute = Regexp.last_match(2).to_i
    return Time.new(date.year, date.month, date.day, hour, minute, 0, date.utc_offset)
  end

  # "14:00" (24-hour format)
  if time_str =~ /^(\d+):(\d+)$/
    hour = Regexp.last_match(1).to_i
    minute = Regexp.last_match(2).to_i
    return Time.new(date.year, date.month, date.day, hour, minute, 0, date.utc_offset)
  end

  nil
end

# Convert 12-hour format hour + meridiem to 24-hour format.
def convert_meridiem_hour(hour, meridiem)
  hour = 0 if hour == 12 && meridiem == "am"
  hour += 12 if meridiem == "pm" && hour < 12
  hour
end

# Check if current time matches cron expression
def cron_matches?(cron_hash, time = Time.now)
  return false unless cron_hash

  # Handle one-time scheduled tasks
  if cron_hash[:one_time]
    target = cron_hash[:timestamp]
    # Match if we're within the same minute as the target time
    return time.year == target.year &&
           time.month == target.month &&
           time.day == target.day &&
           time.hour == target.hour &&
           time.min == target.min
  end

  minute_match = match_field?(cron_hash[:minute], time.min)
  hour_match = match_field?(cron_hash[:hour], time.hour)
  day_match = match_field?(cron_hash[:day], time.day)
  month_match = match_field?(cron_hash[:month], time.month)
  weekday_match = match_field?(cron_hash[:weekday], time.wday)

  minute_match && hour_match && day_match && month_match && weekday_match
end

def match_field?(pattern, value)
  return true if pattern == "*"

  # Handle ranges (e.g., "1-5")
  if pattern.include?("-")
    range_start, range_end = pattern.split("-").map(&:to_i)
    return value.between?(range_start, range_end)
  end

  # Handle lists (e.g., "1,3,5")
  return pattern.split(",").map(&:to_i).include?(value) if pattern.include?(",")

  # Handle step values (e.g., "*/5")
  if pattern.include?("/")
    base, step = pattern.split("/")
    step = step.to_i
    return (value % step).zero? if base == "*"
  end

  # Exact match
  pattern.to_i == value
end

# Load cron jobs from config
def load_cron_jobs
  return {} unless File.exist?(CRON_CONFIG_FILE)

  jobs = JSON.parse(File.read(CRON_CONFIG_FILE), symbolize_names: true)

  # Deserialize timestamp strings back to Time objects for one-time jobs
  jobs.each_value do |job|
    next unless job[:parsed]

    job[:parsed][:timestamp] = Time.parse(job[:parsed][:timestamp]) if job[:parsed][:one_time] && job[:parsed][:timestamp].is_a?(String)
  end

  jobs
rescue JSON::ParserError => e
  LOG.error "[Cron] Failed to parse cron config: #{e.message}"
  {}
end

# Save cron jobs to config
def save_cron_jobs(jobs)
  FileUtils.mkdir_p(BRAINIAC_DIR)
  File.write(CRON_CONFIG_FILE, JSON.pretty_generate(jobs))
end

# Reload cron jobs from disk
def reload_cron_jobs!(force: false)
  return unless file_changed?(CRON_CONFIG_FILE, force: force)

  CRON_JOBS_MUTEX.synchronize do
    CRON_JOBS.clear
    CRON_JOBS.merge!(load_cron_jobs)
  end
  LOG.info "[Cron] Reloaded #{CRON_JOBS.size} cron jobs"
end

# Add a new cron job
def add_cron_job(id:, schedule:, agent:, project:, prompt: nil, script: nil, enabled: true, model: nil, effort: nil, discord_channel_id: nil,
                 forum_title: nil, forum_reply_to_latest: false, repeat_count: nil)
  parsed = parse_cron_expression(schedule)
  return { error: "Invalid cron expression" } unless parsed
  return { error: "Must provide either prompt or script, not both" } if prompt && script
  return { error: "Must provide either prompt or script" } unless prompt || script

  job = {
    id: id,
    schedule: schedule,
    parsed: parsed,
    agent: agent,
    project: project,
    model: model,
    effort: effort,
    prompt: prompt,
    script: script,
    enabled: enabled,
    discord_channel_id: discord_channel_id,
    forum_title: forum_title,
    forum_reply_to_latest: forum_reply_to_latest,
    repeat_count: repeat_count,
    execution_count: 0,
    created_at: Time.now.iso8601,
    last_run: nil
  }

  CRON_JOBS_MUTEX.synchronize do
    jobs = load_cron_jobs
    jobs[id.to_sym] = job
    save_cron_jobs(jobs)
    CRON_JOBS[id.to_sym] = job
  end

  { success: true, job: job }
end

# Remove a cron job
def remove_cron_job(id)
  CRON_JOBS_MUTEX.synchronize do
    jobs = load_cron_jobs
    removed = jobs.delete(id.to_sym)
    save_cron_jobs(jobs)
    CRON_JOBS.delete(id.to_sym)
    removed ? { success: true } : { error: "Job not found" }
  end
end

# Enable/disable a cron job
def toggle_cron_job(id, enabled)
  CRON_JOBS_MUTEX.synchronize do
    jobs = load_cron_jobs
    job = jobs[id.to_sym]
    return { error: "Job not found" } unless job

    job[:enabled] = enabled
    jobs[id.to_sym] = job
    save_cron_jobs(jobs)
    CRON_JOBS[id.to_sym] = job
    { success: true, job: job }
  end
end

# Update a cron job's schedule, discord channel, and/or forum title
def update_cron_job(id, schedule: nil, discord_channel_id: nil, forum_title: nil, forum_reply_to_latest: nil)
  return { error: "No updates provided" } if schedule.nil? && discord_channel_id.nil? && forum_title.nil? && forum_reply_to_latest.nil?

  if schedule
    parsed = parse_cron_expression(schedule)
    return { error: "Invalid cron expression" } unless parsed
  end

  CRON_JOBS_MUTEX.synchronize do
    jobs = load_cron_jobs
    job = jobs[id.to_sym]
    return { error: "Job not found" } unless job

    if schedule
      job[:schedule] = schedule
      job[:parsed] = parsed
    end
    job[:discord_channel_id] = discord_channel_id if discord_channel_id
    job[:forum_title] = forum_title if forum_title
    job[:forum_reply_to_latest] = forum_reply_to_latest unless forum_reply_to_latest.nil?
    jobs[id.to_sym] = job
    save_cron_jobs(jobs)
    CRON_JOBS[id.to_sym] = job
    { success: true, job: job }
  end
end

# Execute a script-based cron job (no agent, direct script execution)
def execute_script_job(job, project)
  script_path = File.expand_path(job[:script])

  unless File.exist?(script_path)
    LOG.error "[Cron] Script not found: #{script_path}"
    return
  end

  unless File.executable?(script_path)
    LOG.error "[Cron] Script not executable: #{script_path}"
    return
  end

  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
  log_file = File.join(project["repo_path"], "tmp/cron-script-#{job[:id]}-#{timestamp}.log")
  FileUtils.mkdir_p(File.dirname(log_file))

  draft_file = prepare_script_discord_draft(job, timestamp) if job[:discord_channel_id]

  LOG.info "[Cron] Running script #{script_path} for job #{job[:id]}, tail -f #{log_file}"

  pid = spawn(script_path,
              chdir: project["repo_path"],
              out: [log_file, "w"],
              err: %i[child out])

  Thread.new do
    Process.wait(pid)
    LOG.info "[Cron] Script job #{job[:id]} finished (exit: #{$CHILD_STATUS.exitstatus})"
    deliver_script_output(job, log_file, draft_file)
    update_cron_job_state(job)
  rescue StandardError => e
    LOG.error "[Cron] Script job #{job[:id]} failed: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
  end
end

# Prepare a Discord draft file and meta for a script job. Returns the draft file path.
def prepare_script_discord_draft(job, timestamp)
  draft_file = File.join(DISCORD_DRAFT_DIR, "cron-script-#{timestamp}-#{job[:id]}.md")
  meta_file = "#{draft_file}.meta.json"

  FileUtils.mkdir_p(File.dirname(draft_file))

  script_agent_key = job[:agent]&.downcase&.gsub(/[^a-z0-9-]/, "-")
  meta = {
    channel_id: job[:discord_channel_id],
    agent_key: script_agent_key,
    agent_name: job[:agent] || "Script",
    cron_job_id: job[:id],
    forum_title: job[:forum_title],
    forum_reply_to_latest: job[:forum_reply_to_latest],
    created_at: Time.now.iso8601
  }
  File.write(meta_file, JSON.pretty_generate(meta))
  draft_file
end

# Read script output and write to draft file or log.
def deliver_script_output(job, log_file, draft_file)
  return unless File.exist?(log_file)

  output = File.read(log_file).strip

  if job[:discord_channel_id] && draft_file && !output.empty?
    File.write(draft_file, output)
    LOG.info "[Cron] Script output written to #{draft_file} (#{output.length} chars)"
  elsif !output.empty?
    LOG.info "[Cron] Script output: #{output[0..200]}..."
  else
    LOG.warn "[Cron] Script produced no output"
  end
end

# Build the prompt content and meta files for a cron job
def build_cron_prompt(job, project)
  prompt = job[:prompt]
  agent_name = job[:agent]
  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")

  if job[:discord_channel_id]
    draft_file = File.join(DISCORD_DRAFT_DIR, "cron-#{timestamp}-#{agent_name}-#{job[:id]}.md")
    meta_file = "#{draft_file}.meta.json"
    FileUtils.mkdir_p(File.dirname(draft_file))

    agent_key = agent_name.downcase.gsub(/[^a-z0-9-]/, "-")
    meta = {
      channel_id: job[:discord_channel_id],
      agent_key: agent_key,
      agent_name: agent_name,
      cron_job_id: job[:id],
      forum_title: job[:forum_title],
      forum_reply_to_latest: job[:forum_reply_to_latest],
      created_at: Time.now.iso8601
    }
    File.write(meta_file, JSON.pretty_generate(meta))

    full_prompt = <<~PROMPT
      ## Scheduled Task (Discord Posting)
      This is a scheduled cron job that will post to Discord channel #{job[:discord_channel_id]}.

      You were asked to: "#{prompt}"

      Project: #{job[:project]}
      Source directory: #{project["repo_path"]}

      **IMPORTANT: Write your response to #{draft_file}. Do NOT reply via stdout.**
      Your response will be automatically posted to Discord.

      #{prompt}
    PROMPT

    { response_file: draft_file, meta_file: meta_file, full_prompt: full_prompt }
  else
    response_file = File.join(BRAINIAC_DIR, "tmp", "cron", "cron-#{job[:id]}-#{Time.now.to_i}.md")
    FileUtils.mkdir_p(File.dirname(response_file))

    full_prompt = <<~PROMPT
      ## Scheduled Task
      This is a scheduled cron job. You were asked to: "#{prompt}"

      Project: #{job[:project]}
      Source directory: #{project["repo_path"]}

      Write your response to: #{response_file}

      #{prompt}
    PROMPT

    { response_file: response_file, meta_file: nil, full_prompt: full_prompt }
  end
end

# Handle post-execution: extract response from log, update job state
def handle_cron_completion(job, project, agent_name, agent_config_name, log_file, response_file, meta_file)
  cron_exit_status = $CHILD_STATUS.exitstatus
  LOG.info "[Cron] Job #{job[:id]} finished (exit: #{cron_exit_status})"

  if cron_exit_status && cron_exit_status != 0 && job[:discord_channel_id]
    bot_token = discord_bot_tokens[agent_config_name] || discord_bot_tokens.values.first
    if bot_token
      notify_agent_crash(
        exit_status: cron_exit_status, log_file: log_file,
        agent_name: agent_name, source: :discord,
        source_context: { channel_id: job[:discord_channel_id], bot_token: bot_token },
        project_config: project
      )
    end
  end

  extract_cron_response_from_log(job, agent_config_name, log_file, response_file, meta_file)

  qmd_out, qmd_status = Open3.capture2e("qmd", "update")
  if qmd_status.success?
    LOG.info "[Brain] qmd update completed after cron job #{job[:id]}"
  else
    LOG.warn "[Brain] qmd update failed: #{qmd_out.strip}"
  end

  brain_push(message: "#{agent_config_name}: cron-#{job[:id]}")
  update_cron_job_state(job)

  if File.exist?(response_file)
    LOG.info "[Cron] Job #{job[:id]} completed. Response: #{File.read(response_file)[0..100]}..."
  else
    LOG.warn "[Cron] Job #{job[:id]} produced no response"
  end
end

# Extract agent response from log if the response file wasn't written directly
def extract_cron_response_from_log(job, agent_config_name, log_file, response_file, meta_file)
  return if File.exist?(response_file)
  return unless File.exist?(log_file)

  log_content = File.read(log_file)

  if log_content.match?(/Opening browser\.\.\.|Press \(\^\) \+ C to cancel/)
    LOG.error "[Cron] Auth failure detected for job #{job[:id]} — " \
              "re-authenticate with: kiro-cli --agent #{agent_config_name} chat"
    File.delete(meta_file) if meta_file && File.exist?(meta_file)
    return
  end

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

  return unless !clean_output.empty? && clean_output.length > 20

  File.write(response_file, clean_output)
  LOG.info "[Cron] Extracted response from log (#{clean_output.length} chars)"
end

# Update cron job state after execution (last_run, execution_count, auto-disable)
def update_cron_job_state(job)
  CRON_JOBS_MUTEX.synchronize do
    jobs = load_cron_jobs
    job_data = jobs[job[:id].to_sym]
    return unless job_data

    job_data[:last_run] = Time.now.iso8601
    job_data[:execution_count] = (job_data[:execution_count] || 0) + 1

    if job[:parsed][:one_time]
      job_data[:enabled] = false
      CRON_JOBS[job[:id].to_sym][:enabled] = false
      LOG.info "[Cron] Auto-disabled one-time job: #{job[:id]}"
    elsif job[:repeat_count] && job_data[:execution_count] >= job[:repeat_count]
      job_data[:enabled] = false
      CRON_JOBS[job[:id].to_sym][:enabled] = false
      LOG.info "[Cron] Auto-disabled job #{job[:id]} after #{job[:repeat_count]} executions"
    end

    save_cron_jobs(jobs)
    CRON_JOBS[job[:id].to_sym][:last_run] = Time.now.iso8601
    CRON_JOBS[job[:id].to_sym][:execution_count] = job_data[:execution_count]
  end
end

# Execute a cron job (dispatch agent)
def execute_cron_job(job)
  return unless job[:enabled]

  LOG.info "[Cron] Executing job #{job[:id]}: #{job[:prompt] || job[:script]}..."

  project = PROJECTS[job[:project]]
  unless project
    LOG.error "[Cron] Project #{job[:project]} not found for job #{job[:id]}"
    return
  end

  if job[:script]
    execute_script_job(job, project)
    return
  end

  agent_name = job[:agent]
  agent_config_name = agent_name.downcase.gsub(/[^a-z0-9-]/, "-")
  prompt_data = build_cron_prompt(job, project)
  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")

  log_file = File.join(project["repo_path"], "tmp/agent-cron-#{job[:id]}-#{timestamp}.log")
  FileUtils.mkdir_p(File.dirname(log_file))

  prompt_file = write_cron_prompt_file(job, prompt_data[:full_prompt], timestamp)
  cmd = build_cron_agent_cmd(job, project)

  LOG.info "[Cron] Dispatching job #{job[:id]} with #{agent_name}, tail -f #{log_file}"

  spawn_env = agent_env_for(agent_name)
  LOG.info "[Cron] Injecting #{spawn_env.size} env var(s) for agent #{agent_name}" unless spawn_env.empty?

  pid = spawn(spawn_env, *cmd,
              chdir: project["repo_path"],
              in: prompt_file,
              out: [log_file, "w"],
              err: %i[child out])

  Thread.new do
    Process.wait(pid)
    handle_cron_completion(job, project, agent_name, agent_config_name, log_file, prompt_data[:response_file], prompt_data[:meta_file])
  rescue StandardError => e
    LOG.error "[Cron] Job #{job[:id]} failed: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
  end
end

# Write cron prompt to a temp file, return path.
def write_cron_prompt_file(job, prompt_content, timestamp)
  prompt_dir = File.join(BRAINIAC_DIR, "tmp")
  FileUtils.mkdir_p(prompt_dir)
  prompt_file = File.join(prompt_dir, "prompt-cron-#{job[:id]}-#{timestamp}.md")
  File.write(prompt_file, prompt_content)
  prompt_file
end

# Build the CLI command array for a cron agent invocation.
def build_cron_agent_cmd(job, project)
  agent_config_name = job[:agent].downcase.gsub(/[^a-z0-9-]/, "-")
  resolved = resolve_project_cli_config(project)
  cmd = [resolved["agent_cli"]]
  cmd.push("--agent", agent_config_name)
  cmd.concat(resolved["agent_cli_args"].split)
  add_trust_tools!(cmd, resolved["agent_cli_args"])
  cmd.push(resolved["agent_model_flag"], job[:model]) if resolved["agent_model_flag"]&.length&.positive? && job[:model]
  cmd.push(resolved["agent_effort_flag"], job[:effort]) if resolved["agent_effort_flag"]&.length&.positive? && job[:effort]
  cmd
end

# Cron loop — runs every minute, checks all jobs
def cron_loop
  loop do
    now = Time.now

    # Calculate sleep time to wake up at the start of the next minute
    seconds_until_next_minute = 60 - now.sec
    sleep seconds_until_next_minute

    now = Time.now

    CRON_JOBS_MUTEX.synchronize do
      CRON_JOBS.each_value do |job|
        next unless job[:enabled]
        next unless cron_matches?(job[:parsed], now)

        # Prevent duplicate runs within the same minute
        if job[:last_run]
          last_run_time = Time.parse(job[:last_run])
          next if (now - last_run_time) < 60
        end

        execute_cron_job(job)
      end
    end
  rescue StandardError => e
    LOG.error "[Cron] Loop error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    sleep 60
  end
end

# Start cron background thread
def start_cron_thread
  return if CRON_THREAD[:ref]&.alive?

  reload_cron_jobs!

  CRON_THREAD[:ref] = Thread.new do
    LOG.info "[Cron] Starting cron thread..."
    cron_loop
  end
end
