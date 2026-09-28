# frozen_string_literal: true

require_relative "lib/brunch/version"

Gem::Specification.new do |spec|
  spec.name = "brunch"
  spec.version = Brunch::VERSION
  spec.authors = ["Maciej Ciemborowicz"]
  spec.summary = "Isolated Docker Compose environments for Git branches"
  spec.description = "Brunch uses Git hooks and git-hooks-ext to run one isolated Docker Compose environment for the active branch."
  spec.homepage = "https://github.com/ciembor/brunch"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"
  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.glob("{lib,exe}/**/*") + %w[README.md LICENSE.txt CHANGELOG.md]
  spec.bindir = "exe"
  spec.executables = ["brunch"]
  spec.add_development_dependency "rake", "~> 13.0"
end
