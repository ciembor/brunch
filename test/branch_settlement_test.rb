# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brunch"

class BranchSettlementTest < Minitest::Test
  def test_git_ancestor_selects_the_nearest_git_process
    processes = {
      40 => { parent: 30, started: "inner", state: "S", command: "/usr/bin/git" },
      30 => { parent: 20, started: "bridge", state: "S", command: "/tmp/git-hooks-ext" },
      20 => { parent: 10, started: "outer", state: "S", command: "/usr/bin/git" },
      10 => { parent: 1, started: "shell", state: "S", command: "/bin/zsh" }
    }
    Brunch::BranchSettlement.stub(:process_info, ->(pid) { processes[pid] }) do
      assert_equal({ "pid" => 40, "started" => "inner" }, Brunch::BranchSettlement.git_ancestor(40))
      assert_nil Brunch::BranchSettlement.git_ancestor(10)
    end
    Brunch::BranchSettlement.stub(:process_info, ->(pid) { processes[pid] if pid == 40 }) do
      assert_equal({ "pid" => 40, "started" => "inner" }, Brunch::BranchSettlement.git_ancestor(40))
    end
  end

  def test_running_requires_the_same_process_and_ignores_zombies
    identity = { "pid" => 123, "started" => "original" }
    info = { parent: 1, started: "original", state: "S", command: "git" }
    Brunch::BranchSettlement.stub(:process_info, ->(_pid) { info }) do
      assert Brunch::BranchSettlement.running?(identity)
      info[:state] = "Z"
      refute Brunch::BranchSettlement.running?(identity)
      info[:state] = "S"
      info[:started] = "replacement"
      refute Brunch::BranchSettlement.running?(identity)
    end
    refute Brunch::BranchSettlement.running?({ "pid" => "123", "started" => "original" })
    refute Brunch::BranchSettlement.running?(nil)
    Brunch::BranchSettlement.stub(:process_info, nil) do
      Process.stub(:kill, ->(_signal, _pid) { 1 }) do
        assert Brunch::BranchSettlement.running?(identity)
      end
    end
    Process.stub(:kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
      refute Brunch::BranchSettlement.process_exists?(123)
    end
    Process.stub(:kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert Brunch::BranchSettlement.process_exists?(123)
    end
  end

  def test_process_info_parses_ps_and_handles_disappeared_process
    success = Struct.new(:success?).new(true)
    failure = Struct.new(:success?).new(false)
    output = " 42 Mon Oct  5 18:30:24 2026 Ss /usr/bin/git\n"
    Open3.stub(:capture2, [output, success]) do
      assert_equal({ parent: 42, started: "Mon Oct 5 18:30:24 2026", state: "Ss", command: "/usr/bin/git" },
                   Brunch::BranchSettlement.process_info(123))
    end
    Open3.stub(:capture2, ["", failure]) { assert_nil Brunch::BranchSettlement.process_info(123) }
    Open3.stub(:capture2, ["invalid", success]) { assert_nil Brunch::BranchSettlement.process_info(123) }
    Open3.stub(:capture2, ->(*_args, **_kwargs) { raise Errno::ENOENT }) do
      assert_nil Brunch::BranchSettlement.process_info(123)
    end
  end

  def test_worker_waits_until_git_exits
    checks = [true, true, false]
    sleeps = []
    Brunch::BranchSettlement.stub(:running?, ->(_identity) { checks.shift }) do
      Brunch::BranchSettlement.stub(:sleep, ->(seconds) { sleeps << seconds }) do
        Brunch::BranchSettlement.wait_for({ "pid" => 123, "started" => "start" })
      end
    end
    assert_equal [0.1, 0.1], sleeps
  end

  def test_worker_is_detached_with_closed_standard_streams
    arguments = nil
    spawn = lambda do |*args, **options|
      arguments = [args, options]
      123
    end
    Process.stub(:spawn, spawn) do
      Process.stub(:detach, ->(pid) { assert_equal 123, pid }) do
        Brunch::BranchSettlement.spawn_worker("/tmp/repo", "feature", "token")
      end
    end
    assert_equal [Gem.ruby, File.expand_path("../exe/brunch", __dir__), "branch-settled", "feature", "token"], arguments[0]
    assert_equal "/tmp/repo", arguments[1][:chdir]
    assert_equal File::NULL, arguments[1][:in]
    assert_equal File::NULL, arguments[1][:out]
    assert_equal File::NULL, arguments[1][:err]
    assert arguments[1][:pgroup]
    assert arguments[1][:close_others]
  end
end
