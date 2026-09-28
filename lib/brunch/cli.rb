# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "yaml"

module Brunch
  class CLI
    PORT_RANGE = (1024..49_151)
    class ConfigurationError < StandardError; end

    class << self
      def start(arguments)
        new.start(arguments)
      end
    end

    def start(arguments)
      Dir.chdir(repo_root)
      lock = acquire_lock
      return 75 unless lock

      case arguments
      in ["activate"] then activate
      in ["start", ref] then start_environment(ref, state)
      in ["stop"] then stop_active_environment(state)
      in ["restart"] then restart_active_environment(state)
      in ["status"] then show_status(state)
      in ["logs", *log_arguments] then show_logs(state, log_arguments)
      in ["exec", "--", *command] if !command.empty? then execute_active_environment(state, command)
      in ["doctor"] then doctor(state)
      in ["cleanup"] then cleanup(state)
      in ["register", _ref] then cleanup(state)
      in ["install"] then Hooks.install
      in ["version"] | ["--version"] | ["-v"] then puts Brunch::VERSION
      else
        warn "Usage: brunch {install|activate|start <ref>|stop|restart|status|logs [args]|exec -- <cmd>|doctor|cleanup|register <ref>|version}"
        return 64
      end

      0
    rescue ConfigurationError => error
      warn error.message
      64
    ensure
      release_lock(lock) if defined?(lock) && lock
    end

    private

    def acquire_lock
      FileUtils.mkdir_p(state_root)
      lock = File.open(File.join(state_root, "lock"), "w")
      return lock if lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.close
      warn "Another Brunch command is already running."
      nil
    end

    def release_lock(lock)
      lock.flock(File::LOCK_UN)
      lock.close
    end

    def git_output(*arguments)
      output, status = Open3.capture2("git", *arguments)
      abort "Git command failed: git #{arguments.join(" ")}" unless status.success?
      output.strip
    end

    def repo_root
      @repo_root ||= git_output("rev-parse", "--show-toplevel")
    end

    def state_root
      common_dir = git_output("rev-parse", "--git-common-dir")
      @state_root ||= File.join(File.expand_path(common_dir, repo_root), "brunch")
    end

    def state_path = File.join(state_root, "state.json")

    def state
      return { "environments" => {} } unless File.file?(state_path)
      JSON.parse(File.read(state_path))
    end

    def save_state(value)
      FileUtils.mkdir_p(state_root)
      temporary_path = "#{state_path}.#{Process.pid}.tmp"
      File.open(temporary_path, "w", 0o600) do |file|
        file.write(JSON.pretty_generate(value))
        file.flush
        file.fsync
      end
      File.rename(temporary_path, state_path)
    ensure
      FileUtils.rm_f(temporary_path) if defined?(temporary_path)
    end

    def configuration
      path = File.join(repo_root, "brunch.yml")
      value = { "manager" => "docker_compose", "compose_file" => "compose.yaml", "lifecycle" => "switch_only" }
      value.merge!(YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}) if File.file?(path)
      validate_configuration!(value)
      value
    end

    def manager = Managers.build(configuration)

    def validate_configuration!(value)
      abort "brunch.yml must contain a mapping." unless value.is_a?(Hash)
      abort "Unknown Brunch manager: #{value["manager"]}." unless %w[docker_compose podman_compose local_process command].include?(value["manager"])
      abort "Unknown Brunch lifecycle: #{value["lifecycle"]}." unless %w[switch_only active_only].include?(value["lifecycle"])
      if %w[docker_compose podman_compose].include?(value["manager"]) && (!value["compose_file"].is_a?(String) || value["compose_file"].empty?)
        abort "compose_file must be a non-empty string."
      end
      if value["manager"] == "local_process" && (!value["command"].is_a?(String) || value["command"].empty?)
        abort "local_process manager requires a non-empty command."
      end
      return unless value["manager"] == "command"

      commands = value["commands"]
      abort "command manager requires a commands mapping." unless commands.is_a?(Hash)
      %w[start stop remove].each { |action| abort "command manager requires commands.#{action}." unless commands[action].is_a?(String) && !commands[action].empty? }
      %w[create status health logs].each { |action| abort "commands.#{action} must be a string." if commands.key?(action) && !commands[action].is_a?(String) }
    end

    def cksum(value)
      table = @cksum_table ||= Array.new(256) do |index|
        crc = index << 24
        8.times { crc = (crc & 0x8000_0000).zero? ? crc << 1 : (crc << 1) ^ 0x04c1_1db7 }
        crc & 0xffff_ffff
      end
      crc = value.bytes.reduce(0) { |result, byte| ((result << 8) ^ table[((result >> 24) ^ byte) & 0xff]) & 0xffff_ffff }
      length = value.bytesize
      while length.positive?
        crc = ((crc << 8) ^ table[((crc >> 24) ^ (length & 0xff)) & 0xff]) & 0xffff_ffff
        length >>= 8
      end
      (~crc) & 0xffff_ffff
    end

    def identifier(ref) = "#{ref.downcase.gsub(/[^a-z0-9]+/, "-")}-#{cksum(ref)}"
    def preferred_port(ref) = PORT_RANGE.begin + (cksum(ref) % PORT_RANGE.size)
    def port_available?(port)
      manager.port_available?(port)
    end

    def choose_port(ref, saved_port)
      preferred = saved_port || preferred_port(ref)
      return preferred if port_available?(preferred)
      suggested = (preferred + 1..PORT_RANGE.end).find { |port| port_available?(port) } || PORT_RANGE.find { |port| port_available?(port) }
      return nil unless suggested
      tty = File.open("/dev/tty", "r+")
      loop do
        tty.print "Port #{preferred} is in use for #{ref}. Enter a port (#{PORT_RANGE.begin}-#{PORT_RANGE.end}) or press Enter for #{suggested}: "
        answer = tty.gets
        return nil unless answer
        selected = answer.strip.empty? ? suggested : Integer(answer.strip, 10) rescue nil
        return selected if selected && PORT_RANGE.cover?(selected) && port_available?(selected)
        tty.puts "Choose a free numeric port from #{PORT_RANGE.begin} to #{PORT_RANGE.end}."
      end
    rescue Errno::ENOENT, Errno::ENXIO
      warn "Port #{preferred} is in use for #{ref}, but no interactive terminal is available."
      nil
    ensure
      tty&.close
    end

    def snapshot_path(ref) = File.join(state_root, "snapshots", identifier(ref))

    def archive_ref(ref, destination)
      FileUtils.rm_rf(destination)
      FileUtils.mkdir_p(destination)
      environment = { "LC_ALL" => "C", "LANG" => "C" }
      statuses = Open3.pipeline([environment, "git", "archive", "--format=tar", ref], [environment, "tar", "-x", "-C", destination])
      abort "Could not create a snapshot for #{ref}." unless statuses.all?(&:success?)
    end

    def ref_exists?(ref)
      system("git", "cat-file", "-e", "#{ref}^{commit}", out: File::NULL, err: File::NULL)
    end

    def cleanup(data)
      data.fetch("environments").dup.each do |ref, entry|
        next if ref_exists?(ref) || !manager.remove(entry)
        data.fetch("environments").delete(ref)
        puts "Removed environment for deleted ref #{ref}."
      end
      save_state(data)
    end

    def recover_pending_environment(data)
      pending = data.delete("pending")
      return unless pending
      manager.reset(pending)
      save_state(data)
      warn "Recovered interrupted environment setup for #{pending.fetch("ref", "unknown")}."
    end

    def active_entry(data)
      ref = data["active_ref"]
      return [nil, nil] unless ref && data.fetch("environments").key?(ref)
      [ref, data.fetch("environments").fetch(ref)]
    end

    def stop_active_environment(data)
      ref, entry = active_entry(data)
      return warn "No active Brunch environment." unless entry
      manager.stop(entry)
      puts "Stopped #{entry.fetch("project")} for #{ref}."
    end

    def restart_active_environment(data)
      ref, entry = active_entry(data)
      return warn "No active Brunch environment." unless entry
      manager.stop(entry)
      start_environment(ref, data)
    end

    def show_status(data)
      environments = data.fetch("environments")
      if environments.empty?
        puts "No Brunch environments."
        return
      end

      environments.each do |ref, entry|
        active = ref == data["active_ref"] ? "active" : "sleeping"
        health = manager.healthy?(entry)
        health_label = health.nil? ? "unknown" : health ? "healthy" : "unhealthy"
        port = entry.fetch("port")
        puts "#{ref} (#{active}): #{manager.status(entry)}, #{health_label}, http://127.0.0.1:#{port}"
      end
    end

    def show_logs(data, arguments)
      _ref, entry = active_entry(data)
      return warn "No active Brunch environment." unless entry
      manager.logs(entry, *arguments)
    end

    def execute_active_environment(data, command)
      _ref, entry = active_entry(data)
      return warn "No active Brunch environment." unless entry
      abort "Command failed: #{command.join(" ")}" unless system(manager.environment(entry), *command, chdir: entry.fetch("snapshot"))
    end

    def doctor(data)
      hooks_dir = git_output("rev-parse", "--git-path", "hooks")
      ports = data.fetch("environments").values.map { |entry| entry.fetch("port") }
      checks = {
        "Git repository" => !repo_root.empty?,
        "Git hooks" => Hooks::EVENTS.all? { |event| File.file?(File.join(hooks_dir, event)) },
        "Configuration" => !!configuration,
        "#{configuration.fetch("manager")} availability" => manager.available?,
        "Unique environment ports" => ports.uniq.size == ports.size
      }
      checks.each { |name, passed| puts "#{passed ? "OK" : "FAIL"} #{name}" }
      abort "Brunch doctor found problems." unless checks.values.all?
    end

    def start_environment(ref, data)
      return warn "#{configuration.fetch("manager")} is not available; skipped environment for #{ref}." unless manager.available?
      return warn "#{ref} does not resolve to a commit; skipped environment." unless ref_exists?(ref)
      existing = data.fetch("environments")[ref]
      port = choose_port(ref, existing&.fetch("port", nil))
      return warn "No port selected for #{ref}." unless port
      entry = { "ref" => ref, "project" => "brunch-#{identifier(ref)}", "port" => port, "snapshot" => snapshot_path(ref), "compose_file" => configuration.fetch("compose_file") }
      manager.reset(existing) if existing
      archive_ref(ref, entry.fetch("snapshot"))
      if %w[docker_compose podman_compose].include?(configuration.fetch("manager")) && !File.file?(File.join(entry.fetch("snapshot"), entry.fetch("compose_file")))
        abort "Missing #{entry.fetch("compose_file")} in #{ref}."
      end
      data["pending"] = entry
      save_state(data)
      abort "Could not create environment for #{ref}." unless manager.create(entry)
      abort "Could not start environment for #{ref}." unless manager.start(entry)
      data.fetch("environments")[ref] = entry
      data.delete("pending")
      save_state(data)
      puts "Started #{entry.fetch("project")} for #{ref} at http://127.0.0.1:#{port}"
    end

    def activate
      data = state
      recover_pending_environment(data)
      cleanup(data)
      current_ref = git_output("branch", "--show-current")
      return if current_ref.empty?
      previous_ref = data["active_ref"]
      if configuration.fetch("lifecycle") == "active_only"
        data.fetch("environments").each { |ref, entry| manager.stop(entry) if ref != current_ref }
      elsif previous_ref && previous_ref != current_ref && data.fetch("environments").key?(previous_ref)
        manager.stop(data.fetch("environments")[previous_ref])
      end
      start_environment(current_ref, data)
      data["active_ref"] = current_ref
      save_state(data)
    end
  end
end
