# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../lib/brunch"

class HooksContractTest < Minitest::Test
  def test_dispatch_routes_events_and_rejects_unknown_event
    calls = []
    Brunch::CLI.stub(:start, ->(args) { calls << args }) do
      Brunch::Hooks.dispatch("post-checkout", %w[old new 0])
      Brunch::Hooks.dispatch("post-checkout", %w[old new 1])
      %w[branch-created remote-branch-created remote-branch-updated].each do |event|
        Brunch::Hooks.dispatch(event, ["feature"])
      end
      Brunch::Hooks.dispatch("branch-deleted", ["feature", "refs/heads/feature", "old-oid", "new-oid"])
      %w[worktree-created worktree-removed worktree-moved worktree-pruned worktree-repaired].each do |event|
        Brunch::Hooks.dispatch(event, ["path"])
      end
      assert_raises(SystemExit) { Brunch::Hooks.dispatch("unknown", []) }
    end
    assert_equal ["activate"], calls.first
    assert_equal 10, calls.length
    assert_includes calls, %w[branch-deleted feature old-oid]
    assert_nil ENV.fetch("BRUNCH_BRANCH_DELETION_HOOK", nil)
    assert_equal %w[worktree-event worktree-repaired path], calls.last
  end

  def test_branch_deletion_hook_marks_only_its_own_dispatch
    markers = []
    Brunch::CLI.stub(:start, ->(_arguments) { markers << ENV.fetch("BRUNCH_BRANCH_DELETION_HOOK", nil) }) do
      Brunch::Hooks.dispatch("branch-deleted", ["feature", "refs/heads/feature", "old-oid"])
      Brunch::Hooks.dispatch("branch-created", ["feature"])
    end
    assert_equal ["1", nil], markers
  end

  def test_branch_deletion_hook_restores_existing_marker
    marker = "BRUNCH_BRANCH_DELETION_HOOK"
    previous = ENV.fetch(marker, nil)
    ENV[marker] = "previous"

    Brunch::CLI.stub(:start, ->(_arguments) { assert_equal "1", ENV.fetch(marker) }) do
      Brunch::Hooks.dispatch("branch-deleted", ["feature", "refs/heads/feature", "old-oid"])
    end

    assert_equal "previous", ENV.fetch(marker)
  ensure
    previous ? ENV[marker] = previous : ENV.delete(marker)
  end

  def test_install_hook_is_idempotent_and_preserves_unrelated_hooks
    Dir.mktmpdir("brunch-hook-test") do |directory|
      path = File.join(directory, "hooks", "post-checkout")
      Brunch::Hooks.send(:install_hook, path, "post-checkout")
      contents = File.read(path)
      assert_includes contents, "Brunch::Hooks.dispatch"
      assert File.executable?(path)
      Brunch::Hooks.send(:install_hook, path, "post-checkout")
      assert_equal contents, File.read(path)
      File.write(path, "#!/bin/sh\necho custom\n")
      assert_raises(SystemExit) { Brunch::Hooks.send(:install_hook, path, "post-checkout") }
      assert_equal "#!/bin/sh\necho custom\n", File.read(path)
      File.write(path, "require \"brunch\"\nBrunch::Hooks.dispatch('post-checkout', ARGV)\n")
      Brunch::Hooks.send(:install_hook, path, "post-checkout")
      assert_equal contents, File.read(path)
    end
  end

  def test_install_requires_git_hooks_ext_and_propagates_bridge_failure
    Brunch::Hooks.stub(:system, ->(*_args, **_kwargs) { false }) do
      assert_raises(SystemExit) { Brunch::Hooks.install }
    end
    calls = []
    Brunch::Hooks.stub(:system, lambda { |*args, **_kwargs|
      calls << args
      args != %w[ghe install]
    }) do
      assert_raises(SystemExit) { Brunch::Hooks.install }
    end
    assert_includes calls, %w[ghe install]
  end

  def test_git_command_failure_is_reported
    failure = Struct.new(:success?).new(false)
    Open3.stub(:capture2, ["", failure]) do
      _out, error = capture_io { assert_raises(SystemExit) { Brunch::Hooks.send(:git_output, "rev-parse", "HEAD") } }
      assert_includes error, "Git command failed"
    end
  end
end
