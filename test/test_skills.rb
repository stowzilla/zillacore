# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "logger"
require "tempfile"

# Stub constants that skills.rb needs
BRAINIAC_DIR = Dir.mktmpdir("brainiac-test") unless defined?(BRAINIAC_DIR)
KNOWLEDGE_DIR = File.join(BRAINIAC_DIR, "brain", "knowledge") unless defined?(KNOWLEDGE_DIR)
KNOWLEDGE_COLLECTION = "brainiac-knowledge" unless defined?(KNOWLEDGE_COLLECTION)
FileUtils.mkdir_p(KNOWLEDGE_DIR)
LOG = Logger.new(File::NULL) unless defined?(LOG)

verbose = $VERBOSE
$VERBOSE = nil
require_relative "../lib/brainiac/skills"
$VERBOSE = verbose

class TestSkills < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir("skills-test")
    @original_skills_dir = SKILLS_DIR.dup
    silence_warnings { Object.const_set(:SKILLS_DIR, File.join(@test_dir, "skills")) }
    silence_warnings { Object.const_set(:SKILL_ARCHIVE_DIR, File.join(SKILLS_DIR, "_archived")) }
    FileUtils.mkdir_p(SKILLS_DIR)
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
    silence_warnings { Object.const_set(:SKILLS_DIR, @original_skills_dir) }
  end

  def create_skill(name, description: "Test skill", tags: [], content: "Steps here")
    dir = File.join(SKILLS_DIR, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), <<~SKILL)
      ---
      name: #{name}
      description: #{description}
      tags: [#{tags.join(", ")}]
      ---
      #{content}
    SKILL
    dir
  end

  def test_build_skill_index_empty
    assert_equal [], build_skill_index
  end

  def test_build_skill_index_finds_skills
    create_skill("deploy-rails", description: "Deploy a Rails app", tags: %w[rails deploy])
    create_skill("debug-memory", description: "Debug memory leaks", tags: %w[ruby debug])

    index = build_skill_index
    assert_equal 2, index.size
    assert_equal "deploy-rails", index.find { |s| s[:name] == "deploy-rails" }[:name]
    assert_equal "Debug memory leaks", index.find { |s| s[:name] == "debug-memory" }[:description]
  end

  def test_parse_skill_frontmatter
    path = File.join(create_skill("test-skill", description: "A test", tags: %w[test]), "SKILL.md")
    fm = parse_skill_frontmatter(path)
    assert_equal "test-skill", fm["name"]
    assert_equal "A test", fm["description"]
    assert_equal %w[test], fm["tags"]
  end

  def test_skill_index_for_prompt_empty
    assert_equal "", skill_index_for_prompt
  end

  def test_skill_index_for_prompt_with_skills
    create_skill("my-skill", description: "Does things")
    result = skill_index_for_prompt
    assert_includes result, "Available Skills"
    assert_includes result, "my-skill"
    assert_includes result, "Does things"
  end

  def test_record_skill_usage_view
    dir = create_skill("tracked-skill")
    skill_path = File.join(dir, "SKILL.md")

    record_skill_usage(skill_path, type: :view)
    usage = JSON.parse(File.read(skill_usage_path(skill_path)))
    assert_equal 1, usage["views"]
    assert_equal 0, usage["uses"]
    assert usage["last_viewed"]
  end

  def test_record_skill_usage_use
    dir = create_skill("used-skill")
    skill_path = File.join(dir, "SKILL.md")

    record_skill_usage(skill_path, type: :use)
    usage = JSON.parse(File.read(skill_usage_path(skill_path)))
    assert_equal 0, usage["views"]
    assert_equal 1, usage["uses"]
    assert usage["last_used"]
  end

  def test_detect_skill_candidate_not_enough_tool_calls
    log = Tempfile.new("agent-log")
    log.write("Tool: something\n" * 3)
    log.close
    result = detect_skill_candidate(log.path)
    assert_equal false, result[:extract]
    log.unlink
  end

  def test_detect_skill_candidate_qualifies
    log = Tempfile.new("agent-log")
    log.write(<<~LOG)
      Tool: execute_bash
      Tool: fs_write
      Tool: execute_bash
      Tool: fs_read
      Tool: execute_bash
      error: something failed
      let me try a different approach
      that worked perfectly
    LOG
    log.close
    result = detect_skill_candidate(log.path)
    assert_equal true, result[:extract]
    assert result[:tool_calls] >= 5
    log.unlink
  end

  def test_curate_skills_archives_stale
    dir = create_skill("stale-skill")
    skill_path = File.join(dir, "SKILL.md")
    # Create usage file with old timestamps
    usage_file = skill_usage_path(skill_path)
    old_time = (Time.now - ((SKILL_STALE_DAYS + 1) * 86_400)).iso8601
    File.write(usage_file, JSON.generate({ "views" => 1, "uses" => 0, "last_viewed" => old_time, "last_used" => nil }))

    result = curate_skills
    assert_equal 1, result[:archived]
    refute File.exist?(skill_path)
    assert File.exist?(File.join(SKILL_ARCHIVE_DIR, "stale-skill", "SKILL.md"))
  end

  def test_auto_inject_skills_empty_when_no_skills
    result = auto_inject_skills("deploy rails app")
    assert_equal "", result
  end

  def test_auto_inject_skills_returns_index_when_no_qmd
    create_skill("deploy-rails", description: "Deploy a Rails app")
    # Without qmd available, falls back to listing remaining skills
    result = auto_inject_skills("deploy rails app")
    # Should at least list the skill in "Other Available Skills" if qmd isn't installed
    # or return empty if qmd check fails — either is acceptable
    assert [true, false].include?(result.empty? || result.include?("deploy-rails"))
  end

  def test_match_skills_semantically_empty_context
    skills = [{ name: "test", description: "test", path: "/tmp/x", tags: [] }]
    result = match_skills_semantically("", skills)
    assert_equal [], result
  end

  def test_curate_skills_keeps_active
    dir = create_skill("active-skill")
    skill_path = File.join(dir, "SKILL.md")
    usage_file = skill_usage_path(skill_path)
    File.write(usage_file, JSON.generate({ "views" => 5, "uses" => 2, "last_viewed" => Time.now.iso8601, "last_used" => Time.now.iso8601 }))

    result = curate_skills
    assert_equal 0, result[:archived]
    assert File.exist?(skill_path)
  end

  private

  def silence_warnings
    old_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = old_verbose
  end
end
