# Changelog

## Unreleased

- Add pluggable environment managers. Docker Compose remains the default and a
  command-based manager supports other project-specific runtimes.
- Add an optional `create` lifecycle command for provisioning custom-manager
  environments before they start.

## 0.1.0 - 2026-09-28

- Initial public release.
- Isolated Docker Compose environments activated by Git branch checkout.
- `git-hooks-ext` integration and stale-environment cleanup.
