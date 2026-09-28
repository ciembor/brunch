# frozen_string_literal: true

require "fileutils"
require "open3"
require "socket"

module Brunch
  module Managers
    class Base
      def initialize(configuration)
        @configuration = configuration
      end

      def available? = true

      def create(_entry) = true

      def port_available?(port)
        socket = TCPSocket.new("127.0.0.1", port)
        socket.close
        false
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH
        true
      end

      def stop(_entry); end

      def status(_entry) = "unknown"

      def healthy?(_entry) = nil

      def logs(_entry)
        warn "Logs are not supported by this manager."
        false
      end

      def reset(entry)
        stop(entry)
        FileUtils.rm_rf(entry.fetch("snapshot"))
      end

      def remove(entry)
        stop(entry)
        FileUtils.rm_rf(entry.fetch("snapshot"))
        true
      end
    end

    class DockerCompose < Base
      def available?
        system("docker", "info", out: File::NULL, err: File::NULL)
      end

      def start(entry) = compose(entry, "up", "--detach", "--build", "--remove-orphans")

      def status(entry)
        return "unavailable" unless available?
        healthy?(entry) ? "running" : "stopped"
      end

      def healthy?(entry)
        return false unless available?
        output, status = Open3.capture2(*compose_command(entry, "ps", "--status", "running", "--quiet"))
        status.success? && !output.strip.empty?
      end

      def logs(entry) = compose(entry, "logs", "--tail", "100")

      def port_available?(port)
        ports, = Open3.capture2(*ports_command)
        return false if ports.match?(/:#{port}->/)

        super
      end

      def stop(entry)
        compose(entry, "stop") if available?
      end

      def reset(entry)
        compose(entry, "down", "--remove-orphans") if available?
        FileUtils.rm_rf(entry.fetch("snapshot"))
      end

      def remove(entry)
        return false unless available? && compose(entry, "down", "--volumes", "--remove-orphans")
        FileUtils.rm_rf(entry.fetch("snapshot"))
        true
      end

      private

      def compose_command(entry, *arguments)
        compose_file = File.join(entry.fetch("snapshot"), entry.fetch("compose_file"))
        ["docker", "compose", "--project-name", entry.fetch("project"), "--project-directory", entry.fetch("snapshot"), "--file", compose_file, *arguments]
      end

      def ports_command = ["docker", "ps", "--format", "{{.Ports}}"]

      def compose(entry, *arguments)
        system({ "BRUNCH_PORT" => entry.fetch("port").to_s }, *compose_command(entry, *arguments))
      end
    end

    class PodmanCompose < DockerCompose
      def available?
        system("podman", "info", out: File::NULL, err: File::NULL)
      end

      private

      def compose_command(entry, *arguments)
        compose_file = File.join(entry.fetch("snapshot"), entry.fetch("compose_file"))
        ["podman", "compose", "--project-name", entry.fetch("project"), "--project-directory", entry.fetch("snapshot"), "--file", compose_file, *arguments]
      end

      def ports_command = ["podman", "ps", "--format", "{{.Ports}}"]

      def compose(entry, *arguments)
        system({ "BRUNCH_PORT" => entry.fetch("port").to_s }, *compose_command(entry, *arguments))
      end
    end

    class LocalProcess < Base
      def start(entry)
        log_path = File.join(entry.fetch("snapshot"), ".brunch.log")
        entry["pid"] = Process.spawn(environment(entry), "sh", "-lc", @configuration.fetch("command"), chdir: entry.fetch("snapshot"), out: [log_path, "a"], err: [log_path, "a"], pgroup: true)
        entry["log_path"] = log_path
        Process.detach(entry.fetch("pid"))
        true
      end

      def stop(entry)
        pid = entry["pid"]
        return true unless pid
        Process.kill("TERM", -pid)
        true
      rescue Errno::ESRCH
        true
      end

      def status(entry) = running?(entry) ? "running" : "stopped"
      def healthy?(entry) = running?(entry)

      def logs(entry)
        path = entry["log_path"]
        return super unless path && File.file?(path)
        puts File.readlines(path).last(100)
        true
      end

      private

      def running?(entry)
        Process.kill(0, entry.fetch("pid"))
        true
      rescue Errno::ESRCH
        false
      end

      def environment(entry)
        {
          "BRUNCH_REF" => entry.fetch("ref", ""),
          "BRUNCH_PORT" => entry.fetch("port").to_s,
          "BRUNCH_PROJECT" => entry.fetch("project"),
          "BRUNCH_SNAPSHOT" => entry.fetch("snapshot")
        }
      end
    end

    # Runs project-provided commands, making Brunch compatible with tools such
    # as Podman, Kubernetes wrappers, Foreman, or custom process supervisors.
    class Command < Base
      def create(entry) = run("create", entry, optional: true)
      def start(entry) = run("start", entry)
      def stop(entry) = run("stop", entry)
      def remove(entry)
        run("remove", entry) && super
      end

      def status(entry)
        command?("status") ? (run("status", entry) ? "running" : "stopped") : "unknown"
      end

      def healthy?(entry)
        return nil unless command?("health")
        run("health", entry)
      end

      def logs(entry)
        return super unless command?("logs")
        run("logs", entry)
      end

      private

      def run(action, entry, optional: false)
        command = @configuration.fetch("commands")[action]
        return true if optional && !command
        abort "Missing commands.#{action} for the command manager." unless command
        environment = {
          "BRUNCH_REF" => entry.fetch("ref", ""),
          "BRUNCH_PORT" => entry.fetch("port").to_s,
          "BRUNCH_PROJECT" => entry.fetch("project"),
          "BRUNCH_SNAPSHOT" => entry.fetch("snapshot")
        }
        system(environment, "sh", "-lc", command, chdir: entry.fetch("snapshot"))
      end

      def command?(action) = @configuration.fetch("commands").key?(action)
    end

    module_function

    def build(configuration)
      case configuration.fetch("manager")
      when "docker_compose" then DockerCompose.new(configuration)
      when "podman_compose" then PodmanCompose.new(configuration)
      when "local_process" then LocalProcess.new(configuration)
      when "command" then Command.new(configuration)
      else abort "Unknown Brunch manager: #{configuration.fetch("manager")}."
      end
    end
  end
end
