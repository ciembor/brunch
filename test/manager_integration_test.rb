# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/brunch"

class ManagerIntegrationTest < Minitest::Test
  def test_compose_manager_lifecycle
    manager_name = ENV.fetch("BRUNCH_INTEGRATION_MANAGER") { skip "Set BRUNCH_INTEGRATION_MANAGER to run integration tests." }
    Dir.mktmpdir do |directory|
      snapshot = File.join(directory, "snapshot")
      Dir.mkdir(snapshot)
      File.write(File.join(snapshot, "compose.yaml"), <<~YAML)
        services:
          web:
            image: alpine:3.20
            command: sh -c 'sleep 30'
            stop_grace_period: 1s
      YAML
      manager = Brunch::Managers.build("manager" => manager_name)
      skip "#{manager_name} is unavailable" unless manager.available?
      entry = { "ref" => "integration", "port" => 45_000, "project" => "brunch-integration-#{Process.pid}", "snapshot" => snapshot, "compose_file" => "compose.yaml" }

      assert manager.start(entry)
      assert manager.remove(entry)
    ensure
      manager&.remove(entry) if entry && File.exist?(snapshot)
    end
  end

  def test_compose_manager_removes_resources_after_worktree_disappears
    manager_name = ENV.fetch("BRUNCH_INTEGRATION_MANAGER") { skip "Set BRUNCH_INTEGRATION_MANAGER to run integration tests." }
    Dir.mktmpdir do |directory|
      source = File.join(directory, "worktree")
      control = File.join(directory, "control")
      FileUtils.mkdir_p([source, control])
      compose = <<~YAML
        services:
          web:
            image: alpine:3.20
            command: sh -c 'sleep 30'
            stop_grace_period: 1s
      YAML
      File.write(File.join(source, "compose.yaml"), compose)
      File.write(File.join(control, "compose.yaml"), compose)
      manager = Brunch::Managers.build("manager" => manager_name)
      skip "#{manager_name} is unavailable" unless manager.available?
      entry = { "source_type" => "worktree", "ref" => "integration", "port" => 45_001,
                "project" => "brunch-worktree-#{Process.pid}", "snapshot" => source,
                "control" => control, "compose_file" => "compose.yaml" }

      assert manager.start(entry)
      FileUtils.rm_rf(source)
      assert manager.remove(entry)
      refute_path_exists control
    ensure
      manager&.remove(entry) if entry && File.exist?(control)
    end
  end
end
