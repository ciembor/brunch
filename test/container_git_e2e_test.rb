# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "net/http"
require "open3"
require "socket"
require "tmpdir"
require_relative "../lib/brunch"

class ContainerGitE2ETest < Minitest::Test
  EXECUTABLE = File.expand_path("../exe/brunch", __dir__)
  HTTP_TIMEOUT = 20

  def setup
    @manager_name = ENV.fetch("BRUNCH_INTEGRATION_MANAGER", nil)
    skip "Set BRUNCH_INTEGRATION_MANAGER to run container E2E tests." unless @manager_name

    manager = Brunch::Managers.build("manager" => @manager_name)
    assert manager.available?, "#{@manager_name} is unavailable"
  end

  def test_branch_switch_serves_each_commit_on_the_same_port
    with_repository do |main, _directory|
      port = free_port
      File.write(File.join(main, "brunch.yml"), configuration(port))
      commit_fixture(main)
      run_git(main, "switch", "--quiet", "-c", "feature")
      File.write(File.join(main, "index.html"), "feature\n")
      run_git(main, "add", "index.html")
      run_git(main, "commit", "--quiet", "-m", "feature page")
      run_git(main, "switch", "--quiet", "main")

      run_cli(main, "activate")
      assert_equal port.to_s, run_cli(main, "port")
      assert_equal port.to_s, run_cli(main, "run", "--", Gem.ruby, "-e", "print ENV.fetch('BRUNCH_PORT')")
      assert_http(port, "main\n")

      run_git(main, "switch", "--quiet", "feature")
      run_cli(main, "activate")
      assert_equal port.to_s, run_cli(main, "port")
      assert_http(port, "feature\n")
      assert_includes run_cli(main, "status"), "feature (#{File.realpath(main)}): running"
      record = state(main).fetch("worktrees").values.first
      assert_equal "stopped", record.fetch("environments").fetch("main").fetch("status")

      run_cli(main, "stop")
      assert_unreachable(port)
    end
  end

  def test_switch_back_keeps_the_same_container_and_its_writable_files
    with_repository do |main, _directory|
      commit_fixture(main)
      run_cli(main, "activate")
      main_entry = state(main).fetch("worktrees").values.first.fetch("environments").fetch("main")
      project = main_entry.fetch("project")
      original_id = container_id(project)
      run_container("exec", original_id, "sh", "-c", "echo preserved > /tmp/brunch-persistence")

      run_git(main, "switch", "--quiet", "-c", "feature")
      run_cli(main, "activate")
      run_git(main, "switch", "--quiet", "main")
      assert_includes run_cli(main, "activate"), "Resumed main"

      assert_equal original_id, container_id(project)
      assert_equal "preserved", run_container("exec", original_id, "cat", "/tmp/brunch-persistence")
    end
  end

  def test_parallel_worktrees_serve_independently_and_cleanup_removed_worktree
    with_repository do |main, directory|
      commit_fixture(main)
      feature = File.join(directory, "feature")
      run_git(main, "worktree", "add", "--quiet", "-b", "feature", feature)
      File.write(File.join(feature, "index.html"), "feature\n")

      run_cli(main, "activate")
      run_cli(feature, "activate")
      main_port = Integer(run_cli(main, "port"))
      feature_port = Integer(run_cli(feature, "port"))
      refute_equal main_port, feature_port
      assert_includes run_cli(main, "ports"), "● main  #{main_port}"
      assert_includes run_cli(feature, "ports"), "● feature  #{feature_port}"
      assert_http(main_port, "main\n")
      assert_http(feature_port, "feature\n")

      File.write(File.join(feature, "index.html"), "feature changed\n")
      assert_http(feature_port, "feature changed\n")
      assert_http(main_port, "main\n")

      run_cli(feature, "stop")
      assert_unreachable(feature_port)
      assert_http(main_port, "main\n")

      run_git(main, "worktree", "remove", "--force", feature)
      run_cli(main, "cleanup")
      assert_equal 1, state(main).fetch("worktrees").size
      assert_http(main_port, "main\n")
    end
  end

  def test_git_checkout_hook_automatically_switches_live_container
    skip "git-hooks-ext is unavailable" unless system("ghe", "--version", out: File::NULL, err: File::NULL)

    with_repository do |main, _directory|
      port = free_port
      File.write(File.join(main, "brunch.yml"), configuration(port))
      File.write(File.join(main, "Gemfile"), "source 'https://rubygems.org'\n")
      commit_fixture(main)
      run_git(main, "switch", "--quiet", "-c", "feature")
      File.write(File.join(main, "index.html"), "feature\n")
      run_git(main, "add", "index.html")
      run_git(main, "commit", "--quiet", "-m", "feature page")
      run_git(main, "switch", "--quiet", "main")

      run_cli(main, "install")
      run_cli(main, "activate")
      assert_http(port, "main\n")

      run_git(main, "switch", "--quiet", "feature")
      assert_equal "feature", state(main).fetch("worktrees").values.first.fetch("current")
      assert_http(port, "feature\n")
    end
  end

  private

  def with_repository
    Dir.mktmpdir("brunch-container-e2e") do |directory|
      main = File.join(directory, "main")
      Dir.mkdir(main)
      run_git(main, "init", "--quiet", "-b", "main")
      run_git(main, "config", "user.email", "e2e@example.com")
      run_git(main, "config", "user.name", "Brunch E2E")
      File.write(File.join(main, "brunch.yml"), configuration)
      File.write(File.join(main, "compose.yaml"), compose_file)
      File.write(File.join(main, "index.html"), "main\n")
      yield main, directory
    ensure
      remove_test_containers(main) if main
    end
  end

  def configuration(port = nil)
    lines = ["manager: #{@manager_name}"]
    lines << "preferred_port: #{port}" if port
    "#{lines.join("\n")}\n"
  end

  def compose_file
    <<~YAML
      services:
        web:
          image: busybox:1.36
          command: sh -c 'httpd -f -p 3000 -h /site'
          volumes:
            - .:/site:ro
          ports:
            - "127.0.0.1:${BRUNCH_PORT}:3000"
          stop_grace_period: 1s
    YAML
  end

  def commit_fixture(main)
    run_git(main, "add", ".")
    run_git(main, "commit", "--quiet", "-m", "initial")
  end

  def run_git(directory, *arguments)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments)
    assert status.success?, "git #{arguments.join(' ')} failed: #{output}#{error}"
    output.force_encoding(Encoding::UTF_8).strip
  end

  def run_cli(directory, *arguments)
    output, error, status = Open3.capture3(Gem.ruby, EXECUTABLE, *arguments, chdir: directory)
    assert status.success?, "brunch #{arguments.join(' ')} failed: #{output}#{error}"
    output.force_encoding(Encoding::UTF_8).strip
  end

  def run_container(*arguments)
    output, error, status = Open3.capture3(@manager_name == "podman_compose" ? "podman" : "docker", *arguments)
    assert status.success?, "#{arguments.join(' ')} failed: #{output}#{error}"
    output.strip
  end

  def container_id(project)
    id = run_container("ps", "--filter", "label=com.docker.compose.project=#{project}", "--quiet")
    refute_empty id
    id
  end

  def state(main)
    JSON.parse(File.read(File.join(main, ".git", "brunch", "state.json")))
  end

  def free_port
    100.times do
      port = rand(20_000..40_000)
      begin
        server = TCPServer.new("127.0.0.1", port)
        server.close
        return port
      rescue Errno::EADDRINUSE
        next
      end
    end
    raise "Could not find a free test port"
  end

  def assert_http(port, expected)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HTTP_TIMEOUT
    observation = "no response"
    loop do
      begin
        response = Net::HTTP.start("127.0.0.1", port, nil, nil, open_timeout: 1, read_timeout: 1) { |http| http.get("/") }
        return assert_equal expected, response.body if response.code == "200" && response.body == expected

        observation = "HTTP #{response.code}: #{response.body.inspect}"
      rescue IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
        observation = "#{e.class}: #{e.message}"
      end
      raise "No HTTP response matching #{expected.inspect} on port #{port}; last #{observation}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.2
    end
  end

  def assert_unreachable(port)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HTTP_TIMEOUT
    loop do
      socket = TCPSocket.new("127.0.0.1", port)
      socket.close
      raise "Port #{port} remained reachable" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.2
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
      return
    end
  end

  def remove_test_containers(main)
    return unless File.file?(File.join(main, ".git", "brunch", "state.json"))

    data = state(main)
    entries = data.fetch("worktrees", {}).values.flat_map { |record| record.fetch("environments", {}).values }
    entries << data["pending"] if data["pending"]
    manager = Brunch::Managers.build("manager" => @manager_name)
    entries.uniq { |entry| entry.fetch("project") }.each { |entry| manager.remove(entry) }
  end
end
