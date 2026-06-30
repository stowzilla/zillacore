# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/plugins"

class TestPlugins < Minitest::Test
  def setup
    @plugins_file = File.join(TEST_BRAINIAC_DIR, "plugins.json")
    # Ensure Brainiac::Plugins module exists
    return if defined?(Brainiac::Plugins)

    Object.const_set(:Brainiac, Module.new) unless defined?(Brainiac)
    Brainiac.const_set(:Plugins, Module.new) unless defined?(Brainiac::Plugins)
  end

  def teardown
    FileUtils.rm_f(@plugins_file)
  end

  def test_load_plugins_config_returns_default_when_missing
    FileUtils.rm_f(@plugins_file)
    result = load_plugins_config
    assert_equal({ "plugins" => [] }, result)
  end

  def test_load_plugins_config_reads_file
    File.write(@plugins_file, JSON.generate({ "plugins" => [{ "name" => "whatsapp" }] }))
    result = load_plugins_config
    assert_equal [{ "name" => "whatsapp" }], result["plugins"]
  end

  def test_installed_plugins_from_hash_entries
    config = { "plugins" => [{ "name" => "whatsapp" }, { "name" => "slack" }] }
    swap_constant(:PLUGINS_CONFIG, config) do
      assert_equal %w[whatsapp slack], installed_plugins
    end
  end

  def test_installed_plugins_from_string_entries
    config = { "plugins" => %w[whatsapp slack] }
    swap_constant(:PLUGINS_CONFIG, config) do
      assert_equal %w[whatsapp slack], installed_plugins
    end
  end

  def test_installed_plugins_empty
    config = { "plugins" => [] }
    swap_constant(:PLUGINS_CONFIG, config) do
      assert_equal [], installed_plugins
    end
  end

  def test_resolve_plugin_module_finds_pascal
    mod = Module.new
    Brainiac::Plugins.const_set(:TestWidget, mod)

    assert_equal mod, resolve_plugin_module("test-widget")
  ensure
    Brainiac::Plugins.send(:remove_const, :TestWidget) if Brainiac::Plugins.const_defined?(:TestWidget)
  end

  def test_resolve_plugin_module_case_insensitive
    mod = Module.new
    Brainiac::Plugins.const_set(:WhatsApp, mod)

    assert_equal mod, resolve_plugin_module("whatsapp")
  ensure
    Brainiac::Plugins.send(:remove_const, :WhatsApp) if Brainiac::Plugins.const_defined?(:WhatsApp)
  end

  def test_resolve_plugin_module_returns_nil_for_unknown
    assert_nil resolve_plugin_module("nonexistent-xyz-plugin")
  end

  def test_save_plugins_config_writes_file
    config = { "plugins" => [{ "name" => "test" }] }
    save_plugins_config(config)

    assert File.exist?(@plugins_file)
    parsed = JSON.parse(File.read(@plugins_file))
    assert_equal [{ "name" => "test" }], parsed["plugins"]
  end

  private

  def swap_constant(name, new_value)
    old_verbose = $VERBOSE
    $VERBOSE = nil
    old_value = Object.const_get(name)
    Object.send(:remove_const, name)
    Object.const_set(name, new_value)
    $VERBOSE = old_verbose
    yield
  ensure
    $VERBOSE = nil
    Object.send(:remove_const, name)
    Object.const_set(name, old_value)
    $VERBOSE = old_verbose
  end
end
