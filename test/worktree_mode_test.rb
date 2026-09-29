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
