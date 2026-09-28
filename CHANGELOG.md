# Changelog

## 0.4.1 - 2026-09-28

- Strengthen `doctor` hook and port validation.

## 0.4.0 - 2026-09-28

- Add `doctor`, `exec`, and argument forwarding for `logs`.
- Serialize commands with a repository-local lock, save state atomically, and
  recover interrupted environment setup on the next activation.
- Add conditional Docker Compose and Podman Compose integration tests to CI.

## 0.3.0 - 2026-09-28

- Add a native `local_process` manager for `bin/dev`-style commands, with PID
  tracking, process-group shutdown, and snapshot-local logs.

## 0.2.0 - 2026-09-28

- Add pluggable environment managers. Docker Compose remains the default and a
  command-based manager supports other project-specific runtimes.
- Add an optional `create` lifecycle command for provisioning custom-manager
  environments before they start.
- Add the Podman Compose manager, configurable `switch_only` and `active_only`
  lifecycle modes, and `status`, `stop`, `restart`, and `logs` commands.
- Validate `brunch.yml` and expose manager status and health checks.

## 0.1.0 - 2026-09-28

- Initial public release.
- Isolated Docker Compose environments activated by Git branch checkout.
- `git-hooks-ext` integration and stale-environment cleanup.
