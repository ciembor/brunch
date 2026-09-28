# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "yaml"

module Brunch
  class CLI
    PORT_RANGE = (1024..49_151)

    class << self
      def start(arguments)
        new.start(arguments)
      end
    end

    def start(arguments)
      Dir.chdir(repo_root)

      case arguments
      in ["activate"] then activate
      in ["start", ref] then start_environment(ref, state)
      in ["cleanup"] then cleanup(state)
      in ["register", _ref] then cleanup(state)
      in ["install"] then Hooks.install
      in ["version"] | ["--version"] | ["-v"] then puts Brunch::VERSION
      else
        warn "Usage: brunch {install|activate|start <ref>|cleanup|register <ref>|version}"
        return 64
      end

      0
    end

    private

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
      File.write(state_path, JSON.pretty_generate(value))
    end

    def configuration
      path = File.join(repo_root, "brunch.yml")
      return { "compose_file" => "compose.yaml" } unless File.file?(path)
      { "compose_file" => YAML.safe_load_file(path, permitted_classes: [], aliases: false).fetch("compose_file", "compose.yaml") }
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
    def docker_running? = system("docker", "info", out: File::NULL, err: File::NULL)

    def port_available?(port)
      ports, = Open3.capture2("docker", "ps", "--format", "{{.Ports}}")
      return false if ports.match?(/:#{port}->/)
      socket = TCPSocket.new("127.0.0.1", port)
      socket.close
      false
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH
      true
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

    def compose(entry, *arguments)
      compose_file = File.join(entry.fetch("snapshot"), entry.fetch("compose_file"))
      system({ "BRUNCH_PORT" => entry.fetch("port").to_s }, "docker", "compose", "--project-name", entry.fetch("project"), "--project-directory", entry.fetch("snapshot"), "--file", compose_file, *arguments)
    end

    def stop(entry)
      compose(entry, "stop") if docker_running?
    end

    def remove(entry)
      return false unless docker_running? && compose(entry, "down", "--volumes", "--remove-orphans")
      FileUtils.rm_rf(entry.fetch("snapshot"))
      true
    end

    def replace(entry)
      compose(entry, "down", "--remove-orphans") if docker_running?
      FileUtils.rm_rf(entry.fetch("snapshot"))
    end

    def ref_exists?(ref)
      system("git", "cat-file", "-e", "#{ref}^{commit}", out: File::NULL, err: File::NULL)
    end

    def cleanup(data)
      data.fetch("environments").dup.each do |ref, entry|
        next if ref_exists?(ref) || !remove(entry)
        data.fetch("environments").delete(ref)
        puts "Removed environment for deleted ref #{ref}."
      end
      save_state(data)
    end

    def start_environment(ref, data)
      return warn "Docker is not running; skipped environment for #{ref}." unless docker_running?
      return warn "#{ref} does not resolve to a commit; skipped environment." unless ref_exists?(ref)
      existing = data.fetch("environments")[ref]
      port = choose_port(ref, existing&.fetch("port", nil))
      return warn "No port selected for #{ref}." unless port
      entry = { "project" => "brunch-#{identifier(ref)}", "port" => port, "snapshot" => snapshot_path(ref), "compose_file" => configuration.fetch("compose_file") }
      replace(existing) if existing
      archive_ref(ref, entry.fetch("snapshot"))
      abort "Missing #{entry.fetch("compose_file")} in #{ref}." unless File.file?(File.join(entry.fetch("snapshot"), entry.fetch("compose_file")))
      abort "Could not start environment for #{ref}." unless compose(entry, "up", "--detach", "--build", "--remove-orphans")
      data.fetch("environments")[ref] = entry
      save_state(data)
      puts "Started #{entry.fetch("project")} for #{ref} at http://127.0.0.1:#{port}"
    end

    def activate
      data = state
      cleanup(data)
      current_ref = git_output("branch", "--show-current")
      return if current_ref.empty?
      previous_ref = data["active_ref"]
      stop(data.fetch("environments")[previous_ref]) if previous_ref && previous_ref != current_ref && data.fetch("environments").key?(previous_ref)
      start_environment(current_ref, data)
      data["active_ref"] = current_ref
      save_state(data)
    end
  end
end
