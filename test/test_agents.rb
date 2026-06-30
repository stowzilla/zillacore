# frozen_string_literal: true

require_relative "test_helper"

class TestAgents < Minitest::Test
  def test_agent_env_for_returns_env_hash
    env = agent_env_for("Galen")
    assert_equal "fizzy_galen_token", env["FIZZY_TOKEN"]
    assert_equal "Bot_galen", env["DISCORD_BOT_TOKEN"]
  end

  def test_agent_env_for_case_insensitive
    env = agent_env_for("GALEN")
    assert_equal "fizzy_galen_token", env["FIZZY_TOKEN"]
  end

  def test_agent_env_for_unknown_agent
    assert_equal({}, agent_env_for("UnknownBot"))
  end

  def test_agent_env_for_nil
    assert_equal({}, agent_env_for(nil))
  end

  def test_fizzy_token_for_returns_token
    assert_equal "fizzy_galen_token", fizzy_token_for("Galen")
  end

  def test_fizzy_token_for_glados
    assert_equal "fizzy_glados_token", fizzy_token_for("GLaDOS")
  end

  def test_fizzy_display_name_from_registry
    assert_equal "Galen", fizzy_display_name("galen")
    assert_equal "GLaDOS", fizzy_display_name("glados")
    assert_equal "Sleeper Service", fizzy_display_name("sleeper-service")
  end

  def test_fizzy_display_name_falls_back_to_input
    assert_equal "UnknownBot", fizzy_display_name("UnknownBot")
  end

  def test_agent_roster_returns_hash
    roster = agent_roster
    assert_instance_of Hash, roster
    assert_equal "Galen", roster["galen"]
    assert_equal "GLaDOS", roster["glados"]
  end

  def test_local_agent_names_includes_marked_local
    locals = local_agent_names
    assert_includes locals, "Galen"
    assert(locals.any? { |n| n.downcase == "glados" })
  end

  def test_local_agent_names_excludes_non_local
    locals = local_agent_names
    refute locals.include?("Sleeper Service")
  end

  def test_all_agent_names_includes_registered
    names = all_agent_names
    assert names.include?("Galen")
    assert(names.any? { |n| n.downcase == "glados" })
    assert(names.any? { |n| n.downcase == "kaylee" || n == "Kaylee" })
  end

  def test_detect_mentioned_agent_full_name
    assert_equal "Galen", detect_mentioned_agent("@Galen can you review this?")
  end

  def test_detect_mentioned_agent_case_insensitive
    agent = detect_mentioned_agent("@galen look at this")
    assert agent
    assert_equal "galen", agent.downcase
  end

  def test_detect_mentioned_agent_glados
    agent = detect_mentioned_agent("Hey @GLaDOS what do you think?")
    assert agent
    assert_equal "glados", agent.downcase
  end

  def test_detect_mentioned_agent_no_mention
    assert_nil detect_mentioned_agent("No one mentioned here")
  end

  def test_comment_from_agent_true
    assert comment_from_agent?("Galen")
  end

  def test_comment_from_agent_false_for_human
    refute comment_from_agent?("Andy")
    refute comment_from_agent?("SomeRandom")
  end

  def test_comment_from_agent_false_for_nil
    refute comment_from_agent?(nil)
  end

  def test_load_role_returns_nil_for_missing_file
    assert_nil load_role("nonexistent-role")
  end

  def test_load_role_reads_markdown_file
    File.write(File.join(ROLES_DIR, "test-engineer.md"), "# Test Engineer\nYou write tests.")
    content = load_role("test-engineer")
    assert_includes content, "Test Engineer"
  end

  def test_load_role_strips_yaml_frontmatter
    File.write(File.join(ROLES_DIR, "reviewer.md"), "---\nname: reviewer\n---\n# Reviewer\nReview code.")
    content = load_role("reviewer")
    refute_includes content, "---"
    assert_includes content, "# Reviewer"
  end
end
