# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "yaml"

module Brunch
  class CLI
    include WorktreeMode

    PORT_RANGE = (1024..49_151)
    CONFIGURATION_KEYS = %w[manager compose_file command commands preferred_port].freeze
    COMMAND_KEYS = %w[create start stop remove status health logs].freeze

    class ConfigurationError < StandardError; end
    class OperationError < StandardError; end

    def self.start(arguments) = new.start(arguments)

    def start(arguments)
      Dir.chdir(repo_root) unless Dir.pwd == repo_root
      case arguments
      in ["install"] then Hooks.install
      in ["version"] | ["--version"] | ["-v"] then puts Brunch::VERSION
      else
        unless %w[branch-deleted branch-settled].include?(arguments.first)
          reconcile_deleted_branches
          reconcile_missing_branches
        end
        return worktree_command(arguments)
      end
      0
    rescue ConfigurationError => e
      warn e.message
      64
    rescue OperationError => e
      warn e.message
      1
    end

    private

    def git_output(*arguments)
      output, status = Open3.capture2("git", *arguments)
      abort "Git command failed: git #{arguments.join(' ')}" unless status.success?

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
      return { "worktrees" => {} } unless File.file?(state_path)

      data = JSON.parse(File.read(state_path))
      raise ConfigurationError, "Invalid Brunch state: expected a JSON object." unless data.is_a?(Hash)
      if data.fetch("environments", {}).any? || data.key?("active_ref")
        raise ConfigurationError, "Legacy branch state found in .git/brunch/state.json; stop old environments before upgrading."
      end

      data
    rescue JSON::ParserError => e
      raise ConfigurationError, "Invalid Brunch state: #{e.message}"
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
      FileUtils.rm_f(temporary_path) if temporary_path
    end

    def configuration(root: repo_root)
      path = File.join(root, "brunch.yml")
      configured = File.file?(path) ? YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {} : {}
      validate_configuration!(configured)
      { "manager" => "docker_compose", "compose_file" => "compose.yaml", "preferred_port" => 3000 }.merge(configured)
    rescue Psych::Exception => e
      raise ConfigurationError, "Invalid brunch.yml: #{e.message}"
    end

    def validate_configuration!(configured)
      raise ConfigurationError, "brunch.yml must contain a mapping." unless configured.is_a?(Hash)

      unknown = configured.keys - CONFIGURATION_KEYS
      raise ConfigurationError, "Unknown brunch.yml key(s): #{unknown.join(', ')}." unless unknown.empty?

      value = { "manager" => "docker_compose", "compose_file" => "compose.yaml", "preferred_port" => 3000 }.merge(configured)
      unless %w[docker_compose podman_compose local_process command].include?(value["manager"])
        raise ConfigurationError, "Unknown Brunch manager: #{value['manager']}."
      end
      unless value["preferred_port"].is_a?(Integer) && PORT_RANGE.cover?(value["preferred_port"])
        raise ConfigurationError, "preferred_port must be a number from #{PORT_RANGE.begin} to #{PORT_RANGE.end}."
      end
      if %w[docker_compose podman_compose].include?(value["manager"]) && (!value["compose_file"].is_a?(String) || value["compose_file"].empty?)
        raise ConfigurationError, "compose_file must be a non-empty string."
      end
      if value["manager"] == "local_process" && (!value["command"].is_a?(String) || value["command"].empty?)
        raise ConfigurationError, "local_process manager requires a non-empty command."
      end
      return unless value["manager"] == "command"

      commands = value["commands"]
      raise ConfigurationError, "command manager requires a commands mapping." unless commands.is_a?(Hash)

      unknown = commands.keys - COMMAND_KEYS
      raise ConfigurationError, "Unknown commands key(s): #{unknown.join(', ')}." unless unknown.empty?

      %w[start stop remove].each do |action|
        raise ConfigurationError, "command manager requires commands.#{action}." unless commands[action].is_a?(String) && !commands[action].empty?
      end
      %w[create status health logs].each do |action|
        raise ConfigurationError, "commands.#{action} must be a string." if commands.key?(action) && !commands[action].is_a?(String)
      end
    end

    def preferred_port = configuration.fetch("preferred_port")

    def archive_ref(ref, destination)
      FileUtils.rm_rf(destination)
      FileUtils.mkdir_p(destination)
      environment = { "LC_ALL" => "C", "LANG" => "C" }
      statuses = Open3.pipeline([environment, "git", "archive", "--format=tar", ref],
                                [environment, "tar", "-x", "-C", destination])
      abort "Could not create a control copy for #{ref}." unless statuses.all?(&:success?)
    end

    def color(text, code)
      return text unless $stdout.tty?

      "\e[#{code}m#{text}\e[0m"
    end
  end
end
