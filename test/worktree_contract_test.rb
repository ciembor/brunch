# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"
require_relative "../lib/brunch"

class WorktreeContractTest < Minitest::Test
  class ManagerDouble
    attr_accessor :available, :create_result, :start_result, :stop_result, :resume_result, :reset_result, :remove_result,
                  :status_result
    attr_reader :events

    def initialize
      @events = []
      @available = true
      @create_result = true
      @start_result = true
      @stop_result = true
      @resume_result = true
      @reset_result = true
      @remove_result = true
      @status_result = "unknown"
    end

    def available? = available
    def status(_entry) = status_result
    def port_available?(_port) = true

    def create(entry)
      events << [:create, entry.fetch("ref")]
      create_result
    end

    def start(entry)
      events << [:start, entry.fetch("ref")]
      start_result
    end

    def stop(entry)
      events << [:stop, entry.fetch("ref")]
      stop_result
    end

    def resume(entry)
      events << [:resume, entry.fetch("ref")]
      resume_result
    end

    def reset(entry)
      events << [:reset, entry.fetch("ref")]
      reset_result
    end

    def remove(entry)
      events << [:remove, entry.fetch("ref")]
      remove_result
    end
  end

  def with_repo
    Dir.mktmpdir("brunch-worktree-test") do |directory|
      root = File.realpath(directory)
      assert system("git", "-C", root, "init", "--quiet", "-b", "main", out: File::NULL)
      assert system("git", "-C", root, "config", "maintenance.auto", "false")
      assert system("git", "-C", root, "config", "user.email", "test@example.com")
      assert system("git", "-C", root, "config", "user.name", "Test")
      File.write(File.join(root, "brunch.yml"), <<~YAML)
        manager: command
        commands:
          start: "true"
          stop: "true"
          remove: "true"
          logs: "echo logs:$1"
      YAML
      File.write(File.join(root, "app.txt"), "hello\n")
      assert system("git", "-C", root, "add", ".")
      assert system("git", "-C", root, "commit", "--quiet", "-m", "initial")
      Dir.chdir(root) { yield Brunch::CLI.new, root }
    end
  end

  def without_reflog(&)
    original_capture = Open3.method(:capture2)
    Open3.stub(:capture2, lambda { |*arguments|
      arguments[1] == "reflog" ? ["", Struct.new(:success?).new(false)] : original_capture.call(*arguments)
    }, &)
  end

  def test_dispatch_covers_worktree_commands_and_rejects_other_branch
    with_repo do |cli, root|
      calls = []
      %i[worktree_activate worktree_stop worktree_cleanup worktree_status worktree_ports worktree_port worktree_logs
         worktree_run worktree_doctor worktree_repair worktree_remove worktree_move worktree_watch].each do |method|
        cli.define_singleton_method(method) { |*args, **kwargs| calls << [method, args, kwargs] }
      end
      assert_equal 0, cli.send(:worktree_command, ["worktree-event", "worktree-repaired", root])
      assert_equal 0, cli.send(:worktree_command, ["worktree-event", "worktree-removed", root])
      assert_equal 0, cli.send(:worktree_command, ["worktree-event", "worktree-moved", root, root])
      assert_equal 0, cli.send(:worktree_command, ["restart"])
      assert_equal 0, cli.send(:worktree_command, ["stop"])
      assert_equal 0, cli.send(:worktree_command, ["cleanup"])
      assert_equal 0, cli.send(:worktree_command, ["status"])
      assert_equal 0, cli.send(:worktree_command, ["list"])
      assert_equal 0, cli.send(:worktree_command, ["watch"])
      assert_equal 0, cli.send(:worktree_command, ["port"])
      assert_equal 0, cli.send(:worktree_command, ["logs", "--follow"])
      assert_equal 0, cli.send(:worktree_command, ["run", "--", "true"])
      assert_equal 64, cli.send(:worktree_command, ["exec", "--", "true"])
      assert_equal 0, cli.send(:worktree_command, ["doctor"])
      assert_equal 64, cli.send(:worktree_command, ["unexpected"])
      assert_raises(SystemExit) { cli.send(:worktree_command, %w[start another]) }
      ref = cli.send(:worktree_ref, root).first
      assert_equal 0, cli.send(:worktree_command, ["start", ref])
      assert_equal 0, cli.send(:worktree_command, ["worktree-event", "worktree-created", root])
      assert_includes calls, [:worktree_activate, [root], { force: true }]
      assert_includes calls, [:worktree_repair, [root], {}]
      assert_includes calls, [:worktree_logs, [["--follow"]], {}]
    end
  end

  def test_status_ports_logs_run_and_doctor_on_active_worktree
    with_repo do |cli, root|
      assert_equal 0, cli.start(["activate"])
      port = cli.send(:current_worktree_entry, cli.send(:state)).first.fetch("port")
      out, = capture_io do
        cli.send(:worktree_status)
        cli.send(:worktree_ports)
        cli.send(:worktree_port)
      end
      assert_includes out, root
      assert_includes out, port.to_s
      assert cli.send(:worktree_logs, ["--follow"])
      cli.send(:worktree_run, [Gem.ruby, "-e", "File.write('proof', ENV.fetch('BRUNCH_PORT'))"])
      assert_equal port.to_s, File.read(File.join(root, "proof"))
      assert_raises(SystemExit) { cli.send(:worktree_run, [Gem.ruby, "-e", "exit 1"]) }

      hooks = File.join(root, ".git", "hooks")
      Brunch::Hooks::EVENTS.each { |event| File.write(File.join(hooks, event), "Brunch::Hooks.dispatch\n") }
      cli.define_singleton_method(:system) { |*_args, **_kwargs| true }
      out, = capture_io { cli.send(:worktree_doctor) }
      assert_includes out, "OK Unique ports"
      assert_includes out, "OK Git worktree paths"
      File.write(File.join(hooks, Brunch::Hooks::EVENTS.first), "bad\n")
      out, = capture_io { assert_raises(SystemExit) { cli.send(:worktree_doctor) } }
      assert_includes out, "FAIL Brunch hooks"
    end
  end

  def test_worktree_reporting_without_active_environment
    with_repo do |cli, root|
      out, = capture_io { cli.send(:worktree_status) }
      [[:worktree_port], [:worktree_logs, []], [:worktree_run, ["true"]], [:worktree_stop, root]].each do |method, *arguments|
        error = assert_raises(Brunch::CLI::OperationError) { cli.send(method, *arguments) }
        assert_includes error.message, "No Brunch environment"
      end
      assert_includes out, "No Brunch environment"
    end
  end

  def test_worktree_operations_without_environment_return_nonzero
    with_repo do |cli, _root|
      [%w[port], %w[stop], %w[logs], %w[run -- true]].each do |command|
        _output, error = capture_io { assert_equal 1, cli.start(command) }
        assert_includes error, "No Brunch environment"
      end
    end
  end

  def test_repair_selects_move_or_activation
    with_repo do |cli, root|
      id = cli.send(:worktree_identity, root)
      calls = []
      current_state = { "worktrees" => { id => { "path" => "/old/path" } } }
      cli.define_singleton_method(:state) { current_state }
      cli.define_singleton_method(:worktree_move) { |*args| calls << [:move, args] }
      cli.define_singleton_method(:worktree_activate) { |*args| calls << [:activate, args] }
      cli.send(:worktree_repair, root)
      assert_equal [:move, ["/old/path", root]], calls.last
      current_state = { "worktrees" => { id => { "path" => root } } }
      cli.send(:worktree_repair, root)
      assert_equal [:activate, [root]], calls.last
      missing_parent = File.join(root, "missing", "child")
      assert_equal missing_parent, cli.send(:canonical_worktree_path, missing_parent)
    end
  end

  def test_compose_activation_copies_worktree_compose_file_to_control_directory
    with_repo do |cli, root|
      File.write(File.join(root, "compose.yaml"), "services: {}\n")
      File.open(File.join(root, "brunch.yml"), "a") { |file| file.write("manager: docker_compose\n") }
      manager = Object.new
      manager.define_singleton_method(:available?) { true }
      manager.define_singleton_method(:port_available?) { |_port| true }
      manager.define_singleton_method(:create) { |_entry| true }
      manager.define_singleton_method(:start) { |_entry| true }
      Brunch::Managers.stub(:build, manager) do
        out, = capture_io { cli.send(:worktree_activate, root) }
        assert_includes out, "Started"
      end
      record, active = cli.send(:current_worktree_entry, cli.send(:state))
      assert_equal root, record.fetch("path")
      assert_equal "services: {}\n", File.read(File.join(active.fetch("control"), "compose.yaml"))
    end
  end

  def test_worktree_event_ignores_absent_directories_and_activates_existing_ones
    with_repo do |cli, root|
      calls = []
      cli.define_singleton_method(:worktree_activate) { |*_args| calls << :activate }
      cli.define_singleton_method(:worktree_repair) { |*_args| calls << :repair }
      missing = File.join(root, "missing")
      assert_equal 0, cli.send(:worktree_command, ["worktree-event", "worktree-created", missing])
      assert_equal 0, cli.send(:worktree_command, ["worktree-event", "worktree-repaired", missing])
      assert_equal 0, cli.send(:worktree_command, ["worktree-event", "worktree-created", root])
      assert_equal 0, cli.send(:worktree_command, ["worktree-event", "worktree-repaired", root])
      assert_equal %i[activate repair], calls
    end
  end

  def test_invalid_and_unborn_git_worktrees_are_rejected
    Dir.mktmpdir("brunch-unborn-worktree") do |directory|
      root = File.realpath(directory)
      cli = Brunch::CLI.new
      assert_raises(SystemExit) { cli.send(:worktree_identity, root) }
      assert system("git", "-C", root, "init", "--quiet", out: File::NULL)
      assert_raises(SystemExit) { cli.send(:worktree_ref, root) }
    end
  end

  def test_detached_head_has_stable_ref_and_port_search_skips_reserved_ports
    with_repo do |cli, root|
      assert system("git", "-C", root, "checkout", "--detach", "--quiet", out: File::NULL)
      ref, head = cli.send(:worktree_ref, root)
      assert_equal "detached-#{head[0, 12]}", ref
      manager = ManagerDouble.new
      cli.define_singleton_method(:preferred_port) { 30_000 }
      data = { "worktrees" => { "existing" => { "port" => 30_000 }, "other" => { "port" => 30_001 } } }
      assert_equal 30_002, cli.send(:worktree_port_for, "new", data, manager)
    end
  end

  def test_activation_rejects_unavailable_manager_and_missing_compose
    with_repo do |cli, root|
      manager = ManagerDouble.new
      File.write(File.join(root, "brunch.yml"), "manager: docker_compose\n")
      manager.available = false
      Brunch::Managers.stub(:build, manager) do
        assert_raises(SystemExit) { cli.send(:worktree_activate, root) }
      end
      manager.available = true
      Brunch::Managers.stub(:build, manager) do
        assert_raises(SystemExit) { cli.send(:worktree_activate, root) }
      end
      assert_empty(cli.send(:state).fetch("worktrees").values.flat_map { |record| record.fetch("environments").values })
    end
  end

  def test_interrupted_create_and_start_can_be_retried
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        manager.create_result = false
        assert_raises(SystemExit) { cli.send(:worktree_activate, root) }
        _record, entry = cli.send(:current_worktree_entry, cli.send(:state))
        assert_equal "starting", entry.fetch("status")

        manager.create_result = true
        manager.start_result = false
        assert_raises(SystemExit) { cli.send(:worktree_activate, root) }
        manager.start_result = true
        out, = capture_io { cli.send(:worktree_activate, root) }
        assert_includes out, "Started"
        _record, entry = cli.send(:current_worktree_entry, cli.send(:state))
        assert_equal "running", entry.fetch("status")
        assert_includes manager.events, [:reset, "main"]
      end
    end
  end

  def test_switch_back_resumes_existing_environment_without_reset
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        assert system("git", "-C", root, "switch", "--quiet", "-c", "feature")
        cli.send(:worktree_activate, root)
        assert system("git", "-C", root, "switch", "--quiet", "main")
        out, = capture_io { cli.send(:worktree_activate, root) }

        assert_includes out, "Resumed main"
        assert_includes manager.events, [:resume, "main"]
        refute_includes manager.events, [:reset, "main"]
        assert_equal "running", cli.send(:current_worktree_entry, cli.send(:state)).last.fetch("status")

        cli.send(:worktree_stop, root)
        manager.resume_result = false
        error = assert_raises(SystemExit) { cli.send(:worktree_activate, root) }
        assert_equal 1, error.status
        assert_equal "stopped", cli.send(:current_worktree_entry, cli.send(:state)).last.fetch("status")
        manager.resume_result = true
        cli.send(:worktree_activate, root)
        assert_equal "running", cli.send(:current_worktree_entry, cli.send(:state)).last.fetch("status")

        manager.status_result = "stopped"
        resumes_before = manager.events.count { |event| event == [:resume, "main"] }
        cli.send(:worktree_activate, root)
        resumes_after = manager.events.count { |event| event == [:resume, "main"] }
        assert_equal resumes_before + 1, resumes_after
      end
    end
  end

  def test_renamed_branch_keeps_its_environment_until_the_new_name_is_deleted
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        assert system("git", "switch", "--quiet", "-c", "feature")
        cli.send(:worktree_activate, root)
        assert system("git", "switch", "--quiet", "main")
        cli.send(:worktree_activate, root)

        old_oid = cli.send(:git_output, "rev-parse", "feature")
        assert system("git", "branch", "-m", "feature", "renamed")
        assert system("git", "switch", "--quiet", "renamed")
        assert system("git", "commit", "--allow-empty", "--quiet", "-m", "new work")
        assert system("git", "switch", "--quiet", "main")
        cli.start(["branch-deleted", "feature", old_oid])
        cli.start(["status"])
        environments = cli.send(:state).fetch("worktrees").values.first.fetch("environments")
        assert environments.key?("renamed")
        refute environments.key?("feature")
        refute_includes manager.events, [:remove, "feature"]

        renamed_oid = cli.send(:git_output, "rev-parse", "renamed")
        assert system("git", "branch", "-D", "renamed", out: File::NULL)
        cli.start(["branch-deleted", "renamed", renamed_oid])
        cli.start(["status"])
        environments = cli.send(:state).fetch("worktrees").values.first.fetch("environments")
        refute environments.key?("renamed")
        assert_includes manager.events, [:remove, "renamed"]
      end
    end
  end

  def test_deleted_branch_reconciliation_preserves_existing_ref_and_reports_git_failure
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        oid = cli.send(:git_output, "rev-parse", "main")
        cli.start(["branch-deleted", "main", oid])
        cli.start(["status"])
        assert cli.send(:state).fetch("worktrees").values.first.fetch("environments").key?("main")
        refute_includes manager.events, [:remove, "main"]

        cli.start(["branch-deleted", "main", oid])
        failed = Struct.new(:success?).new(false)
        Open3.stub(:capture2, ["", failed]) do
          assert_raises(SystemExit) { cli.send(:local_branch_refs) }
        end
      end
    end
  end

  def test_deleted_branch_stays_pending_when_reflog_is_unavailable
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        oid = cli.send(:git_output, "rev-parse", "main")
        cli.send(:rename_branch_environments, "main", "old")
        cli.start(["branch-deleted", "old", oid])

        without_reflog { cli.start(["status"]) }
        assert_equal oid, cli.send(:state).fetch("deleted_branches").fetch("old")
        refute_includes manager.events, [:remove, "old"]
      end
    end
  end

  def test_missing_branch_without_reflog_keeps_its_environment
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        cli.send(:rename_branch_environments, "main", "old")
        without_reflog { cli.start(["status"]) }

        environments = cli.send(:state).fetch("worktrees").values.first.fetch("environments")
        assert environments.key?("old")
        refute_includes manager.events, [:remove, "old"]
      end
    end
  end

  def test_missing_branch_without_hook_is_removed_when_no_rename_is_known
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        assert system("git", "switch", "--quiet", "-c", "feature")
        cli.send(:worktree_activate, root)
        assert system("git", "switch", "--quiet", "main")
        cli.send(:worktree_activate, root)
        assert system("git", "branch", "-D", "feature", out: File::NULL)

        cli.start(["status"])
        environments = cli.send(:state).fetch("worktrees").values.first.fetch("environments")
        refute environments.key?("feature")
        assert_includes manager.events, [:remove, "feature"]
      end
    end
  end

  def test_rename_without_deletion_hook_is_recovered_from_reflog
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        assert system("git", "switch", "--quiet", "-c", "feature")
        cli.send(:worktree_activate, root)
        assert system("git", "switch", "--quiet", "main")
        cli.send(:worktree_activate, root)
        assert system("git", "branch", "-m", "feature", "renamed")

        cli.start(["status"])
        environments = cli.send(:state).fetch("worktrees").values.first.fetch("environments")
        assert environments.key?("renamed")
        refute environments.key?("feature")
        refute_includes manager.events, [:remove, "feature"]
      end
    end
  end

  def test_detached_environment_is_not_treated_as_a_deleted_branch
    with_repo do |cli, root|
      assert system("git", "checkout", "--detach", "--quiet", out: File::NULL)
      Brunch::Managers.stub(:build, ManagerDouble.new) do
        cli.send(:worktree_activate, root)
        cli.start(["status"])
        ref = cli.send(:state).fetch("worktrees").values.first.fetch("environments").keys.first
        assert ref.start_with?("detached-")
      end
    end
  end

  def test_branch_cleanup_preserves_state_when_removal_fails_and_clears_empty_worktree
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.start(%w[branch-deleted untracked oid])
        assert_empty cli.send(:state).fetch("deleted_branches", {})
        cli.send(:worktree_activate, root)
        cli.send(:remove_branch_environments, "other")
        manager.remove_result = false
        assert_raises(SystemExit) { cli.send(:remove_branch_environments, "main") }
        assert cli.send(:state).fetch("worktrees").values.first.fetch("environments").key?("main")
        manager.remove_result = true
        cli.send(:remove_branch_environments, "main")
        assert_empty cli.send(:state).fetch("worktrees")
      end
    end
  end

  def test_branch_reconciliation_ignores_worktree_removed_before_its_lock
    [[:rename_branch_environments, %w[main renamed]], [:remove_branch_environments, ["main"]]].each do |method, arguments|
      with_repo do |cli, root|
        Brunch::Managers.stub(:build, ManagerDouble.new) do
          cli.send(:worktree_activate, root)
          cli.define_singleton_method(:with_worktree_lock) do |_id, &operation|
            data = state
            data.fetch("worktrees").clear
            save_state(data)
            operation.call
          end
          cli.send(method, *arguments)
          assert_empty cli.send(:state).fetch("worktrees")
        end
      end
    end
  end

  def test_rename_does_not_replace_an_existing_environment
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        cli.send(:rename_branch_environments, "main", "renamed")
        record = cli.send(:state).fetch("worktrees").values.first
        assert_equal "renamed", record.fetch("current")
        assert_equal "renamed", record.fetch("environments").fetch("renamed").fetch("ref")

        data = cli.send(:state)
        record = data.fetch("worktrees").values.first
        record.fetch("environments")["main"] = record.fetch("environments").fetch("renamed").dup
        cli.send(:save_state, data)
        cli.send(:rename_branch_environments, "renamed", "main")
        record = cli.send(:state).fetch("worktrees").values.first
        assert record.fetch("environments").key?("renamed")
        assert record.fetch("environments").key?("main")
      end
    end
  end

  def test_switch_stop_reset_stop_remove_and_move_failures_preserve_state
    with_repo do |cli, root|
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        manager.stop_result = false
        assert_raises(SystemExit) { cli.send(:worktree_stop, root) }
        assert_equal "running", cli.send(:current_worktree_entry, cli.send(:state)).last.fetch("status")
        assert system("git", "-C", root, "switch", "--quiet", "-c", "feature")
        assert_raises(SystemExit) { cli.send(:worktree_activate, root) }
        assert_equal "main", cli.send(:current_worktree_entry, cli.send(:state)).last.fetch("ref")

        assert system("git", "-C", root, "switch", "--quiet", "main")
        manager.stop_result = true
        manager.reset_result = false
        assert_raises(SystemExit) { cli.send(:worktree_activate, root, force: true) }
        manager.reset_result = true

        manager.remove_result = false
        assert_raises(SystemExit) { cli.send(:worktree_remove, root) }
        assert cli.send(:state).fetch("worktrees").key?(cli.send(:worktree_identity, root))

        new_path = File.join(root, "moved")
        Dir.mkdir(new_path)
        manager.stop_result = false
        assert_raises(SystemExit) { cli.send(:worktree_move, root, new_path) }
        assert_equal root, cli.send(:state).fetch("worktrees").values.first.fetch("path")
      end
    end
  end

  def test_worktree_list_failure_and_missing_stale_path
    with_repo do |cli, root|
      failure = Struct.new(:success?).new(false)
      Open3.stub(:capture2, ["", failure]) do
        assert_raises(SystemExit) { cli.send(:worktree_paths) }
      end
      manager = ManagerDouble.new
      Brunch::Managers.stub(:build, manager) do
        cli.send(:worktree_activate, root)
        data = cli.send(:state)
        stale = File.join(root, "removed-worktree")
        record = data.fetch("worktrees").delete(cli.send(:worktree_identity, root))
        record["path"] = stale
        data.fetch("worktrees")["stale-id"] = record
        cli.send(:save_state, data)
        out, = capture_io { cli.send(:worktree_cleanup) }
        assert_includes out, "Removed Brunch environments"
        assert_empty cli.send(:state).fetch("worktrees")
      end
    end
  end

  def test_cleanup_ignores_nonexistent_paths_in_git_worktree_list
    with_repo do |cli, root|
      missing = File.join(root, "gone")
      cli.define_singleton_method(:worktree_paths) { [root, missing] }
      cli.send(:worktree_cleanup)
      assert_empty cli.send(:state).fetch("worktrees", {})
    end
  end

  def test_ports_group_worktrees_and_dim_stopped_branches
    with_repo do |cli, root|
      id = cli.send(:worktree_identity, root)
      other = File.join(root, "other")
      data = { "worktrees" => {
        id => { "path" => root, "current" => "main", "port" => 3000,
                "environments" => { "main" => { "ref" => "main", "port" => 3000, "status" => "running" },
                                    "older" => { "ref" => "older", "port" => 3000, "status" => "stopped" } } },
        "other" => { "path" => other, "current" => "feature", "port" => 3001,
                     "environments" => { "feature" => { "ref" => "feature", "port" => 3001, "status" => "running" } } },
        "empty" => { "path" => File.join(root, "empty"), "current" => nil, "port" => 3002,
                     "environments" => {} }
      } }
      cli.define_singleton_method(:state) { data }
      cli.define_singleton_method(:color) { |text, code| "<#{code}>#{text}</#{code}>" }
      out, = capture_io { cli.send(:worktree_ports) }
      assert_equal <<~OUTPUT, out
        <32>● #{root}</32>
          ├─ <32>● main</32>  3000
        <90>  └─ ○ older  3000</90>
        ○ #{other}
          └─ <32>● feature</32>  3001
      OUTPUT
    end
  end

  def test_ports_dim_stopped_current_branch
    with_repo do |cli, root|
      id = cli.send(:worktree_identity, root)
      data = { "worktrees" => { id => { "path" => root, "current" => "main",
                                        "environments" => { "main" => { "port" => 3000, "status" => "stopped" } } } } }
      cli.define_singleton_method(:state) { data }
      cli.define_singleton_method(:color) { |text, code| "<#{code}>#{text}</#{code}>" }
      out, = capture_io { cli.send(:worktree_ports) }
      assert_equal "<32>● #{root}</32>\n<90>  └─ ○ main  3000</90>\n", out
    end
  end

  def test_watch_refreshes_the_list_until_interrupted
    with_repo do |cli, root|
      id = cli.send(:worktree_identity, root)
      cli.define_singleton_method(:state) do
        { "worktrees" => {
          id => { "path" => root, "current" => "main",
                  "environments" => { "main" => { "port" => 3000, "status" => "running" } } }
        } }
      end
      cli.define_singleton_method(:sleep) { |_seconds| raise Interrupt }
      output = StringIO.new
      output.define_singleton_method(:tty?) { true }
      previous_stdout = $stdout
      $stdout = output
      cli.send(:worktree_watch)

      assert_includes output.string, "\e[2J\e[H"
      assert_includes output.string, "● main"
      assert_includes output.string, "Refreshing every second. Press Ctrl-C to stop."
      assert_includes output.string, "Stopped watching."
    ensure
      $stdout = previous_stdout
    end
  end

  def test_watch_requires_an_interactive_terminal
    with_repo do |cli, _root|
      output = StringIO.new
      previous_stdout = $stdout
      $stdout = output

      error = assert_raises(Brunch::CLI::OperationError) { cli.send(:worktree_watch) }
      assert_equal "brunch watch requires an interactive terminal.", error.message
    ensure
      $stdout = previous_stdout
    end
  end
end
