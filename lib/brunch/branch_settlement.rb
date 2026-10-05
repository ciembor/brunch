# frozen_string_literal: true

require "open3"
require "securerandom"

module Brunch
  module BranchSettlement
    module_function

    def git_ancestor(pid = Process.ppid)
      32.times do
        process = process_info(pid)
        break unless process

        return { "pid" => pid, "started" => process.fetch(:started) } if File.basename(process.fetch(:command)) == "git"

        pid = process.fetch(:parent)
        break if pid <= 1
      end
      nil
    end

    def running?(identity)
      return false unless identity.is_a?(Hash) && identity["pid"].is_a?(Integer) && identity["started"].is_a?(String)

      process = process_info(identity.fetch("pid"))
      return process_exists?(identity.fetch("pid")) unless process

      process.fetch(:started) == identity.fetch("started") && !process.fetch(:state).start_with?("Z")
    end

    def process_exists?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def token = SecureRandom.hex(16)

    def spawn_worker(root, ref, token)
      executable = File.expand_path("../../exe/brunch", __dir__)
      pid = Process.spawn(Gem.ruby, executable, "branch-settled", ref, token,
                          chdir: root, in: File::NULL, out: File::NULL, err: File::NULL,
                          pgroup: true, close_others: true)
      Process.detach(pid)
    end

    def wait_for(identity)
      sleep 0.1 while running?(identity)
    end

    def process_info(pid)
      output, status = Open3.capture2("ps", "-p", pid.to_s, "-o", "ppid=,lstart=,stat=,comm=", err: File::NULL)
      return unless status.success?

      fields = output.strip.split(/\s+/, 8)
      return unless fields.length == 8 && fields[0].match?(/\A\d+\z/)

      { parent: fields[0].to_i, started: fields[1, 5].join(" "), state: fields[6], command: fields[7] }
    rescue Errno::ENOENT
      nil
    end
  end
end
