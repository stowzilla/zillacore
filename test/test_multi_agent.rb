# frozen_string_literal: true

require_relative "test_helper"

class TestMultiAgentInteraction < Minitest::Test
  def setup
    PROCESSED_EVENTS.clear
    ACTIVE_SESSIONS.clear
    RECENT_SESSIONS.clear
    LAST_COMMENT_TIMES.clear
    AGENT_DISPATCH_DEPTH.clear
  end

  def test_detect_galen_mentioned
    assert_equal "Galen", detect_mentioned_agent("@Galen can you review this?")
  end

  def test_detect_glados_mentioned
    agent = detect_mentioned_agent("Hey @GLaDOS what do you think?")
    assert agent
    assert_equal "glados", agent.downcase
  end

  def test_no_mention_detected
    assert_nil detect_mentioned_agent("This is just a normal comment")
  end

  def test_full_loop_prevention
    card_id = "card-loop-test"
    record_human_comment(card_id)
    AGENT_DISPATCH_MAX_DEPTH.times { record_agent_dispatch(card_id) }
    refute agent_dispatch_allowed?(card_id)
  end

  def test_human_resets_depth
    card_id = "card-reset"
    record_human_comment(card_id)
    5.times { record_agent_dispatch(card_id) }
    record_human_comment(card_id)
    assert_equal 0, AGENT_DISPATCH_DEPTH[card_id][:count]
    assert agent_dispatch_allowed?(card_id)
  end

  def test_concurrent_sessions_different_cards
    pid1 = spawn("sleep", "30")
    pid2 = spawn("sleep", "30")
    register_session("card-100", pid1, agent_name: "Galen")
    register_session("card-200", pid2, agent_name: "GLaDOS")
    assert session_active?("card-100")
    assert session_active?("card-200")
  ensure
    [pid1, pid2].each do |p|
      begin
        Process.kill("KILL", p)
      rescue StandardError
        nil
      end
      begin
        Process.wait(p)
      rescue StandardError
        nil
      end
    end
  end

  def test_comment_from_agent_vs_human
    assert comment_from_agent?("Galen")
    refute comment_from_agent?("Andy")
    refute comment_from_agent?("RandomPerson")
  end

  def test_kill_archives_session
    pid = spawn("sleep", "30")
    register_session("card-archive", pid, agent_name: "GLaDOS")
    kill_session("card-archive")
    sleep 0.1
    assert_equal "GLaDOS", RECENT_SESSIONS.first[:agent_name]
  ensure
    begin
      begin
        Process.kill("KILL", pid)
      rescue StandardError
        nil
      end
    rescue StandardError
      nil
    end
    begin
      Process.wait(pid)
    rescue StandardError
      nil
    end
  end

  def test_fizzy_display_name_preserves_casing
    assert_equal "GLaDOS", fizzy_display_name("glados")
    assert_equal "Galen", fizzy_display_name("galen")
    assert_equal "Kaylee", fizzy_display_name("kaylee")
  end
end
