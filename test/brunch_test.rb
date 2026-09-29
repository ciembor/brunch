# frozen_string_literal: true

require_relative "test_helper"
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
        "commands" => { "create" => "true", "start" => "true", "stop" => "true", "remove" => "true" }
      )
      entry = { "ref" => "main", "port" => 3000, "project" => "brunch-main", "snapshot" => snapshot }
      assert manager.create(entry)
      assert manager.start(entry)
      assert manager.stop(entry)
      assert manager.remove(entry)
      refute_path_exists snapshot
    end
  end

  def test_local_process_manager_tracks_and_stops_its_process_group
    Dir.mktmpdir do |snapshot|
      manager = Brunch::Managers.build("manager" => "local_process", "command" => "sleep 10")
      entry = { "ref" => "main", "port" => 3000, "project" => "brunch-main", "snapshot" => snapshot }
      assert manager.start(entry)
      assert_equal "running", manager.status(entry)
      assert manager.stop(entry)
      20.times do
        break unless manager.healthy?(entry)

        sleep 0.01
      end
      refute manager.healthy?(entry)
    ensure
      manager&.stop(entry) if entry
    end
  end
end
