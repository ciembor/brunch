# frozen_string_literal: true

require "rake/testtask"

def run_quality_command(*command)
  abort "Quality check failed: #{command.join(' ')}" unless system(*command)
end

Rake::TestTask.new(:test) do |task|
  task.libs << "lib"
  task.pattern = "test/**/*_test.rb"
end

task default: :test

namespace :quality do
  task :lint do
    run_quality_command "bundle", "exec", "rubocop", "lib", "exe", "test", "Rakefile"
  end

  task :reek do
    run_quality_command "bundle", "exec", "reek", "lib"
  end

  task coverage: :test
end

task quality: %w[quality:lint quality:reek quality:coverage]
