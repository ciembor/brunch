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

      def port_available?(port)
        ports, = Open3.capture2("docker", "ps", "--format", "{{.Ports}}")
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

      def compose(entry, *arguments)
        compose_file = File.join(entry.fetch("snapshot"), entry.fetch("compose_file"))
        system({ "BRUNCH_PORT" => entry.fetch("port").to_s }, "docker", "compose", "--project-name", entry.fetch("project"), "--project-directory", entry.fetch("snapshot"), "--file", compose_file, *arguments)
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
    end

    module_function

    def build(configuration)
      case configuration.fetch("manager")
      when "docker_compose" then DockerCompose.new(configuration)
      when "command" then Command.new(configuration)
      else abort "Unknown Brunch manager: #{configuration.fetch("manager")}."
      end
    end
  end
end
