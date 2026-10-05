# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require_relative "../lib/brunch"

class WorktreeModeTest < Minitest::Test
  def test_two_worktrees_keep_independent_environments_and_ports
    Dir.mktmpdir do |directory|
      main = File.join(directory, "main")
      feature = File.join(directory, "feature")
      moved = File.join(directory, "moved")
      Dir.mkdir(main)
      run_git(main, "init", "--quiet")
      run_git(main, "config", "user.email", "test@example.com")
      run_git(main, "config", "user.name", "Test")
      File.write(File.join(main, "brunch.yml"), <<~YAML)
        manager: command
        commands:
          start: "true"
          stop: "true"
          remove: "true"
      YAML
      File.write(File.join(main, "app.txt"), "committed\n")
      run_git(main, "add", ".")
      run_git(main, "commit", "--quiet", "-m", "initial")
      run_git(main, "worktree", "add", "--quiet", "-b", "feature", feature)

      assert_equal 0, run_brunch(main, "activate")
      assert_equal 0, run_brunch(feature, "activate")
      main_port = capture_brunch(main, "port")
      feature_port = capture_brunch(feature, "port")
      refute_equal main_port, feature_port

      File.write(File.join(feature, "app.txt"), "uncommitted\n")
      assert_equal 0,
                   run_brunch(feature, "run", "--", "ruby", "-e",
                              "File.write('proof.txt', File.read('app.txt') + ENV.fetch('BRUNCH_PORT'))")
      assert_equal "uncommitted\n#{feature_port}", File.read(File.join(feature, "proof.txt"))
      File.delete(File.join(feature, "proof.txt"))

      main_id = git_dir_id(main)
      feature_id = git_dir_id(feature)
      data = JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
      assert_equal "running", current_entry(data, main_id).fetch("status")
      assert_equal "running", current_entry(data, feature_id).fetch("status")
      assert_equal 0, run_brunch(main, "cleanup")
      data = JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
      assert data.fetch("worktrees").key?(feature_id)

      assert_equal 0, run_brunch(feature, "stop")
      data = JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
      assert_equal "running", current_entry(data, main_id).fetch("status")
      assert_equal "stopped", current_entry(data, feature_id).fetch("status")

      File.write(File.join(feature, "app.txt"), "committed\n")
      run_git(feature, "switch", "--quiet", "-c", "alternate")
      assert_equal 0, run_brunch(feature, "activate")
      data = JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
      assert_equal "stopped",
                   data.fetch("worktrees").fetch(feature_id).fetch("environments").fetch("feature").fetch("status")
      assert_equal "alternate", data.fetch("worktrees").fetch(feature_id).fetch("current")
      assert_equal feature_port, capture_brunch(feature, "port")
      assert_equal "running", current_entry(data, main_id).fetch("status")

      run_git(main, "worktree", "move", feature, moved)
      assert_equal 0, run_brunch(main, "cleanup")
      assert_equal 0, run_brunch(main, "worktree-event", "worktree-moved", feature, moved)
      assert_equal feature_port, capture_brunch(moved, "port")
      data = JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
      assert_equal File.realpath(moved), data.fetch("worktrees").fetch(feature_id).fetch("path")

      run_git(main, "worktree", "remove", moved)
      assert_equal 0, run_brunch(main, "cleanup")
      assert_equal 0, run_brunch(main, "worktree-event", "worktree-removed", moved)
      data = JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
      assert data.fetch("worktrees").key?(main_id)
      refute data.fetch("worktrees").key?(feature_id)
      assert File.file?(File.join(main, "app.txt"))
    end
  end

  def test_git_hooks_ext_creates_environment_once_for_new_worktree
    skip "git-hooks-ext is unavailable" unless system("ghe", "--version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |directory|
      main = File.join(directory, "main")
      feature = File.join(directory, "feature")
      moved = File.join(directory, "moved")
      Dir.mkdir(main)
      run_git(main, "init", "--quiet")
      run_git(main, "config", "user.email", "test@example.com")
      run_git(main, "config", "user.name", "Test")
      File.write(File.join(main, "Gemfile"), "source 'https://rubygems.org'\ngem 'brunch', path: '../brunch'\n")
      File.write(File.join(main, "brunch.yml"), <<~YAML)
        manager: command
        commands:
          start: "printf x >> .starts"
          stop: "true"
          remove: "true"
      YAML
      run_git(main, "add", ".")
      run_git(main, "commit", "--quiet", "-m", "initial")
      Dir.chdir(main) { Brunch::Hooks.install }

      assert system("ghe", "worktree", "add", "-b", "feature", feature, chdir: main)
      assert_equal "x", File.read(File.join(feature, ".starts"))
      assert_equal 0, run_brunch(main, "worktree-event", "worktree-created", feature)
      assert_equal "x", File.read(File.join(feature, ".starts"))

      assert system("ghe", "worktree", "move", feature, moved, chdir: main)
      data = JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
      assert_equal File.realpath(moved), data.fetch("worktrees").fetch(git_dir_id(moved)).fetch("path")
      File.delete(File.join(moved, ".starts"))
      assert system("ghe", "worktree", "remove", moved, chdir: main)
      data = JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
      assert_empty data.fetch("worktrees")
    end
  end

  def test_git_hooks_ext_deletion_removes_environment_but_rename_preserves_it
    skip "git-hooks-ext 0.6.0 is unavailable" unless system("ghe", "--version", out: File::NULL, err: File::NULL)

    output, = Open3.capture2("ghe", "--version")
    skip "git-hooks-ext 0.6.0 is unavailable" if Gem::Version.new(output.split.last) < Gem::Version.new("0.6.0")

    assert_branch_deletion_lifecycle
  end

  def test_git_hook_settles_rename_and_delete_after_git_exits_without_another_brunch_command
    skip "git-hooks-ext 0.6.0 is unavailable" unless recent_git_hooks_ext?

    Dir.mktmpdir do |directory|
      root = File.join(directory, "repo")
      Dir.mkdir(root)
      run_git(root, "init", "--quiet", "-b", "main")
      run_git(root, "config", "user.email", "test@example.com")
      run_git(root, "config", "user.name", "Test")
      File.write(File.join(root, "Gemfile"), "source 'https://rubygems.org'\ngem 'brunch', path: #{File.expand_path('..', __dir__).inspect}\n")
      File.write(File.join(root, "brunch.yml"), <<~YAML)
        manager: command
        commands:
          start: "true"
          stop: "true"
          remove: "printf x >> .removed"
      YAML
      run_git(root, "add", ".")
      run_git(root, "commit", "--quiet", "-m", "initial")
      Dir.chdir(root) do
        Brunch::Hooks.install
        Brunch::CLI.start(["activate"])
      end
      run_git(root, "switch", "--quiet", "-c", "feature/topic")
      run_git(root, "switch", "--quiet", "main")

      hook = File.join(root, ".git", "hooks", "branch-deleted")
      gate = File.join(directory, "release-hook")
      File.open(hook, "a") do |file|
        file.puts "sleep 0.01 until File.exist?(#{gate.inspect})"
      end

      git_pid = Process.spawn("git", "branch", "-m", "feature/topic", "renamed/topic",
                              chdir: root, out: File::NULL, err: $stderr)
      begin
        wait_for_brunch_state(root) { |data| data.fetch("deleted_branches", {}).key?("feature/topic") }
        pending = brunch_state(root).fetch("deleted_branches").fetch("feature/topic")
        assert_kind_of Hash, pending
        assert_equal git_pid, pending.fetch("git").fetch("pid")
        assert_equal 0, run_brunch(root, "status")
        assert brunch_environments(root).key?("feature/topic")
        refute File.exist?(File.join(root, ".removed"))
      ensure
        File.write(gate, "go")
        _pid, status = Process.waitpid2(git_pid)
        assert status.success?, "git branch -m failed"
      end
      wait_for_brunch_state(root) do |data|
        data.fetch("worktrees").values.first.fetch("environments").key?("renamed/topic") &&
          data.fetch("deleted_branches", {}).empty?
      end
      assert brunch_environments(root).key?("renamed/topic")
      refute brunch_environments(root).key?("feature/topic")
      refute File.exist?(File.join(root, ".removed"))

      File.delete(gate)
      git_pid = Process.spawn("git", "branch", "-D", "renamed/topic", chdir: root,
                                                                      out: File::NULL, err: $stderr)
      begin
        wait_for_brunch_state(root) { |data| data.fetch("deleted_branches", {}).key?("renamed/topic") }
        assert_equal 0, run_brunch(root, "status")
        assert brunch_environments(root).key?("renamed/topic")
      ensure
        File.write(gate, "go")
        _pid, status = Process.waitpid2(git_pid)
        assert status.success?, "git branch -D failed"
      end
      wait_for_brunch_state(root) do |data|
        !data.fetch("worktrees").values.first.fetch("environments").key?("renamed/topic") &&
          data.fetch("deleted_branches", {}).empty?
      end
      assert_equal "x", File.read(File.join(root, ".removed"))

      run_git(root, "branch", "-m", "main", "primary")
      wait_for_brunch_state(root) do |data|
        data.fetch("worktrees").values.first.fetch("current") == "primary" && data.fetch("deleted_branches", {}).empty?
      end
      assert brunch_environments(root).key?("primary")
      refute brunch_environments(root).key?("main")
      assert_equal "x", File.read(File.join(root, ".removed"))

      run_git(root, "switch", "--quiet", "-c", "source")
      run_git(root, "switch", "--quiet", "primary")
      run_git(root, "switch", "--quiet", "-c", "target")
      run_git(root, "switch", "--quiet", "primary")
      source_project = brunch_environments(root).fetch("source").fetch("project")
      target_project = brunch_environments(root).fetch("target").fetch("project")
      refute_equal source_project, target_project
      run_git(root, "branch", "-M", "source", "target")
      wait_for_brunch_state(root) do |data|
        environments = data.fetch("worktrees").values.first.fetch("environments")
        environments["target"]&.fetch("project") == source_project && !environments.key?("source") &&
          data.fetch("deleted_branches", {}).empty?
      end
      assert_equal "xx", File.read(File.join(root, ".removed"))
    end
  end

  def test_reftable_rename_preserves_environment_without_deletion_event
    version, = Open3.capture2("git", "--version")
    git_version = version[/git version (\d+(?:\.\d+)+)/, 1]
    skip "Git 2.54 or later is unavailable" unless git_version && Gem::Version.new(git_version) >= Gem::Version.new("2.54")
    skip "git-hooks-ext is unavailable" unless system("ghe", "--version", out: File::NULL, err: File::NULL)

    hook_version, = Open3.capture2("ghe", "--version")
    skip "git-hooks-ext 0.6.0 is unavailable" if Gem::Version.new(hook_version.split.last) < Gem::Version.new("0.6.0")

    assert_branch_deletion_lifecycle("--ref-format=reftable")
  end

  def test_parallel_activation_reserves_distinct_ports
    Dir.mktmpdir do |directory|
      main = File.join(directory, "main")
      feature = File.join(directory, "feature")
      Dir.mkdir(main)
      run_git(main, "init", "--quiet")
      run_git(main, "config", "user.email", "test@example.com")
      run_git(main, "config", "user.name", "Test")
      File.write(File.join(main, "brunch.yml"), <<~YAML)
        manager: command
        commands:
          start: "sleep 1"
          stop: "true"
          remove: "true"
      YAML
      run_git(main, "add", ".")
      run_git(main, "commit", "--quiet", "-m", "initial")
      run_git(main, "worktree", "add", "--quiet", "-b", "feature", feature)

      executable = File.expand_path("../exe/brunch", __dir__)
      processes = [main, feature].map do |path|
        Process.spawn(Gem.ruby, executable, "activate", chdir: path, out: File::NULL, err: File::NULL)
      end
      processes.each do |pid|
        _completed, status = Process.waitpid2(pid)
        assert status.success?, "parallel brunch activation failed"
      end

      data = JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
      records = data.fetch("worktrees").values
      assert_equal 2, records.size
      assert_equal 2, records.map { |record| record.fetch("port") }.uniq.size
      assert(records.all? do |record|
        record.fetch("environments").fetch(record.fetch("current")).fetch("status") == "running"
      end)
    end
  end

  private

  def recent_git_hooks_ext?
    output, status = Open3.capture2("ghe", "--version")
    status.success? && Gem::Version.new(output.split.last) >= Gem::Version.new("0.6.0")
  rescue Errno::ENOENT
    false
  end

  def brunch_state(root)
    JSON.parse(File.read(File.join(root, ".git", "brunch", "state.json")))
  end

  def brunch_environments(root)
    brunch_state(root).fetch("worktrees").values.first.fetch("environments")
  end

  def wait_for_brunch_state(root)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    loop do
      data = brunch_state(root)
      return if yield(data)

      flunk "Timed out waiting for Brunch branch state: #{data.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
  end

  def assert_branch_deletion_lifecycle(*init_arguments)
    Dir.mktmpdir do |directory|
      root = File.join(directory, "repo")
      Dir.mkdir(root)
      run_git(root, "init", "--quiet", "-b", "main", *init_arguments)
      run_git(root, "config", "user.email", "test@example.com")
      run_git(root, "config", "user.name", "Test")
      File.write(File.join(root, "Gemfile"), "source 'https://rubygems.org'\ngem 'brunch', path: '../brunch'\n")
      File.write(File.join(root, "brunch.yml"), <<~YAML)
        manager: command
        commands:
          start: "true"
          stop: "true"
          remove: "printf x >> .removed"
      YAML
      run_git(root, "add", ".")
      run_git(root, "commit", "--quiet", "-m", "initial")
      Dir.chdir(root) do
        Brunch::Hooks.install
        Brunch::CLI.start(["activate"])
      end

      run_git(root, "switch", "--quiet", "-c", "feature")
      run_git(root, "switch", "--quiet", "main")
      run_git(root, "branch", "-m", "feature", "renamed")
      assert_equal 0, run_brunch(root, "status")
      environments = JSON.parse(File.read(File.join(root, ".git", "brunch", "state.json"))).fetch("worktrees").values.first.fetch("environments")
      assert environments.key?("renamed")
      refute File.exist?(File.join(root, ".removed"))

      run_git(root, "branch", "-D", "renamed")
      assert_equal 0, run_brunch(root, "status")
      environments = JSON.parse(File.read(File.join(root, ".git", "brunch", "state.json"))).fetch("worktrees").values.first.fetch("environments")
      refute environments.key?("renamed")
      assert_equal "x", File.read(File.join(root, ".removed"))

      run_git(root, "switch", "--quiet", "-c", "another")
      run_git(root, "switch", "--quiet", "main")
      run_git(root, "branch", "-m", "another", "moved")
      run_git(root, "branch", "-D", "moved")
      assert_equal 0, run_brunch(root, "status")
      environments = JSON.parse(File.read(File.join(root, ".git", "brunch", "state.json"))).fetch("worktrees").values.first.fetch("environments")
      refute environments.key?("another")
      assert_equal "xx", File.read(File.join(root, ".removed"))
    end
  end

  def run_git(directory, *arguments)
    assert system("git", "-C", directory, *arguments, out: File::NULL, err: File::NULL),
           "git #{arguments.join(' ')} failed"
  end

  def run_brunch(directory, *arguments)
    Dir.chdir(directory) { Brunch::CLI.start(arguments) }
  end

  def capture_brunch(directory, *arguments)
    output, = capture_io { assert_equal 0, run_brunch(directory, *arguments) }
    output.strip
  end

  def git_dir_id(directory)
    output, status = Open3.capture2("git", "-C", directory, "rev-parse", "--absolute-git-dir")
    assert status.success?
    Digest::SHA256.hexdigest(File.realpath(output.strip))[0, 16]
  end

  def current_entry(data, id)
    record = data.fetch("worktrees").fetch(id)
    record.fetch("environments").fetch(record.fetch("current"))
  end
end
