# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/brunch"

class BrunchTest < Minitest::Test
  def test_has_a_version
    refute_empty Brunch::VERSION
  end

  def test_cli_reports_its_version
    output, = capture_io { assert_equal 0, Brunch::CLI.start(["version"]) }

    assert_equal "#{Brunch::VERSION}\n", output
  end
end
