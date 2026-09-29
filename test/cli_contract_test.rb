# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require_relative "../lib/brunch"

class CliContractTest < Minitest::Test
  def with_cli
    Dir.mktmpdir("brunch-cli-test") do |directory|
      root = File.realpath(directory)
      state_root = File.join(root, ".git", "brunch")
      FileUtils.mkdir_p(state_root)
      cli = Brunch::CLI.new
      cli.define_singleton_method(:repo_root) { root }
      cli.define_singleton_method(:state_root) { state_root }
      previous = Dir.pwd
      Dir.chdir(root)
      yield cli, root
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_dispatch_install_version_and_operational_errors
    with_cli do |cli, root|
      calls = []
      result = 7
      cli.define_singleton_method(:worktree_command) do |arguments|
        calls << arguments
        raise result if result.is_a?(Exception)

        result
      end
      assert_equal 7, cli.start(["status"])
      assert_equal [["status"]], calls
      %w[version --version -v].each do |option|
        output, = capture_io { assert_equal 0, cli.start([option]) }
        assert_equal "#{Brunch::VERSION}\n", output
      end
      Brunch::Hooks.stub(:install, -> { calls << ["install"] }) { assert_equal 0, cli.start(["install"]) }
      assert_includes calls, ["install"]

      result = Brunch::CLI::OperationError.new("failed")
      _output, error = capture_io { assert_equal 1, cli.start(["status"]) }
      assert_includes error, "failed"
      result = Brunch::CLI::ConfigurationError.new("invalid")
      _output, error = capture_io { assert_equal 64, cli.start(["status"]) }
      assert_includes error, "invalid"

      subdirectory = File.join(root, "nested")
      Dir.mkdir(subdirectory)
      Dir.chdir(subdirectory)
      assert_equal 0, cli.start(["version"])
      assert_equal root, Dir.pwd
    end
  end

  def test_state_is_atomic_and_legacy_state_is_rejected_without_overwrite
    with_cli do |cli, root|
      assert_equal({ "worktrees" => {} }, cli.send(:state))
      path = File.join(root, ".git", "brunch", "state.json")
      data = { "worktrees" => { "id" => { "port" => 3000 } } }
      cli.send(:save_state, data)
      assert_equal data, cli.send(:state)
      assert_empty Dir.glob("#{path}.*.tmp")
      ["{broken", "[]", '{"environments":{"old":{}}}', '{"active_ref":"main"}'].each do |contents|
        File.write(path, contents)
        assert_raises(Brunch::CLI::ConfigurationError) { cli.send(:state) }
        assert_equal contents, File.read(path)
      end
      File.write(path, JSON.generate(data))
      FileUtils.stub(:mkdir_p, ->(_path) { raise Errno::EACCES }) do
        assert_raises(Errno::EACCES) { cli.send(:save_state, "worktrees" => {}) }
      end
      assert_equal data, cli.send(:state)
    end
  end

  def test_configuration_defaults_and_validates_supported_keys
    with_cli do |cli, root|
      default = cli.send(:configuration)
      assert_equal "docker_compose", default.fetch("manager")
      assert_equal 3000, default.fetch("preferred_port")
      refute default.key?("mode")
      File.write(File.join(root, "brunch.yml"), "manager: command\npreferred_port: 4000\ncommands:\n  start: 'true'\n  stop: 'true'\n  remove: 'true'\n")
      assert_equal 4000, cli.send(:configuration).fetch("preferred_port")
      assert_equal "command", cli.send(:configuration).fetch("manager")

      invalid = [
        "- invalid\n", "mode: branches\n", "port_mode: shared\n", "lifecycle: active_only\n",
        "shared_port: 3000\n", "preferred_port: 0\n", "preferred_port: 49152\n",
        "preferred_port: '3000'\n", "manager: missing\n", "compose_file: ''\n",
        "manager: local_process\n", "manager: command\n", "manager: command\ncommands: []\n",
        "manager: command\ncommands:\n  start: 'true'\n  stop: 'true'\n  remove: 'true'\n  typo: 'true'\n",
        "manager: command\ncommands:\n  start: ''\n  stop: 'true'\n  remove: 'true'\n",
        "manager: command\ncommands:\n  start: 'true'\n  stop: 'true'\n  remove: 'true'\n  health: false\n"
      ]
      invalid.each do |contents|
        File.write(File.join(root, "brunch.yml"), contents)
        assert_raises(Brunch::CLI::ConfigurationError) { cli.send(:configuration) }
      end
      File.write(File.join(root, "brunch.yml"), "preferred_port: [\n")
      error = assert_raises(Brunch::CLI::ConfigurationError) { cli.send(:configuration) }
      assert_includes error.message, "Invalid brunch.yml"
    end
  end

  def test_git_failure_archive_failure_and_color
    with_cli do |cli, root|
      failure = Object.new
      failure.define_singleton_method(:success?) { false }
      Open3.stub(:capture2, ["", failure]) do
        assert_raises(SystemExit) { cli.send(:git_output, "rev-parse", "HEAD") }
      end
      Open3.stub(:pipeline, [failure]) do
        assert_raises(SystemExit) { cli.send(:archive_ref, "HEAD", File.join(root, "control")) }
      end
      fake_stdout = StringIO.new
      fake_stdout.define_singleton_method(:tty?) { true }
      original = $stdout
      $stdout = fake_stdout
      assert_equal "\e[32mactive\e[0m", cli.send(:color, "active", 32)
    ensure
      $stdout = original if original
    end
  end

  def test_version_file_is_executed_under_coverage
    path = File.expand_path("../lib/brunch/version.rb", __dir__)
    current = Brunch::VERSION
    Brunch.send(:remove_const, :VERSION)
    load path
    assert_equal current, Brunch::VERSION
  end
end
