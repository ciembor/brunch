# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "socket"
require_relative "../lib/brunch"

class ManagersContractTest < Minitest::Test
  def with_entry
    Dir.mktmpdir("brunch-manager-test") do |directory|
      snapshot = File.join(directory, "snapshot")
      control = File.join(directory, "control")
      FileUtils.mkdir_p([snapshot, control])
      entry = { "ref" => "topic", "port" => 31_234, "project" => "brunch-topic",
                "snapshot" => snapshot, "control" => control, "compose_file" => "compose.yaml" }
      yield entry
    end
  end

  def test_base_environment_port_probe_and_safe_cleanup
    with_entry do |entry|
      manager = Brunch::Managers::Base.new({})
      assert_equal({ "BRUNCH_REF" => "topic", "BRUNCH_PORT" => "31234", "BRUNCH_PROJECT" => "brunch-topic",
                     "BRUNCH_SNAPSHOT" => entry.fetch("snapshot") }, manager.environment(entry))
      assert manager.create(entry)
      manager.define_singleton_method(:start) { |_entry| :started }
      assert_equal :started, manager.resume(entry)
      assert_equal "unknown", manager.status(entry)
      refute manager.healthy?(entry)
      _out, err = capture_io { refute manager.logs(entry) }
      assert_includes err, "not supported"

      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      refute manager.port_available?(port)
      server.close
      assert manager.port_available?(port)

      assert manager.remove(entry.merge("source_type" => "worktree"))
      refute_path_exists entry.fetch("control")
      assert_path_exists entry.fetch("snapshot")
      manager.reset(entry)
      refute_path_exists entry.fetch("snapshot")
    ensure
      server&.close unless server&.closed?
    end
  end

  def test_compose_commands_and_health_cover_both_engines
    with_entry do |entry|
      File.write(File.join(entry.fetch("snapshot"), "compose.yaml"), "services: {}\n")
      [Brunch::Managers::DockerCompose, Brunch::Managers::PodmanCompose].each do |klass|
        manager = klass.new({})
        calls = []
        manager.define_singleton_method(:system) do |*args, **kwargs|
          calls << [args, kwargs]
          true
        end
        assert manager.available?
        assert manager.start(entry)
        assert manager.resume(entry)
        assert_equal "start", calls.last.first.last
        assert manager.logs(entry)
        assert manager.logs(entry, "--follow", "web")
        assert manager.stop(entry)
        command = manager.send(:compose_command, entry, "ps")
        assert_includes command, entry.fetch("project")
        assert_includes command, File.join(entry.fetch("snapshot"), "compose.yaml")
        assert(calls.any? { |args, _| args.include?("--tail") })
        assert(calls.any? { |args, _| args.include?("--follow") })

        success = Struct.new(:success?).new(true)
        Open3.stub(:capture2, ["container-id\n", success]) do
          assert manager.healthy?(entry)
          assert_equal "running", manager.status(entry)
        end
        Open3.stub(:capture2, ["", success]) do
          refute manager.healthy?(entry)
          assert_equal "stopped", manager.status(entry)
        end
        manager.define_singleton_method(:available?) { false }
        assert_equal "unavailable", manager.status(entry)
        refute manager.healthy?(entry)
        refute manager.remove(entry)
      end
    end
  end

  def test_compose_port_probe_fallback_and_resource_removal
    with_entry do |entry|
      manager = Brunch::Managers::DockerCompose.new({})
      manager.define_singleton_method(:available?) { true }
      manager.define_singleton_method(:compose) { |*_arguments| true }
      occupied = TCPServer.new("127.0.0.1", 0)
      port = occupied.addr[1]
      Open3.stub(:capture2, ["127.0.0.1:#{port}->3000/tcp", nil]) do
        refute manager.port_available?(port)
      end
      Open3.stub(:capture2, ["", nil]) { refute manager.port_available?(port) }
      occupied.close
      Open3.stub(:capture2, ["", nil]) { assert manager.port_available?(port) }
      assert manager.remove(entry.merge("source_type" => "worktree"))
      refute_path_exists entry.fetch("control")
    ensure
      occupied&.close unless occupied&.closed?
    end
  end

  def test_podman_health_checks_running_containers_by_project_label
    with_entry do |entry|
      manager = Brunch::Managers::PodmanCompose.new({})
      manager.define_singleton_method(:available?) { true }
      success = Struct.new(:success?).new(true)
      expected = ["podman", "ps", "--filter", "label=com.docker.compose.project=brunch-topic", "--quiet"]
      Open3.stub(:capture2, lambda { |*command|
        assert_equal expected, command
        ["container-id\n", success]
      }) do
        assert manager.healthy?(entry)
      end
    end
  end

  def test_compose_reset_removes_snapshot_and_factory_builds_each_engine
    with_entry do |entry|
      assert_instance_of Brunch::Managers::DockerCompose, Brunch::Managers.build("manager" => "docker_compose")
      assert_instance_of Brunch::Managers::PodmanCompose, Brunch::Managers.build("manager" => "podman_compose")
      manager = Brunch::Managers::DockerCompose.new({})
      calls = []
      manager.define_singleton_method(:available?) { true }
      manager.define_singleton_method(:compose) do |*arguments|
        calls << arguments
        true
      end
      manager.reset(entry)
      assert_equal [entry, "down", "--remove-orphans"], calls.last
      refute_path_exists entry.fetch("snapshot")
    end
  end

  def test_manager_cleanup_without_control_and_unavailable_compose_paths
    with_entry do |entry|
      base = Brunch::Managers::Base.new({})
      base.remove_managed_files(entry.merge("source_type" => "worktree", "control" => nil))
      assert_path_exists entry.fetch("snapshot")

      docker = Brunch::Managers::DockerCompose.new({})
      docker.define_singleton_method(:available?) { false }
      assert_nil docker.stop(entry)
      docker.reset(entry)
      refute_path_exists entry.fetch("snapshot")
      assert_equal entry.fetch("control"), docker.send(:compose_directory, entry)
    end
  end

  def test_local_process_worktree_writes_log_in_control_directory
    with_entry do |entry|
      manager = Brunch::Managers::LocalProcess.new("command" => "printf done")
      worktree_entry = entry.merge("source_type" => "worktree")
      assert manager.start(worktree_entry)
      assert_equal File.join(entry.fetch("control"), ".brunch.log"), worktree_entry.fetch("log_path")
      50.times do
        break if File.exist?(worktree_entry.fetch("log_path"))

        sleep 0.01
      end
      assert_path_exists worktree_entry.fetch("log_path")
    ensure
      manager&.stop(worktree_entry) if worktree_entry
    end
  end

  def test_command_manager_missing_action_and_unknown_status
    with_entry do |entry|
      manager = Brunch::Managers::Command.new("commands" => {})
      assert_equal "unknown", manager.status(entry)
      _out, error = capture_io { assert_raises(SystemExit) { manager.start(entry) } }
      assert_includes error, "Missing commands.start"
    end
  end

  def test_local_process_logs_and_stale_pid
    with_entry do |entry|
      manager = Brunch::Managers::LocalProcess.new("command" => "true")
      _out, err = capture_io { refute manager.logs(entry) }
      assert_includes err, "not supported"
      path = File.join(entry.fetch("snapshot"), "run.log")
      File.write(path, (1..105).map { |number| "#{number}\n" }.join)
      out, = capture_io { assert manager.logs(entry.merge("log_path" => path)) }
      refute_includes out.lines, "1\n"
      assert_includes out, "105\n"
      _out, err = capture_io { refute manager.logs(entry.merge("log_path" => path), "--follow") }
      assert_includes err, "not supported"
      assert manager.stop(entry)
      assert manager.stop(entry.merge("pid" => 999_999_999))
      refute manager.healthy?(entry.merge("pid" => 999_999_999))
      assert_equal "stopped", manager.status(entry.merge("pid" => 999_999_999))
    end
  end

  def test_command_manager_status_health_logs_and_missing_command
    with_entry do |entry|
      manager = Brunch::Managers::Command.new("commands" => {
                                                "start" => "true", "stop" => "true", "remove" => "true", "status" => "true",
                                                "health" => "true", "logs" => "test \"$1\" = --follow"
                                              })
      assert manager.create(entry)
      assert_equal "running", manager.status(entry)
      assert manager.healthy?(entry)
      assert manager.logs(entry, "--follow")
      manager = Brunch::Managers::Command.new("commands" => {
                                                "start" => "false", "stop" => "true", "remove" => "false", "status" => "false"
                                              })
      refute manager.start(entry)
      assert_equal "stopped", manager.status(entry)
      refute manager.healthy?(entry)
      _out, err = capture_io { refute manager.logs(entry) }
      assert_includes err, "not supported"
      refute manager.remove(entry)
      assert_path_exists entry.fetch("snapshot")
      assert_raises(SystemExit) { Brunch::Managers.build("manager" => "missing") }
    end
  end
end
