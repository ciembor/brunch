# frozen_string_literal: true

require_relative "lib/brunch/version"

Gem::Specification.new do |spec|
  spec.name = "brunch"
  spec.version = Brunch::VERSION
  spec.authors = ["Maciej Ciemborowicz"]
  spec.summary = "Isolated development environments for Git branches and worktrees"
  spec.description = "Brunch uses Git hooks and git-hooks-ext to run isolated branch or parallel worktree environments through Docker Compose or custom managers."
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
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
