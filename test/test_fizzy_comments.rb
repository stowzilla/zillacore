# frozen_string_literal: true

require_relative "test_helper"

class TestFizzyCommentRouting < Minitest::Test
  def setup
    PROCESSED_EVENTS.clear
    ACTIVE_SESSIONS.clear
    LAST_COMMENT_TIMES.clear
    AGENT_DISPATCH_DEPTH.clear
    save_card_map({
                    "card-internal-1" => {
                      "number" => 42, "branch" => "fizzy-42-test-feature",
                      "worktree" => "/tmp/test-marketplace--fizzy-42-test-feature",
                      "project" => "marketplace", "agent" => "Galen"
                    }
                  })
  end

  def test_deploy_comment_routes_correctly
    payload = build_comment_payload(body: "dev01")
    status, = handle_comment(payload)
    assert_equal 200, status
    # Deploy handler would normally run but isn't loaded in test
  end

  def test_human_mentioned_skips_dispatch
    payload = build_comment_payload(body: "@Andy what do you think?", creator_id: "user-2", creator_name: "Adam")
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "human mentioned"
  end

  def test_non_local_agent_mention_ignored
    payload = build_comment_payload(body: "@Kaylee can you help?")
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "non-local agent mentioned"
  end

  def test_unauthorized_user_rejected
    payload = build_comment_payload(body: "@Galen do it", creator_id: "hacker-unknown", creator_name: "Hacker")
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "unauthorized"
  end

  def test_agent_self_comment_ignored
    payload = build_comment_payload(body: "Done with implementation", creator_id: "agent-1", creator_name: "Galen")
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "self-comment"
  end

  def test_agent_to_agent_blocked_at_max_depth
    AGENT_DISPATCH_DEPTH["card-internal-1"] = { count: AGENT_DISPATCH_MAX_DEPTH, last_human_at: Time.now }
    payload = build_comment_payload(body: "@GLaDOS review", creator_id: "agent-1", creator_name: "Galen")
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "agent-to-agent depth limit"
  end

  def test_untracked_card_no_mention_ignored
    payload = build_comment_payload(body: "hello", card_internal_id: "unknown-xyz")
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "not relevant"
  end

  def test_comment_cooldown_blocks
    record_human_comment("card-internal-1")
    touch_comment_cooldown("card-42-galen")
    payload = build_comment_payload(body: "@Galen more")
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "comment cooldown"
  end

  private

  def build_comment_payload(body:, creator_id: "user-1", creator_name: "Andy",
                            card_internal_id: "card-internal-1", card_number: 42)
    {
      "event" => "comment_created",
      "creator" => { "id" => creator_id, "name" => creator_name },
      "eventable" => {
        "id" => "comment-#{rand(10_000)}",
        "body" => { "plain_text" => body, "html" => "<p>#{body}</p>" },
        "creator" => { "id" => creator_id, "name" => creator_name },
        "card" => { "id" => card_internal_id, "number" => card_number,
                    "title" => "Test Feature", "tags" => [{ "name" => "marketplace" }] }
      }
    }
  end
end
