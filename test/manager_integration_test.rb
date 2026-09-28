# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/brunch"

class ManagerIntegrationTest < Minitest::Test
  def test_compose_manager_lifecycle
    manager_name = ENV.fetch("BRUNCH_INTEGRATION_MANAGER") { skip "Set BRUNCH_INTEGRATION_MANAGER to run integration tests." }
    Dir.mktmpdir do |snapshot|
      File.write(File.join(snapshot, "compose.yaml"), <<~YAML)
        services:
          web:
            image: alpine:3.20
            command: sh -c 'sleep 30'
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
end
