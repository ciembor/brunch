# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/brunch"

class BrunchTest < Minitest::Test
  FakeManager = Struct.new(:events) do
    def available? = true
    def port_available?(_port) = true
    def create(entry) = events << [:create, entry.fetch("ref")]
    def start(entry) = events << [:start, entry.fetch("ref")]
    def stop(entry) = events << [:stop, entry.fetch("ref")]
    def reset(entry)
      events << [:reset, entry.fetch("ref")]
      FileUtils.rm_rf(entry.fetch("snapshot"))
    end
    def remove(entry) = events << [:remove, entry.fetch("ref")]
    def status(_entry) = "running"
    def healthy?(_entry) = true
    def logs(_entry) = true
  end

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

  def test_active_only_stops_every_non_current_environment
    Dir.mktmpdir do |directory|
      original_directory = Dir.pwd
      Dir.chdir(directory)
      system("git", "init", "--quiet")
      system("git", "config", "user.email", "test@example.com")
      system("git", "config", "user.name", "Test")
      File.write("README.md", "test\n")
      system("git", "add", "README.md")
      system("git", "commit", "--quiet", "-m", "initial")
      initial_ref = `git branch --show-current`.strip
      system("git", "branch", "other")
      system("git", "switch", "--quiet", "-c", "feature")

      events = []
      manager = FakeManager.new(events)
      cli = Brunch::CLI.new
      cli.define_singleton_method(:configuration) { { "manager" => "command", "lifecycle" => "active_only", "compose_file" => "compose.yaml" } }
      cli.define_singleton_method(:manager) { manager }
      cli.define_singleton_method(:choose_port) { |_ref, _saved_port| 45_000 }
      cli.send(:save_state, {
        "active_ref" => initial_ref,
        "environments" => {
          initial_ref => { "ref" => initial_ref, "project" => "brunch-#{initial_ref}", "port" => 45_001, "snapshot" => File.join(directory, initial_ref) },
          "other" => { "ref" => "other", "project" => "brunch-other", "port" => 45_002, "snapshot" => File.join(directory, "other") }
        }
      })

      cli.send(:activate)

      assert_includes events, [:stop, initial_ref]
      assert_includes events, [:stop, "other"]
      assert_includes events, [:create, "feature"]
      assert_includes events, [:start, "feature"]
    ensure
      Dir.chdir(original_directory)
    end
  end
end
