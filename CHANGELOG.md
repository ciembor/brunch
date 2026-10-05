# Changelog

## 0.9.2 - 2026-10-05

- Settle branch deletions automatically after the Git process exits, preserving
  environments across `git branch -m` without requiring another Brunch command.
  Handle `git branch -M` when the destination already has an environment, and
  keep pending state if the background worker cannot start.

## 0.9.1 - 2026-10-03

- Replace `brunch ports` with `brunch list` and add `brunch watch` for a
  continuously refreshed interactive view of branch environments.

## 0.9.0 - 2026-10-02

- Remove environments for deleted local branches after the next Brunch command,
  while preserving them across branch renames, including reftable renames that
  do not emit a deletion event. Run `brunch install` again to install the new
  `branch-deleted` hook.
- Keep the same Compose project and named volumes when restarting after a branch rename.
- Exercise the config-based git-hooks-ext bridge with Git 2.55 in CI.

## 0.8.4 - 2026-10-01

- Test against git-hooks-ext 0.6.0 in CI and clarify bridge upgrades and
  worktree Git requirements.
- Document a minimal Rails setup and update the Brunch artwork.

## 0.8.3 - 2026-09-29

- Detect containers that exit immediately after a Compose resume and report the
  failure instead of claiming the branch environment is running.
- Retry activation when a recorded running environment has actually stopped.

## 0.8.2 - 2026-09-29

- Resume stopped branch containers without rebuilding or replacing them when
  switching back, preserving files in their writable layers.
- Group `brunch ports` by worktree and show stopped branch environments in gray.

## 0.8.1 - 2026-09-29

- Reorganize the README into a step-by-step guide for branches, parallel
  worktrees, managers, and everyday commands.

## 0.8.0 - 2026-09-29

- Use one worktree-based lifecycle for both branch switches and parallel
  worktrees. Branches within a worktree reuse its port; separate worktrees
  receive distinct host ports.
- Run applications from the live worktree and replace mode-specific port
  settings with an optional `preferred_port`.
- Document installation and everyday use, and add a compact illustration to
  the README.
- Make CI lint only project files, install the `ghe` alias, and initialize the
  test repository on `main`.
- Detect running Podman Compose containers by their project label.

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
