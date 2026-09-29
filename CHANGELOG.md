# Changelog

## Unreleased

- Use one worktree-based lifecycle for both branch switches and parallel
  worktrees. Branches within a worktree reuse its port; separate worktrees
  receive distinct host ports.
- Run applications from the live worktree and replace mode-specific port
  settings with an optional `preferred_port`.

## 0.7.1 - 2026-09-29

- Use a compatible Podman Compose provider and CLI arguments in integration
  tests and at runtime.

## 0.7.0 - 2026-09-29

- Add parallel worktree mode with per-worktree ports, live source directories,
  isolated projects and volumes, and branch-specific environments.
- Handle git-hooks-ext worktree create, remove, move, prune, and repair events;
  reconcile plain Git worktree operations during cleanup.
- Preserve control files for teardown after a worktree disappears, and use
  short repository locks plus per-worktree lifecycle locks.

## 0.6.0 - 2026-09-29

- Add shared and unique port modes; shared port `3000` is now the default.

## 0.5.0 - 2026-09-28

- Add `ports` and script-friendly `port` commands.

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
