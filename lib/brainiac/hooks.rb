# frozen_string_literal: true

# Brainiac hook system.
#
# Provides a lightweight pub/sub mechanism for plugins to extend core behavior
# without core knowing about specific plugins.
#
# Core emits events at lifecycle points. Plugins register handlers via Brainiac.on.
#
# Events:
#   :agent_completed    — After an agent session finishes (success or failure)
#   :pr_merged          — After a GitHub PR is merged
#   :pr_opened          — After a GitHub PR is opened
#   :pr_reviewed        — After a PR review is submitted
#   :build_brain_context — When building brain context (plugins add source-specific queries)
#   :pre_dispatch       — Before dispatching an agent (plugins can inject config)
#   :post_comment       — After an agent posts a comment/response
#
# Usage (in plugin .register):
#   Brainiac.on(:agent_completed) do |ctx|
#     move_card_to_column(ctx[:card_number], "needs_review", ...)
#   end
#
# Usage (in core):
#   Brainiac.emit(:agent_completed, card_number: 42, agent_name: "Galen", ...)

module Brainiac
  @hooks = Hash.new { |h, k| h[k] = [] }
  @channel_prompts = {}
  @channel_pre_post_checks = {}

  class << self
    # Register a hook for an event.
    #
    # @param event [Symbol] Event name
    # @param block [Proc] Handler block, receives a context hash
    def on(event, &block)
      @hooks[event] << block
    end

    # Emit an event, calling all registered handlers.
    # Returns an array of results from each handler (nil results filtered out).
    #
    # @param event [Symbol] Event name
    # @param context [Hash] Context passed to each handler
    # @return [Array] Results from handlers
    def emit(event, **context)
      results = @hooks[event].map do |handler|
        handler.call(context)
      rescue StandardError => e
        LOG.error "[Hooks] Error in #{event} handler: #{e.message}" if defined?(LOG)
        LOG.error "[Hooks]   #{e.backtrace.first(3).join("\n  ")}" if defined?(LOG)
        nil
      end
      results.compact
    end

    # Register a channel prompt template for use in render_prompt.
    # Plugins call this to add their channel-specific prompt block.
    #
    # @param channel [Symbol] Channel name (e.g., :fizzy, :discord)
    # @param prompt [String] Channel prompt text
    # @param pre_post_check [String, nil] Optional pre-post comment check instructions
    def register_channel_prompt(channel, prompt, pre_post_check: nil)
      @channel_prompts[channel] = prompt
      @channel_pre_post_checks[channel] = pre_post_check if pre_post_check
    end

    # Get registered channel prompts (used by render_prompt).
    #
    # @return [Hash<Symbol, String>]
    def channel_prompts
      @channel_prompts
    end

    # Get registered pre-post checks (used by render_prompt).
    #
    # @return [Hash<Symbol, String>]
    def channel_pre_post_checks
      @channel_pre_post_checks
    end

    # Clear all hooks (useful for testing).
    def reset_hooks!
      @hooks = Hash.new { |h, k| h[k] = [] }
      @channel_prompts = {}
      @channel_pre_post_checks = {}
    end
  end
end
