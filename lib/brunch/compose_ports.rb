# frozen_string_literal: true

module Brunch
  # Reads the resolved Compose model produced by `compose config` and changes
  # only published host ports. Keeping this separate from the source YAML lets
  # Brunch use existing Compose projects without asking them to add variables.
  module ComposePorts
    module_function

    def extract(document)
      services = document.fetch("services", {})
      raise CLI::ConfigurationError, "Compose config must contain a services mapping." unless services.is_a?(Hash)

      services.flat_map do |service, definition|
        next [] unless definition.is_a?(Hash)

        Array(definition["ports"]).filter_map do |port|
          published_mapping(service, port)
        end
      end
    end

    def rewrite(document, assignments)
      indexed = assignments.to_h { |assignment| [key(assignment), assignment.fetch("host")] }
      document.fetch("services", {}).each do |service, definition|
        next unless definition.is_a?(Hash)

        definition["ports"] = Array(definition["ports"]).map do |port|
          mapping = published_mapping(service, port)
          next port unless mapping

          rewrite_port(port, mapping, indexed.fetch(key(mapping)))
        end
      end
      document
    end

    def key(mapping)
      [mapping.fetch("service"), mapping.fetch("target"), mapping.fetch("protocol"), mapping.fetch("host_ip")]
    end

    def published_mapping(service, port)
      return short_mapping(service, port) if port.is_a?(String)

      raise CLI::ConfigurationError, "Unsupported Compose port for #{service}." unless port.is_a?(Hash)
      return unless port.key?("published") && !port["published"].to_s.empty?

      published = integer(port["published"], "published host port for #{service}")
      target = integer(port["target"], "container port for #{service}")
      protocol = port.fetch("protocol", "tcp")
      raise CLI::ConfigurationError, "Unsupported protocol #{protocol.inspect} for #{service}." unless %w[tcp udp].include?(protocol)

      { "service" => service.to_s, "target" => target, "protocol" => protocol,
        "host_ip" => port.fetch("host_ip", "").to_s, "published" => published }
    end
    private_class_method :published_mapping

    def rewrite_port(port, mapping, host)
      return port.merge("published" => host) if port.is_a?(Hash)

      value = [mapping.fetch("host_ip"), host, mapping.fetch("target")].reject { |part| part == "" }.join(":")
      mapping.fetch("protocol") == "tcp" ? value : "#{value}/#{mapping.fetch('protocol')}"
    end
    private_class_method :rewrite_port

    def short_mapping(service, port)
      value, protocol = port.split("/", 2)
      parts = value.split(":")
      raise CLI::ConfigurationError, "Unsupported Compose port for #{service}: #{port.inspect}." unless (2..3).cover?(parts.length)

      target = integer(parts.pop, "container port for #{service}")
      published = integer(parts.pop, "published host port for #{service}")
      host_ip = parts.pop.to_s
      normalized_protocol = protocol || "tcp"
      raise CLI::ConfigurationError, "Unsupported protocol #{normalized_protocol.inspect} for #{service}." unless %w[tcp udp].include?(normalized_protocol)

      { "service" => service.to_s, "target" => target, "protocol" => normalized_protocol,
        "host_ip" => host_ip, "published" => published }
    end
    private_class_method :short_mapping

    def integer(value, description)
      Integer(value).tap do |port|
        raise CLI::ConfigurationError, "Invalid #{description}: #{value.inspect}." unless CLI::PORT_RANGE.cover?(port)
      end
    rescue ArgumentError, TypeError
      raise CLI::ConfigurationError, "Invalid #{description}: #{value.inspect}."
    end
    private_class_method :integer
  end
end
