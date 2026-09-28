# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/brunch"

class BrunchTest < Minitest::Test
  def test_has_a_version
    refute_empty Brunch::VERSION
  end

  def test_cli_reports_its_version
    output, = capture_io { assert_equal 0, Brunch::CLI.start(["version"]) }

    assert_equal "#{Brunch::VERSION}\n", output
  end

  def test_command_manager_runs_lifecycle_commands
    Dir.mktmpdir do |directory|
      snapshot = File.join(directory, "snapshot")
      Dir.mkdir(snapshot)
      manager = Brunch::Managers.build(
        "manager" => "command",
        "commands" => { "start" => "true", "stop" => "true", "remove" => "true" }
      )
      entry = { "ref" => "main", "port" => 3000, "project" => "brunch-main", "snapshot" => snapshot }

      assert manager.start(entry)
      assert manager.stop(entry)
      assert manager.remove(entry)
      refute_path_exists snapshot
    end
  end
end
