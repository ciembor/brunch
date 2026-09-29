# frozen_string_literal: true

require "digest"

module Brunch
  module WorktreeMode
    def worktree_command(arguments)
      case arguments
      in ["worktree-event", "worktree-created", path, *_]
        worktree_activate(path) if File.directory?(path)
      in ["worktree-event", "worktree-removed" | "worktree-pruned", path, *_]
        worktree_remove(path)
      in ["worktree-event", "worktree-moved", old_path, new_path, *_]
        worktree_move(old_path, new_path)
      in ["worktree-event", "worktree-repaired", path, *_]
        worktree_repair(path) if File.directory?(path)
      in ["activate"] then worktree_activate(repo_root)
      in ["restart"] then worktree_activate(repo_root, force: true)
      in ["start", ref]
        abort "Start the checked-out branch from its worktree." unless ref == worktree_ref(repo_root).first
        worktree_activate(repo_root)
      in ["stop"] then worktree_stop(repo_root)
      in ["cleanup"] | ["register", _] then worktree_cleanup
      in ["status"] then worktree_status
      in ["ports"] then worktree_ports
      in ["port"] then worktree_port
      in ["logs", *arguments] then worktree_logs(arguments)
      in ["run", "--", *command] if !command.empty? then worktree_run(command)
      in ["doctor"] then worktree_doctor
      else
        warn "Usage: brunch {activate|start <current-ref>|stop|restart|status|ports|port|logs [args]|run -- <cmd>|doctor|cleanup}"
        return 64
      end
      0
    end

    def with_state_lock
      FileUtils.mkdir_p(state_root)
      File.open(File.join(state_root, "lock"), "w") do |lock|
        lock.flock(File::LOCK_EX)
        data = state
        result = yield(data)
        save_state(data)
        result
      end
    end

    def with_worktree_lock(id)
      directory = File.join(state_root, "worktree-locks")
      FileUtils.mkdir_p(directory)
      File.open(File.join(directory, id), "w") do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def worktree_identity(path)
      git_dir, status = Open3.capture2("git", "-C", path, "rev-parse", "--absolute-git-dir")
      abort "Not a Git worktree: #{path}" unless status.success?
      Digest::SHA256.hexdigest(File.realpath(git_dir.strip))[0, 16]
    end

    def canonical_worktree_path(path)
      File.join(File.realpath(File.dirname(path)), File.basename(path))
    rescue Errno::ENOENT
      File.expand_path(path)
    end

    def worktree_ref(path)
      branch, status = Open3.capture2("git", "-C", path, "symbolic-ref", "--quiet", "--short", "HEAD")
      head, head_status = Open3.capture2("git", "-C", path, "rev-parse", "HEAD")
      abort "Worktree has no commit: #{path}" unless head_status.success?
      [status.success? ? branch.strip : "detached-#{head.strip[0, 12]}", head.strip]
    end

    def worktree_manager(entry) = Managers.build(entry.fetch("configuration"))

    def current_worktree_entry(data, path = repo_root)
      id = worktree_identity(path)
      record = data.fetch("worktrees", {})[id]
      return [nil, nil] unless record

      [record, record.fetch("environments", {})[record["current"]]]
    end

    def worktree_port_for(id, data, manager, base: preferred_port)
      reserved = data.fetch("worktrees", {}).values.map { |record| record["port"] }
      (base..CLI::PORT_RANGE.end).chain(CLI::PORT_RANGE.begin...base).find do |port|
        !reserved.include?(port) && manager.port_available?(port)
      end || abort("No free port for worktree #{id}.")
    end

    def worktree_activate(path, force: false)
      path = File.realpath(path)
      id = worktree_identity(path)
      with_worktree_lock(id) do
        ref, head = worktree_ref(path)
        config = configuration(root: path)
        manager = Managers.build(config)
        abort "#{config.fetch('manager')} is unavailable." unless manager.available?

        existing = nil
        current_ref = nil
        with_state_lock do |data|
          record = data.fetch("worktrees", {})[id]
          existing = record&.fetch("environments", {})&.[](ref)
          current_ref = record&.[]("current")
        end
        return if existing && !force && existing["snapshot"] == path && existing["status"] == "running" && current_ref == ref

        previous = nil
        port = nil
        with_state_lock do |data|
          record = (data["worktrees"] ||= {})[id] ||= { "path" => path, "environments" => {} }
          previous = record.fetch("environments")[record["current"]] if record["current"] && record["current"] != ref
          port = record["port"] ||= worktree_port_for(id, data, manager, base: config.fetch("preferred_port"))
          record["path"] = path
        end
        if previous
          abort "Could not stop previous environment for #{path}." unless worktree_manager(previous).stop(previous)
          with_state_lock do |data|
            data.fetch("worktrees").fetch(id).fetch("environments").fetch(previous.fetch("ref"))["status"] = "stopped"
          end
        end
        if existing && !force && existing["snapshot"] == path && existing["status"] != "starting"
          with_state_lock { |data| data.fetch("worktrees").fetch(id)["current"] = ref }
          abort "Could not resume environment for #{path}. Run brunch restart to rebuild it." unless worktree_manager(existing).resume(existing)

          with_state_lock do |data|
            data.fetch("worktrees").fetch(id).fetch("environments").fetch(ref)["status"] = "running"
          end
          puts "Resumed #{ref} in #{path} at http://127.0.0.1:#{existing.fetch('port')}"
          return
        end
        abort "Could not reset environment for #{path}." if existing && !worktree_manager(existing).reset(existing)

        project = "brunch-#{id[0, 12]}-#{Digest::SHA256.hexdigest(ref)[0, 12]}"
        control = File.join(state_root, "controls", project)
        archive_ref(head, control)
        compose_file = config.fetch("compose_file")
        if %w[docker_compose podman_compose].include?(config.fetch("manager"))
          source_file = File.join(path, compose_file)
          abort "Missing #{compose_file} in #{path}." unless File.file?(source_file)
          destination = File.join(control, compose_file)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(source_file, destination)
        end
        entry = { "source_type" => "worktree", "snapshot" => path, "control" => control,
                  "ref" => ref, "head" => head, "port" => port, "project" => project,
                  "compose_file" => compose_file, "configuration" => config, "status" => "starting" }
        with_state_lock do |data|
          record = data.fetch("worktrees").fetch(id)
          record.fetch("environments")[ref] = entry
          record["current"] = ref
        end
        abort "Could not create environment for #{path}." unless manager.create(entry)
        abort "Could not start environment for #{path}." unless manager.start(entry)
        with_state_lock do |data|
          data.fetch("worktrees").fetch(id).fetch("environments")[ref] = entry.merge("status" => "running")
        end
        puts "Started #{ref} in #{path} at http://127.0.0.1:#{port}"
      end
    end

    def worktree_stop(path)
      id = worktree_identity(path)
      with_worktree_lock(id) do
        with_state_lock do |data|
          _record, entry = current_worktree_entry(data, path)
          raise CLI::OperationError, "No Brunch environment in this worktree." unless entry

          abort "Could not stop #{entry.fetch('project')}." unless worktree_manager(entry).stop(entry)
          entry["status"] = "stopped"
          puts "Stopped #{entry.fetch('project')}."
        end
      end
    end

    def worktree_remove(path)
      path = canonical_worktree_path(path)
      data = state
      id, = data.fetch("worktrees", {}).find { |_key, record| record["path"] == path }
      return unless id

      with_worktree_lock(id) do
        record = state.fetch("worktrees").fetch(id)
        record.fetch("environments").each do |ref, entry|
          abort "Could not remove environment #{ref}." unless worktree_manager(entry).remove(entry)
        end
        with_state_lock { |locked| locked.fetch("worktrees").delete(id) }
        puts "Removed Brunch environments for #{path}."
      end
    end

    def worktree_move(old_path, new_path)
      old_path = canonical_worktree_path(old_path)
      new_path = File.realpath(new_path)
      data = state
      id, = data.fetch("worktrees", {}).find { |_key, record| record["path"] == old_path }
      return worktree_activate(new_path) unless id

      with_worktree_lock(id) do
        record = state.fetch("worktrees").fetch(id)
        record.fetch("environments").each_value do |entry|
          next unless entry["status"] == "running"

          abort "Could not stop environment during worktree move." unless worktree_manager(entry).stop(entry)
        end
        with_state_lock do |locked|
          updated = locked.fetch("worktrees").fetch(id)
          updated["path"] = new_path
          updated.fetch("environments").each_value do |entry|
            entry["snapshot"] = new_path
            entry["status"] = "stopped"
          end
        end
      end
      worktree_activate(new_path, force: true)
    end

    def worktree_repair(path)
      path = File.realpath(path)
      record = state.fetch("worktrees", {})[worktree_identity(path)]
      if record && record.fetch("path") != path
        worktree_move(record.fetch("path"), path)
      else
        worktree_activate(path)
      end
    end

    def worktree_paths
      output, status = Open3.capture2("git", "worktree", "list", "--porcelain", "-z")
      abort "Could not list Git worktrees." unless status.success?
      output.split("\0").filter_map do |field|
        canonical_worktree_path(field.delete_prefix("worktree ")) if field.start_with?("worktree ")
      end
    end

    def worktree_cleanup
      paths = worktree_paths
      identities = paths.each_with_object({}) do |path, result|
        result[worktree_identity(path)] = path if File.directory?(path)
      end
      data = state
      data.fetch("worktrees", {}).each do |id, record|
        path = record.fetch("path")
        if identities[id] && identities[id] != path
          worktree_move(path, identities[id])
        elsif !paths.include?(path)
          worktree_remove(path)
        end
      end
    end

    def worktree_status
      data = state
      record, current = current_worktree_entry(data)
      return puts "No Brunch environment in this worktree." unless current

      puts "#{current.fetch('ref')} (#{record.fetch('path')}): #{worktree_manager(current).status(current)}, http://127.0.0.1:#{record.fetch('port')}"
    end

    def worktree_ports
      data = state
      current_id = worktree_identity(repo_root)
      data.fetch("worktrees", {}).sort_by { |_id, record| record.fetch("path") }.each do |id, record|
        environments = record.fetch("environments", {})
        next if environments.empty?

        path = record.fetch("path")
        puts(id == current_id ? color("● #{path}", 32) : "○ #{path}")
        branches = environments.sort_by { |ref, _entry| [ref == record["current"] ? 0 : 1, ref] }
        branches.each_with_index do |(ref, entry), index|
          prefix = index == branches.length - 1 ? "  └─" : "  ├─"
          running = ref == record["current"] && entry["status"] == "running"
          unless running
            puts color("#{prefix} ○ #{ref}  #{entry.fetch('port')}", 90)
            next
          end

          puts "#{prefix} #{color("● #{ref}", 32)}  #{entry.fetch('port')}"
        end
      end
    end

    def worktree_port
      record, = current_worktree_entry(state)
      raise CLI::OperationError, "No Brunch environment in this worktree." unless record

      puts record.fetch("port")
    end

    def worktree_logs(arguments)
      _record, entry = current_worktree_entry(state)
      raise CLI::OperationError, "No Brunch environment in this worktree." unless entry

      worktree_manager(entry).logs(entry, *arguments)
    end

    def worktree_run(command)
      _record, entry = current_worktree_entry(state)
      raise CLI::OperationError, "No Brunch environment in this worktree." unless entry

      abort "Command failed: #{command.join(' ')}" unless system(worktree_manager(entry).environment(entry), *command,
                                                                 chdir: entry.fetch("snapshot"))
    end

    def worktree_doctor
      data = state
      ports = data.fetch("worktrees", {}).values.map { |record| record["port"] }
      paths = worktree_paths
      hooks_dir = git_output("rev-parse", "--git-path", "hooks")
      checks = {
        "Git worktree" => !worktree_identity(repo_root).empty?,
        "git-hooks-ext" => system("ghe", "--version", out: File::NULL, err: File::NULL),
        "Brunch hooks" => Hooks::EVENTS.all? do |event|
          path = File.join(hooks_dir, event)
          File.file?(path) && File.read(path).include?("Brunch::Hooks.dispatch")
        end,
        "Configuration" => !configuration.nil?,
        "Manager" => Managers.build(configuration).available?,
        "Unique ports" => ports.uniq.size == ports.size,
        "Port range" => ports.all? { |port| CLI::PORT_RANGE.cover?(port) },
        "Git worktree paths" => data.fetch("worktrees", {}).values.all? do |record|
          paths.include?(record.fetch("path"))
        end
      }
      checks.each { |name, passed| puts "#{passed ? 'OK' : 'FAIL'} #{name}" }
      abort "Brunch doctor found problems." unless checks.values.all?
    end
  end
end
