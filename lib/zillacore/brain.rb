# frozen_string_literal: true

# Brain (long-term memory via qmd) — query, context building, and git sync.

BRAIN_SYNC_MUTEX = Mutex.new
BRAIN_LAST_PULL = { at: nil }

def memory_dir_for(agent_name)
  File.join(MEMORY_BASE_DIR, agent_name.downcase.gsub(/[^a-z0-9-]/, "-"))
end

def persona_dir_for(agent_name)
  File.join(PERSONA_BASE_DIR, agent_name.downcase.gsub(/[^a-z0-9-]/, "-"))
end

def persona_collection_for(agent_name)
  "#{agent_name.downcase.gsub(/[^a-z0-9-]/, "-")}-persona"
end

# --- Brain git sync ---

def brain_git_repo?
  File.directory?(File.join(BRAIN_BASE_DIR, ".git"))
end

# Internal pull logic without mutex (for use inside synchronized blocks)
def brain_pull_internal(force: false)
  return unless brain_git_repo?

  # Skip if we pulled within the last 30 seconds (avoid hammering on rapid-fire sessions)
  unless force
    last = BRAIN_LAST_PULL[:at]
    return if last && (Time.now - last) < 30
  end

  # Stash any uncommitted changes, pull, then pop
  status, = Open3.capture2("git", "status", "--porcelain", chdir: BRAIN_BASE_DIR)
  has_changes = !status.strip.empty?

  if has_changes
    Open3.capture2("git", "add", "-A", chdir: BRAIN_BASE_DIR)
    Open3.capture2("git", "stash", chdir: BRAIN_BASE_DIR)
  end

  output, pull_status = Open3.capture2e("git", "pull", "--rebase", "--autostash", chdir: BRAIN_BASE_DIR)
  if pull_status.success?
    LOG.info "[Brain] Pulled latest changes"
  else
    LOG.warn "[Brain] Pull failed: #{output.strip}"
    # Abort rebase if it got stuck
    Open3.capture2("git", "rebase", "--abort", chdir: BRAIN_BASE_DIR)
  end

  Open3.capture2("git", "stash", "pop", chdir: BRAIN_BASE_DIR) if has_changes

  BRAIN_LAST_PULL[:at] = Time.now
end

# Pull latest brain changes. Safe to call frequently — skips if pulled recently.
# Uses rebase to keep history clean and auto-resolves conflicts by keeping both sides.
def brain_pull(force: false)
  return unless brain_git_repo?

  BRAIN_SYNC_MUTEX.synchronize do
    brain_pull_internal(force: force)
  end
rescue StandardError => e
  LOG.warn "[Brain] Pull error: #{e.message}"
end

# Commit and push any brain changes. Called after agent sessions complete.
def brain_push(message: "brain update", retries: 3)
  return unless brain_git_repo?

  BRAIN_SYNC_MUTEX.synchronize do
    # Check for changes
    status, = Open3.capture2("git", "status", "--porcelain", chdir: BRAIN_BASE_DIR)
    return if status.strip.empty?

    Open3.capture2("git", "add", "-A", chdir: BRAIN_BASE_DIR)
    Open3.capture2("git", "commit", "-m", message, chdir: BRAIN_BASE_DIR)

    retries.times do |attempt|
      brain_pull_internal(force: true) if attempt.positive?

      _, push_status = Open3.capture2e("git", "push", chdir: BRAIN_BASE_DIR)
      if push_status.success?
        LOG.info "[Brain] Pushed changes#{" (retry #{attempt})" if attempt.positive?}"
        break
      end

      sleep(2**attempt) if attempt < retries - 1
    end

    LOG.warn "[Brain] Push failed after #{retries} attempts"
  end
rescue StandardError => e
  LOG.warn "[Brain] Push error: #{e.message}"
end

def query_brain(search_terms, agent_name: AI_AGENT_NAME, scope: :knowledge, max_results: 5)
  return "" unless system("which qmd > /dev/null 2>&1")

  collection = case scope
               when :persona then persona_collection_for(agent_name)
               else KNOWLEDGE_COLLECTION
               end

  output, status = Open3.capture2("qmd", "search", search_terms, "-c", collection, "-n", max_results.to_s, "--md")
  return "" unless status.success? && !output.strip.empty?

  output.strip
rescue StandardError => e
  LOG.warn "Brain query failed (#{scope}, #{agent_name}): #{e.message}"
  ""
end

def extract_topics(card_title, comment_body, project_key)
  text = [card_title, comment_body].compact.join(" ")
  # Strip common noise words, extract meaningful terms
  stopwords = %w[the a an is are was were be been being have has had do does did will would shall should
                 may might can could this that these those it its i me my we our you your he she they them
                 to of in for on with at by from as into through during before after above below between
                 and or but not no nor so yet both either neither each every all any few more most other
                 some such only own same than too very just don doesn didn won wasn weren isn aren hasn
                 haven hadn couldn shouldn wouldn about also back even still already again further then
                 once here there when where why how what which who whom whose if because since while
                 please thanks thank need want like make sure get got going go let know think see look
                 work try use find give tell ask seem feel become leave call keep put run move live
                 update fix add create new change set up check out]
  words = text.downcase.gsub(/[^a-z0-9\s_-]/, " ").split.uniq - stopwords
  topics = words.select { |w| w.length > 2 }.first(8)
  topics << project_key if project_key && !project_key.empty?
  topics.compact.uniq
end

def build_brain_context(agent_name: AI_AGENT_NAME, card_title: "", card_number: nil, project_key: nil, comment_body: "", source: nil)
  Thread.new { brain_pull }

  topics = extract_topics(card_title, comment_body, project_key)
  primary_query = topics.first(5).join(" ")
  primary_query = "project conventions" if primary_query.empty?

  fizzy_mentioned = [card_title, comment_body].any? { |s| s&.match?(/fizzy/i) }
  fizzy_originated = source == :fizzy

  search_queries = [primary_query]

  knowledge_threads = [
    Thread.new { query_brain(primary_query, scope: :knowledge, max_results: 3) },
    Thread.new { query_brain(agent_name, scope: :knowledge, max_results: 2) }
  ]
  search_queries << agent_name

  if fizzy_mentioned || fizzy_originated
    knowledge_threads << Thread.new { query_brain("fizzy CLI commands", scope: :knowledge, max_results: 2) }
    search_queries << "fizzy CLI commands"
  end

  persona_thread = Thread.new { query_brain("personality tone voice communication style", agent_name: agent_name, scope: :persona, max_results: 5) }

  all_knowledge = knowledge_threads.map(&:value).reject(&:empty?)
  persona_result = persona_thread.value

  sections = []

  unless persona_result.empty?
    sections << <<~PERSONA
      ## Brain — Persona (auto-retrieved, CRITICAL)
      The following is YOUR personality, communication style, and voice.
      You MUST use this to shape every response you write — tone, word choice, humor, attitude.
      This is who you ARE. Do not respond in a generic or neutral voice.

      #{persona_result}
    PERSONA
  end

  unless all_knowledge.empty?
    knowledge_text = all_knowledge.join("\n\n")
    sections << <<~BRAIN
      ## Brain — Knowledge (auto-retrieved for: #{search_queries.map { |q| %("#{q}") }.join(", ")})
      The following is relevant technical knowledge from your long-term memory.
      These are project conventions, coding patterns, lessons learned, and decisions
      that past-you saved for exactly this kind of work. Use it to inform your implementation.
      If these results don't look relevant to your current task, search manually with better terms.

      #{knowledge_text}
    BRAIN
  end

  # Auto-inject skills: semantically match skills against current task context
  skill_search_context = [card_title, comment_body, primary_query].compact.reject(&:empty?).join(" ")
  skill_section = auto_inject_skills(skill_search_context)
  sections << skill_section unless skill_section.empty?

  sections.join("\n")
end
