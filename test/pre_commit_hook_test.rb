# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

class PreCommitHookTest < Minitest::Test
  INSTALLER = File.expand_path("../bin/install-pre-commit", __dir__)

  def with_repository
    Dir.mktmpdir("brunch-pre-commit-test") do |directory|
      root = File.join(directory, "main")
      Dir.mkdir(root)
      git!(root, "init", "--quiet")
      git!(root, "config", "user.email", "test@example.com")
      git!(root, "config", "user.name", "Test")
      Dir.mkdir(File.join(root, "bin"))
      File.write(File.join(root, "bin", "pre-commit"), "#!/usr/bin/env bash\nset -euo pipefail\ntouch hook-ran\n")
      FileUtils.chmod(0o755, File.join(root, "bin", "pre-commit"))
      git!(root, "add", ".")
      git!(root, "commit", "--quiet", "-m", "initial")
      yield root, directory
    end
  end

  def git!(root, *arguments)
    output, error, status = Open3.capture3("git", "-C", root, *arguments)
    assert status.success?, "git #{arguments.join(' ')} failed: #{output}#{error}"
    output.strip
  end

  def test_installed_hook_uses_current_worktree_and_survives_another_worktree_removal
    with_repository do |root, directory|
      feature = File.join(directory, "feature")
      git!(root, "worktree", "add", "--quiet", "-b", "feature", feature)
      output, error, status = Open3.capture3("bash", INSTALLER, chdir: feature)
      assert status.success?, "#{output}#{error}"

      hook_path = git!(root, "rev-parse", "--git-path", "hooks/pre-commit")
      hook_path = File.expand_path(hook_path, root)
      refute File.symlink?(hook_path)
      assert_includes File.read(hook_path), 'repository_root="$(git rev-parse --show-toplevel)"'

      git!(feature, "commit", "--allow-empty", "--quiet", "-m", "feature")
      assert File.file?(File.join(feature, "hook-ran"))
      File.delete(File.join(feature, "hook-ran"))
      git!(root, "worktree", "remove", feature)

      git!(root, "commit", "--allow-empty", "--quiet", "-m", "main")
      assert File.file?(File.join(root, "hook-ran"))

      output, error, status = Open3.capture3("bash", INSTALLER, chdir: root)
      assert status.success?, "#{output}#{error}"
      assert_includes File.read(hook_path), "Brunch quality pre-commit hook"
    end
  end

  def test_installer_refuses_foreign_hook
    with_repository do |root, _directory|
      hook_path = File.join(root, ".git", "hooks", "pre-commit")
      File.write(hook_path, "#!/bin/sh\nexit 0\n")
      _output, error, status = Open3.capture3("bash", INSTALLER, chdir: root)
      refute status.success?
      assert_includes error, "Refusing to replace existing pre-commit hook"
      assert_equal "#!/bin/sh\nexit 0\n", File.read(hook_path)
    end
  end

  def test_installer_migrates_legacy_brunch_symlink
    with_repository do |root, _directory|
      hook_path = File.join(root, ".git", "hooks", "pre-commit")
      File.symlink(File.join(root, "bin", "pre-commit"), hook_path)
      output, error, status = Open3.capture3("bash", INSTALLER, chdir: root)
      assert status.success?, "#{output}#{error}"
      refute File.symlink?(hook_path)
      assert_includes File.read(hook_path), "Brunch quality pre-commit hook"
      git!(root, "commit", "--allow-empty", "--quiet", "-m", "migrated")
      assert File.file?(File.join(root, "hook-ran"))
    end
  end
end
