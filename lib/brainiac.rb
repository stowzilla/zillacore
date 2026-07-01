require_relative "brainiac/hooks"
require_relative "brainiac/config"
require_relative "brainiac/users"
require_relative "brainiac/agents"
require_relative "brainiac/brain"
require_relative "brainiac/skills"
require_relative "brainiac/sessions"
require_relative "brainiac/prompts"
require_relative "brainiac/helpers"
require_relative "brainiac/cron"
require_relative "brainiac/plugins"

# Namespace for gem-based plugins (brainiac-whatsapp, brainiac-slack, etc.)
module Brainiac
  module Plugins
  end
end
