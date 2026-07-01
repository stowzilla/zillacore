# frozen_string_literal: true

require_relative "test_helper"

class TestConfig < Minitest::Test
  def test_ai_agent_name
    assert_equal "Galen", AI_AGENT_NAME
  end

  def test_handler_enabled_fizzy
    assert handler_enabled?("fizzy")
  end

  def test_handler_enabled_github
    assert handler_enabled?("github")
  end

  def test_handler_disabled_zoho
    refute handler_enabled?("zoho")
  end

  def test_github_webhook_secret
    assert_equal "github-test-secret", github_webhook_secret
  end

  def test_projects_loaded
    assert PROJECTS.key?("marketplace")
    assert PROJECTS.key?("brainiac")
    assert_equal "/home/test/Code/marketplace", PROJECTS["marketplace"]["repo_path"]
  end


  def test_file_changed_detects_new_file
    test_file = File.join(TEST_BRAINIAC_DIR, "config-change-test-#{rand(10_000)}.txt")
    File.write(test_file, "v1")
    CONFIG_MTIMES.delete(test_file)
    assert file_changed?(test_file)
  end

  def test_file_changed_false_when_unchanged
    test_file = File.join(TEST_BRAINIAC_DIR, "config-change-test2-#{rand(10_000)}.txt")
    File.write(test_file, "v1")
    CONFIG_MTIMES.delete(test_file)
    file_changed?(test_file)
    refute file_changed?(test_file)
  end

  def test_file_changed_true_with_force
    test_file = File.join(TEST_BRAINIAC_DIR, "config-change-test3-#{rand(10_000)}.txt")
    File.write(test_file, "v1")
    CONFIG_MTIMES.delete(test_file)
    file_changed?(test_file)
    assert file_changed?(test_file, force: true)
  end
end
