# frozen_string_literal: true

# ZillaCore Test Helper
# Requires: gem install minitest rantly

require "minitest/autorun"
require "rantly"
require "rantly/minitest_extensions"
require "json"

# Add project root to load path so monitor scripts can be required
$LOAD_PATH.unshift File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
