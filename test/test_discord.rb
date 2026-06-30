# frozen_string_literal: true

require_relative "test_helper"

class TestDiscordConfig < Minitest::Test
  def test_load_discord_config_parses_file
    config = load_discord_config
    assert_equal "marketplace", config["default_project"]
  end

  def test_discord_bot_tokens_collected
    tokens = discord_bot_tokens
    assert_equal "Bot_galen", tokens["galen"]
    assert_equal "Bot_glados", tokens["glados"]
  end

  def test_discord_bot_tokens_excludes_agents_without_token
    tokens = discord_bot_tokens
    refute tokens.key?("kaylee")
    refute tokens.key?("threepio")
  end

  def test_find_project_for_mapped_channel
    result = find_project_for_discord_channel("channel-brainiac")
    assert result
    project_key, _config, _mapping = result
    assert_equal "brainiac", project_key
  end

  def test_find_project_for_unmapped_uses_default
    result = find_project_for_discord_channel("random-channel-999")
    assert result
    project_key, _config, _mapping = result
    assert_equal "marketplace", project_key
  end

  def test_find_project_nil_without_default
    original = DISCORD_CONFIG.dup
    DISCORD_CONFIG.replace({ "channel_mappings" => {} })
    assert_nil find_project_for_discord_channel("unknown")
  ensure
    DISCORD_CONFIG.replace(original)
  end

  def test_thread_map_persistence
    FileUtils.rm_f(DISCORD_THREAD_MAP_FILE)
    assert_equal({}, load_discord_thread_map)
    map = { "galen:ch1" => { "worktree" => "/tmp/wt" } }
    save_discord_thread_map(map)
    loaded = load_discord_thread_map
    assert_equal "/tmp/wt", loaded["galen:ch1"]["worktree"]
  end
end

class TestDiscordSessionMechanics < Minitest::Test
  def setup
    ACTIVE_SESSIONS.clear
    AGENT_DISPATCH_DEPTH.clear
  end

  def test_supersede_window_constant
    assert_equal 60, SUPERSEDE_WINDOW
  end

  def test_supersedable_session_found
    pid = spawn("sleep", "30")
    register_session("discord-galen-ch1-msg1", pid,
                     supersede_key: "discord-galen-ch1", agent_name: "Galen")
    result = find_supersedable_session("discord-galen-ch1")
    assert result
    assert_equal pid, result[:pid]
  ensure
    begin
      Process.kill("KILL", pid)
    rescue StandardError
      nil
    end
    begin
      Process.wait(pid)
    rescue StandardError
      nil
    end
  end

  def test_supersedable_session_not_found_outside_window
    pid = spawn("sleep", "30")
    register_session("discord-galen-ch1-msg1", pid,
                     supersede_key: "discord-galen-ch1", agent_name: "Galen")
    ACTIVE_SESSIONS["discord-galen-ch1-msg1"][:started_at] = Time.now - 120
    assert_nil find_supersedable_session("discord-galen-ch1")
  ensure
    begin
      Process.kill("KILL", pid)
    rescue StandardError
      nil
    end
    begin
      Process.wait(pid)
    rescue StandardError
      nil
    end
  end

  def test_discord_dispatch_depth_tracking
    record_human_comment("discord-ch-1")
    assert agent_dispatch_allowed?("discord-ch-1")
    record_agent_dispatch("discord-ch-1")
    assert agent_dispatch_allowed?("discord-ch-1")
  end
end
