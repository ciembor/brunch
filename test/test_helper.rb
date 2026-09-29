# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :line
  enable_coverage :branch
  primary_coverage :line
  minimum_coverage line: 100, branch: 100
  add_filter "/test/"
  track_files "lib/**/*.rb"
end

require "minitest/autorun"
