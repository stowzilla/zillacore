# frozen_string_literal: true

# Auto-skills: procedural skill extraction, progressive loading, usage tracking, and curation.
#
# Skills are SKILL.md files with YAML frontmatter stored in brain/knowledge/skills/.
# They are auto-extracted after complex sessions and curated over time.

require "yaml"
require "json"
require "time"

SKILLS_DIR = File.join(KNOWLEDGE_DIR, "skills")
FileUtils.mkdir_p(SKILLS_DIR)

# --- SKILL.md format ---
# ---
# name: skill-name-slug
# description: When to use this skill (one line)
# tags: [ruby, testing, deployment]
# ---
# Procedural content...

# --- Skill detection ---

# Analyze an agent session log to determine if a skill should be extracted.
# Triggers when: 5+ tool calls AND at least one error-recovery pattern detected.
# Returns: { extract: true, topic: '...', summary: '...' } or { extract: false }
def detect_skill_candidate(log_file)
  return { extract: false } unless File.exist?(log_file)

  content = File.read(log_file, encoding: "utf-8", invalid: :replace)

  # Count tool invocations (kiro-cli logs tool calls as "Tool:" or "antml:invoke")
  tool_calls = content.scan(/(?:^Tool:|<invoke|execute_bash|fs_write|fs_read|code.*operation)/).size
  return { extract: false } if tool_calls < 5

  # Detect error-recovery patterns: retry, fix, error followed by success
  error_patterns = content.scan(/(?:error|failed|fix|retry|correcting|let me try)/i).size
  recovery_patterns = content.scan(/(?:that worked|fixed|resolved|now passing|success)/i).size
  has_recovery = error_patterns >= 1 && recovery_patterns >= 1

  return { extract: false } unless has_recovery

  { extract: true, tool_calls: tool_calls, error_patterns: error_patterns }
end

# --- Skill index (lightweight manifest for prompt injection) ---

# Build a compact skill index for prompt injection.
# Returns array of { name:, description:, path: } from all SKILL.md files.
def build_skill_index
  skills = []
  Dir.glob(File.join(SKILLS_DIR, "**", "SKILL.md")).each do |path|
    frontmatter = parse_skill_frontmatter(path)
    next unless frontmatter

    skills << {
      name: frontmatter["name"],
      description: frontmatter["description"],
      tags: frontmatter["tags"] || [],
      path: path
    }
  end
  skills
end

# Parse YAML frontmatter from a SKILL.md file.
def parse_skill_frontmatter(path)
  content = File.read(path)
  return nil unless content.start_with?("---")

  parts = content.split("---", 3)
  return nil if parts.size < 3

  YAML.safe_load(parts[1])
rescue StandardError => e
  LOG.warn "[Skills] Failed to parse frontmatter in #{path}: #{e.message}"
  nil
end

# --- Progressive skill loading ---

# Maximum tokens (approx chars / 4) to spend on auto-injected skill content.
SKILL_AUTO_INJECT_MAX_CHARS = 8000

# Build the skill index section for prompt injection.
# Only includes name + description (not full content) to keep tokens bounded.
def skill_index_for_prompt
  skills = build_skill_index
  return "" if skills.empty?

  lines = skills.map { |s| "- **#{s[:name]}**: #{s[:description]}" }
  <<~SECTION
    ## Available Skills
    The following procedural skills are available. To use one, read the full file at its path.
    #{lines.join("\n")}
  SECTION
end

# Semantically match skills against the current task context and auto-inject their full content.
# This is the skill:// equivalent — skills are loaded automatically when relevant, not manually.
# Returns a prompt section with full skill content for top matches, plus an index of remaining skills.
def auto_inject_skills(search_context)
  skills = build_skill_index
  return "" if skills.empty?
  return "" unless system("which qmd > /dev/null 2>&1")

  # Semantic search against skill descriptions to find relevant ones
  matched_paths = match_skills_semantically(search_context, skills)

  # Split into auto-injected (matched) and index-only (rest)
  injected = []
  chars_used = 0

  matched_paths.each do |path|
    content = File.read(path)
    break if chars_used + content.size > SKILL_AUTO_INJECT_MAX_CHARS

    skill = skills.find { |s| s[:path] == path }
    next unless skill

    injected << { name: skill[:name], description: skill[:description], content: content, path: path }
    chars_used += content.size
  end

  remaining = skills.reject { |s| injected.any? { |i| i[:path] == s[:path] } }

  sections = []

  unless injected.empty?
    sections << "## Auto-Loaded Skills (matched to your current task)"
    sections << "These skills were automatically loaded because they're relevant to what you're working on.\n"
    injected.each do |skill|
      sections << "### Skill: #{skill[:name]}"
      sections << skill[:content]
      sections << ""
      record_skill_usage(skill[:path], type: :use)
    end
  end

  unless remaining.empty?
    sections << "## Other Available Skills"
    sections << "Additional skills not auto-loaded. Read the file if needed.\n"
    remaining.each { |s| sections << "- **#{s[:name]}**: #{s[:description]} (`#{s[:path]}`)" }
    sections << ""
  end

  sections.join("\n")
end

# Use qmd semantic search to find skills whose descriptions match the current context.
# Returns an ordered array of SKILL.md paths (most relevant first).
def match_skills_semantically(search_context, skills)
  return [] if search_context.strip.empty?

  # Search the knowledge collection — skills are indexed there since they're in knowledge/skills/
  output, status = Open3.capture2("qmd", "search", search_context, "-c", KNOWLEDGE_COLLECTION, "-n", "10", "--md")
  return [] unless status.success? && !output.strip.empty?

  # Extract paths from qmd results that point to SKILL.md files
  skill_paths = skills.map { |s| s[:path] }
  matched = []

  # qmd --md output includes file paths in results — match against known skill paths
  skill_paths.each do |path|
    # Check if the skill's directory name or file appears in search results
    skill_dir_name = File.basename(File.dirname(path))
    matched << path if output.include?(skill_dir_name) || output.include?(path)
  end

  matched
rescue StandardError => e
  LOG.warn "[Skills] Semantic matching failed: #{e.message}"
  []
end

# --- Usage tracking ---

SKILL_USAGE_SUFFIX = ".usage.json"

def skill_usage_path(skill_path)
  skill_path.sub(/SKILL\.md$/, "SKILL.usage.json")
end

# Record a view (skill index shown in prompt) or use (agent read the full skill).
def record_skill_usage(skill_path, type: :view)
  usage_file = skill_usage_path(skill_path)
  data = if File.exist?(usage_file)
           JSON.parse(File.read(usage_file))
         else
           { "views" => 0, "uses" => 0, "last_viewed" => nil, "last_used" => nil, "created_at" => Time.now.iso8601 }
         end

  now = Time.now.iso8601
  case type
  when :view
    data["views"] = (data["views"] || 0) + 1
    data["last_viewed"] = now
  when :use
    data["uses"] = (data["uses"] || 0) + 1
    data["last_used"] = now
  end

  File.write(usage_file, JSON.pretty_generate(data))
rescue StandardError => e
  LOG.warn "[Skills] Failed to record usage for #{skill_path}: #{e.message}"
end

# Batch-record views for all skills in the index (called when prompt is built).
def record_skill_index_views
  build_skill_index.each { |s| record_skill_usage(s[:path], type: :view) }
end

# --- Curator ---

SKILL_STALE_DAYS = 90 # Archive skills unused for this many days
SKILL_ARCHIVE_DIR = File.join(SKILLS_DIR, "_archived")

# Run the curator: archive stale skills, log consolidation candidates.
# Never auto-deletes — only moves to _archived/.
def curate_skills
  FileUtils.mkdir_p(SKILL_ARCHIVE_DIR)
  now = Time.now
  archived = 0
  consolidation_candidates = []

  skills = build_skill_index
  skills_by_tag = Hash.new { |h, k| h[k] = [] }

  skills.each do |skill|
    usage_file = skill_usage_path(skill[:path])
    usage = if File.exist?(usage_file)
              JSON.parse(File.read(usage_file))
            else
              { "views" => 0, "uses" => 0, "last_viewed" => nil, "last_used" => nil }
            end

    # Check staleness
    last_activity = [usage["last_viewed"], usage["last_used"]].compact.max
    if last_activity.nil? || (now - Time.parse(last_activity)) > (SKILL_STALE_DAYS * 86_400)
      archive_skill(skill[:path])
      archived += 1
      next
    end

    # Track tags for consolidation detection
    (skill[:tags] || []).each { |tag| skills_by_tag[tag] << skill }
  end

  # Detect consolidation candidates: 3+ skills sharing the same tag
  skills_by_tag.each do |tag, tag_skills|
    consolidation_candidates << { tag: tag, skills: tag_skills.map { |s| s[:name] } } if tag_skills.size >= 3
  end

  LOG.info "[Curator] Archived #{archived} stale skill(s)" if archived.positive?
  LOG.info "[Curator] Consolidation candidates: #{consolidation_candidates.map { |c| c[:tag] }.join(", ")}" unless consolidation_candidates.empty?

  { archived: archived, consolidation_candidates: consolidation_candidates }
rescue StandardError => e
  LOG.warn "[Curator] Error during curation: #{e.message}"
  { archived: 0, consolidation_candidates: [], error: e.message }
end

def archive_skill(skill_path)
  skill_dir = File.dirname(skill_path)
  skill_name = File.basename(skill_dir)
  archive_dest = File.join(SKILL_ARCHIVE_DIR, skill_name)

  FileUtils.mkdir_p(archive_dest)
  FileUtils.mv(Dir.glob(File.join(skill_dir, "*")), archive_dest)
  FileUtils.rmdir(skill_dir) if Dir.empty?(skill_dir)

  LOG.info "[Curator] Archived skill: #{skill_name}"
rescue StandardError => e
  LOG.warn "[Curator] Failed to archive #{skill_path}: #{e.message}"
end
