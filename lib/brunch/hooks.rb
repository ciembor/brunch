# frozen_string_literal: true

require "fileutils"
require "open3"

module Brunch
  module Hooks
    EVENTS = %w[branch-created remote-branch-created remote-branch-updated post-checkout worktree-created
                worktree-removed worktree-moved worktree-pruned worktree-repaired].freeze

    module_function

    def install
      abort "git-hooks-ext must be installed before running this command." unless system("ghe", "--version",
                                                                                         out: File::NULL, err: File::NULL)
      abort "Could not install the git-hooks-ext bridge." unless system("ghe", "install")

      hooks_dir = git_output("rev-parse", "--git-path", "hooks")
      EVENTS.each { |event| install_hook(File.join(hooks_dir, event), event) }
      puts "Brunch hooks are installed."
    end

    def dispatch(event, arguments)
      case event
      when "post-checkout"
        CLI.start(["activate"]) if arguments.fetch(2, "0") == "1"
      when "branch-created", "remote-branch-created", "remote-branch-updated"
        CLI.start(["register", arguments.fetch(0)])
      when "worktree-created", "worktree-removed", "worktree-moved", "worktree-pruned", "worktree-repaired"
        CLI.start(["worktree-event", event, *arguments])
      else
        abort "Unknown hook event: #{event}"
      end
    end

    def git_output(*arguments)
      output, status = Open3.capture2("git", *arguments)
      abort "Git command failed: git #{arguments.join(' ')}" unless status.success?

      output.strip
    end
    private_class_method :git_output

    def install_hook(path, event)
      contents = hook_contents(event)
      abort "Refusing to replace existing hook: #{path}" if File.exist?(path) && File.read(path) != contents && !brunch_hook?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      FileUtils.chmod(0o755, path)
    end
    private_class_method :install_hook

    def brunch_hook?(path)
      contents = File.read(path)
      contents.include?("require \"brunch\"") && contents.include?("Brunch::Hooks.dispatch")
    end
    private_class_method :brunch_hook?

    def hook_contents(event)
      library_path = File.expand_path("../brunch.rb", __dir__)
      <<~RUBY
        #!#{Gem.ruby}
        # frozen_string_literal: true

        repo_root = `git rev-parse --show-toplevel`.strip
        gemfile = File.join(repo_root, "Gemfile")
        bundled = false
        if File.file?(gemfile) && File.read(gemfile).match?(/gem[[:space:]]+["']brunch["']/)
          ENV["BUNDLE_GEMFILE"] = gemfile
          begin
            require "bundler/setup"
            bundled = true
          rescue LoadError, StandardError
            ENV.delete("BUNDLE_GEMFILE")
          end
        end

        if !bundled && File.file?(gemfile)
          require #{library_path.inspect}
        else
          require "brunch"
        end
        Brunch::Hooks.dispatch(#{event.inspect}, ARGV)
      RUBY
    end
    private_class_method :hook_contents
  end
end
