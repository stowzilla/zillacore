# frozen_string_literal: true

require_relative "test_helper"

class TestSessions < Minitest::Test
  def setup
    PROCESSED_EVENTS.clear
    ACTIVE_SESSIONS.clear
    RECENT_SESSIONS.clear
    LAST_COMMENT_TIMES.clear
    LAST_DEPLOY_TIMES.clear
    AGENT_DISPATCH_DEPTH.clear
    SELF_MOVES.clear
  end

  # --- Event deduplication ---

  def test_already_processed_returns_false_for_new_event
    refute already_processed?("event-001")
  end

  def test_already_processed_returns_true_for_duplicate
    already_processed?("event-001")
    assert already_processed?("event-001")
  end

  def test_already_processed_returns_false_for_nil
    refute already_processed?(nil)
  end

  def test_already_processed_evicts_old_entries_beyond_max
    (PROCESSED_EVENTS_MAX + 50).times { |i| already_processed?("event-#{i}") }
    assert_operator PROCESSED_EVENTS.size, :<=, PROCESSED_EVENTS_MAX
  end

  # --- Self-move tracking ---

  def test_record_self_move_and_detect
    record_self_move(42)
    assert self_move_recent?(42)
  end

  def test_self_move_not_recent_without_recording
    refute self_move_recent?(99)
  end

  def test_self_move_expires_after_window
    SELF_MOVES["42"] = Time.now - 200
    refute self_move_recent?(42, window: 120)
  end

  # --- Session management ---

  def test_session_active_returns_false_when_no_session
    refute session_active?("card-123")
  end

  def test_register_session_and_check_active
    pid = spawn("sleep", "30")
    register_session("card-123", pid, log_file: "/tmp/test.log", agent_name: "Galen")
    assert session_active?("card-123")
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

  def test_session_active_cleans_up_dead_process
    register_session("card-456", 999_999_999, agent_name: "Galen")
    refute session_active?("card-456")
  end

  def test_archive_session_adds_to_recent
    info = { agent_name: "Galen", log_file: "/tmp/x.log", started_at: Time.now }
    ACTIVE_SESSIONS_MUTEX.synchronize { archive_session("card-1", info) }
    assert_equal 1, RECENT_SESSIONS.size
    assert_equal "Galen", RECENT_SESSIONS.first[:agent_name]
  end

  def test_recently_completed_true_within_window
    info = { agent_name: "Galen", log_file: "/tmp/x.log", started_at: Time.now }
    ACTIVE_SESSIONS_MUTEX.synchronize { archive_session("card-5", info) }
    assert recently_completed?("card-5", window: 120)
  end

  def test_recently_completed_false_outside_window
    info = { agent_name: "Galen", log_file: "/tmp/x.log", started_at: Time.now }
    ACTIVE_SESSIONS_MUTEX.synchronize { archive_session("card-5", info) }
    RECENT_SESSIONS.first[:finished_at] = Time.now - 200
    refute recently_completed?("card-5", window: 120)
  end

  # --- Kill session ---

  def test_kill_session_terminates_process
    pid = spawn("sleep", "30")
    register_session("card-kill-test", pid, agent_name: "Galen")
    assert kill_session("card-kill-test")
    sleep 0.2
    refute session_active?("card-kill-test")
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

  def test_kill_session_returns_false_for_nonexistent
    refute kill_session("card-nonexistent")
  end

  # --- Comment cooldown ---

  def test_comment_cooldown_not_active_initially
    refute on_comment_cooldown?("card-10")
  end

  def test_comment_cooldown_active_after_touch
    touch_comment_cooldown("card-10")
    assert on_comment_cooldown?("card-10")
  end

  def test_comment_cooldown_expires
    LAST_COMMENT_TIMES["card-10"] = Time.now - (COMMENT_COOLDOWN + 1)
    refute on_comment_cooldown?("card-10")
  end

  # --- Deploy cooldown ---

  def test_deploy_cooldown_not_active_initially
    refute on_deploy_cooldown?("dev01")
  end

  def test_deploy_cooldown_active_after_touch
    touch_deploy_cooldown("dev01")
    assert on_deploy_cooldown?("dev01")
  end

  def test_deploy_cooldown_expires
    LAST_DEPLOY_TIMES["dev01"] = Time.now - (DEPLOY_COOLDOWN + 1)
    refute on_deploy_cooldown?("dev01")
  end

  # --- Agent dispatch depth (loop prevention) ---

  def test_agent_dispatch_not_allowed_without_human_comment
    refute agent_dispatch_allowed?("card-abc")
  end

  def test_record_human_comment_enables_dispatch
    record_human_comment("card-abc")
    assert agent_dispatch_allowed?("card-abc")
  end

  def test_agent_dispatch_blocked_at_max_depth
    record_human_comment("card-abc")
    AGENT_DISPATCH_MAX_DEPTH.times { record_agent_dispatch("card-abc") }
    refute agent_dispatch_allowed?("card-abc")
  end

  def test_agent_dispatch_resets_on_new_human_comment
    record_human_comment("card-abc")
    5.times { record_agent_dispatch("card-abc") }
    record_human_comment("card-abc")
    assert_equal 0, AGENT_DISPATCH_DEPTH["card-abc"][:count]
    assert agent_dispatch_allowed?("card-abc")
  end

  def test_agent_dispatch_expires_after_window
    record_human_comment("card-abc")
    AGENT_DISPATCH_DEPTH["card-abc"][:last_human_at] = Time.now - (AGENT_DISPATCH_WINDOW + 1)
    refute agent_dispatch_allowed?("card-abc")
  end

  # --- Session supersede ---

  def test_find_supersedable_session_returns_nil_when_empty
    assert_nil find_supersedable_session("discord-galen-channel1")
  end

  def test_find_supersedable_session_finds_active_within_window
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

  def test_find_supersedable_session_ignores_old_sessions
    pid = spawn("sleep", "30")
    register_session("discord-galen-ch1-msg1", pid,
                     supersede_key: "discord-galen-ch1", agent_name: "Galen")
    ACTIVE_SESSIONS["discord-galen-ch1-msg1"][:started_at] = Time.now - (SUPERSEDE_WINDOW + 10)
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
end
