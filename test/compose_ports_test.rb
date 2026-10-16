# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brunch"

class ComposePortsTest < Minitest::Test
  def test_extracts_and_rewrites_each_published_port
    document = {
      "services" => {
        "web" => { "ports" => [
          { "target" => 3000, "published" => "3000", "protocol" => "tcp", "host_ip" => "127.0.0.1" },
          { "target" => 5173, "published" => "5173", "protocol" => "tcp" }
        ] },
        "dns" => { "ports" => [{ "target" => 5353, "published" => "5353", "protocol" => "udp" }] }
      }
    }

    mappings = Brunch::ComposePorts.extract(document)
    actual = mappings.map { |mapping| mapping.values_at("service", "target", "protocol", "host_ip", "published") }
    assert_equal [["web", 3000, "tcp", "127.0.0.1", 3000], ["web", 5173, "tcp", "", 5173],
                  ["dns", 5353, "udp", "", 5353]], actual

    assignments = mappings.map.with_index { |mapping, index| mapping.merge("host" => 41_000 + index) }
    Brunch::ComposePorts.rewrite(document, assignments)
    ports = document.fetch("services").fetch("web").fetch("ports")
    assert_equal 41_000, ports[0].fetch("published")
    assert_equal 41_001, ports[1].fetch("published")
    assert_equal 41_002, document.fetch("services").fetch("dns").fetch("ports").first.fetch("published")
  end

  def test_rejects_unresolved_or_invalid_published_ports
    document = { "services" => { "web" => { "ports" => [{ "target" => 3000, "published" => "3000-3002" }] } } }
    error = assert_raises(Brunch::CLI::ConfigurationError) { Brunch::ComposePorts.extract(document) }
    assert_includes error.message, "Invalid published host port"
  end

  def test_validates_the_resolved_compose_shape_and_unsupported_port_values
    error = assert_raises(Brunch::CLI::ConfigurationError) { Brunch::ComposePorts.extract("services" => []) }
    assert_includes error.message, "services mapping"
    assert_empty Brunch::ComposePorts.extract("services" => { "ignored" => [], "web" => { "ports" => [{}] } })

    error = assert_raises(Brunch::CLI::ConfigurationError) do
      Brunch::ComposePorts.extract("services" => { "web" => { "ports" => ["3000:3000"] } })
    end
    assert_includes error.message, "Unsupported Compose port"
    error = assert_raises(Brunch::CLI::ConfigurationError) do
      Brunch::ComposePorts.extract("services" => { "web" => { "ports" => [{ "target" => 3000, "published" => 3000, "protocol" => "sctp" }] } })
    end
    assert_includes error.message, "Unsupported protocol"
    error = assert_raises(Brunch::CLI::ConfigurationError) do
      Brunch::ComposePorts.extract("services" => { "web" => { "ports" => [{ "target" => "no", "published" => 3000 }] } })
    end
    assert_includes error.message, "Invalid container port"
    error = assert_raises(Brunch::CLI::ConfigurationError) do
      Brunch::ComposePorts.extract("services" => { "web" => { "ports" => [{ "target" => 3000, "published" => 65_000 }] } })
    end
    assert_includes error.message, "Invalid published host port"
  end

  def test_rewrite_keeps_unpublished_ports_and_non_service_definitions
    document = { "services" => { "worker" => [], "web" => { "ports" => [{ "target" => 3000 }] } } }
    assert_equal document, Brunch::ComposePorts.rewrite(document, [])
  end
end
