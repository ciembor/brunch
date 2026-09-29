# Brunch

![Brunch — container per branch and worktree](brunch.webp)

Brunch runs isolated development environments for Git branches and worktrees.

Each branch gets its own environment. With Compose, that means a separate project, network, containers, and named volumes. Branches checked out in the same worktree share its host port, while additional worktrees get different ports and can run in parallel.

Docker Compose is the default manager. Podman Compose, local processes, and custom project commands are also supported.

## Requirements

- Ruby 3.1+
- Git 2.28+
- Docker Compose, Podman Compose, or another supported manager
- [git-hooks-ext](https://github.com/ciembor/git-hooks-ext)

## Installation

Install [git-hooks-ext](https://github.com/ciembor/git-hooks-ext) so that `ghe` is available on your `PATH`, then install Brunch:

```bash
gem install brunch
```

Inside each repository you want Brunch to manage:

```bash
brunch install
```

Brunch installs its hooks through `git-hooks-ext` and will not overwrite hooks owned by another tool.

## Configuration

Add `brunch.yml` to the repository root.

For Docker Compose:

```yaml
compose_file: compose.yaml
```

Expose the application through `BRUNCH_PORT`:

```yaml
services:
  web:
    ports:
      - "127.0.0.1:${BRUNCH_PORT}:3000"
```

The first activated worktree prefers port `3000`. Additional worktrees receive another free port.

To prefer a different starting port:

```yaml
preferred_port: 4000
```

Port assignments are persisted per worktree in `.git/brunch/state.json`.

## Getting started

Commit `brunch.yml` and the application configuration first. The repository must contain at least one commit.

Then run:

```bash
brunch install
brunch doctor
brunch activate
brunch status
```

`brunch activate` starts the environment for the currently checked-out branch.

To print only the current worktree's port:

```bash
brunch port
```

Open the application on the printed port, for example:

```text
http://127.0.0.1:3000
```

With Compose, the application must listen on the container port mapped in the Compose file.

## Branch switching

Once the hooks are installed, normal Git branch switches automatically stop the previous branch environment and start the new one:

```bash
git switch -c feature/login
git switch main
```

Branches checked out in the same worktree reuse that worktree's host port.

With Compose, each branch keeps its own Compose project and named volumes, so persistent resources remain isolated between branches.
Returning to a previously activated branch starts its stopped containers again,
preserving files written inside them. The branch keeps the same host port.

To manually start the environment after `brunch stop`:

```bash
brunch activate
```

To rebuild and recreate its containers explicitly:

```bash
brunch restart
```

`brunch restart` may discard data stored only in a container's writable layer.
Put important data, such as databases, in named volumes.

Compose builds use files from the live worktree, including uncommitted changes.

If you want source edits to appear in an already running container without rebuilding, configure a bind mount or another reload mechanism in your Compose setup.

## Parallel worktrees

Additional worktrees run independently on different host ports.

Create them with `git-hooks-ext`:

```bash
ghe worktree add -b feature-a ../feature-a
ghe worktree add -b feature-b ../feature-b
```

Then:

```bash
cd ../feature-a

brunch port
brunch ports
```

`brunch port` prints the current worktree's port.

`brunch ports` groups the current and previously activated branches under each
worktree. Stopped branches appear in gray and retain their worktree's port for
the next activation.

Switching branches inside one worktree does not affect environments running in other worktrees.

If you create a worktree with plain Git:

```bash
git worktree add -b feature-c ../feature-c
```

activate Brunch manually inside it:

```bash
cd ../feature-c
brunch activate
```

After moving or removing worktrees with plain Git, run:

```bash
brunch cleanup
```

Brunch never deletes the worktree source directory.

## Managers

### Docker Compose

Docker Compose is the default manager:

```yaml
compose_file: compose.yaml
```

### Podman Compose

Podman Compose uses the same Compose file contract:

```yaml
manager: podman_compose
compose_file: compose.yaml
```

### Local process

Use `local_process` for a development command such as `bin/dev`:

```yaml
manager: local_process
command: bin/dev
```

Brunch starts and stops the process together with the branch environment and stores its output under `.git/brunch/controls`.

### Custom commands

Use the `command` manager to integrate Brunch with project-specific tooling:

```yaml
manager: command
commands:
  create: bin/environment create
  start: bin/environment start
  stop: bin/environment stop
  remove: bin/environment remove
```

Brunch runs these commands from the live worktree with:

```text
BRUNCH_REF
BRUNCH_PORT
BRUNCH_PROJECT
BRUNCH_SNAPSHOT
```

`BRUNCH_SNAPSHOT` points to the live worktree for compatibility with manager adapters.

`create` is optional.

`start` must return after launching the environment.

`stop` is called when switching away from the active branch.

`remove` is called when the corresponding worktree environment is deleted and should remove manager-owned persistent resources.

Optional commands:

```yaml
commands:
  status: bin/environment status
  health: bin/environment health
  logs: bin/environment logs
```

These power the corresponding Brunch operations.

## Worktree lifecycle

A branch checkout stops the previous environment in that worktree and starts the new one on the same host port.

Other worktrees continue running.

Removing a worktree removes its Brunch environments. Brunch keeps the information needed to shut down manager resources under `.git/brunch/controls`, so cleanup can still run after the worktree itself is gone.

If a custom `remove` command depends on project files, those files must be committed because cleanup after worktree removal uses the last committed state.

`brunch cleanup` removes environments belonging to worktrees that no longer exist.

Git does not expose every branch deletion workflow reliably to hooks, so stopped branch environments may remain until their worktree is removed.

## Commands

```bash
brunch install
```

Install Brunch hooks for the repository.

```bash
brunch activate
```

Start the environment for the current branch.

```bash
brunch status
```

Show the current environment, manager status, and port.

```bash
brunch port
```

Print the current worktree's port.

```bash
brunch ports
```

List current and stopped branch environments grouped by worktree.

```bash
brunch stop
```

Stop the active environment without removing it.

```bash
brunch restart
```

Recreate and start the active environment.

```bash
brunch logs
brunch logs --follow
```

Show environment logs.

```bash
brunch run -- bin/rails console
```

Run a command on the host from the live worktree.

```bash
brunch doctor
```

Check Git, installed hooks, configuration, manager availability, and ports.

```bash
brunch cleanup
```

Remove environments belonging to deleted worktrees.

## Upgrading from older configurations

Before upgrading from an older branch-only configuration, stop its running environment and clean up its legacy state.

Brunch will not reinterpret an existing non-empty branch-only state as worktree state.

## Development

```bash
bundle install
bin/install-pre-commit
bundle exec rake quality
gem build brunch.gemspec
```

Run container integration tests with Docker Compose:

```bash
BRUNCH_INTEGRATION_MANAGER=docker_compose bundle exec rake test
```

Or Podman Compose:

```bash
BRUNCH_INTEGRATION_MANAGER=podman_compose bundle exec rake test
```

Without `BRUNCH_INTEGRATION_MANAGER`, container integration tests are skipped by the local quality check.

The pre-commit hook runs RuboCop with automatic corrections, Reek, and the full test suite. SimpleCov requires 100% line and branch coverage for `lib/**/*.rb`.

If RuboCop modifies a file, review and stage the changes before committing.
