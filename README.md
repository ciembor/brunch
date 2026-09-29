# Brunch

Brunch runs isolated development environments for Git branches or worktrees.
The default branch mode runs one environment on a shared port. Worktree mode
lets several people or agents run different features at the same time, each
with its own port and data. Docker Compose is the default manager; Podman
Compose, local processes, and project commands are also supported.

Each environment has a distinct Compose project name, network, and named
volumes. Branch mode uses a committed snapshot made with `git archive`.
Worktree mode runs from each worktree's live directory, including uncommitted
changes when the manager rebuilds or reloads the application.

## Requirements

- Ruby 3.1 or newer
- Git 2.28 or newer
- A supported environment manager: Docker Compose, Podman Compose, or project commands
- [`git-hooks-ext`](https://github.com/ciembor/git-hooks-ext)

## Installation

```sh
gem install brunch
brunch install
```

`brunch install` installs the `git-hooks-ext` bridge and the project-local
hooks. It refuses to replace an existing hook owned by another tool.

## Project configuration

Add `brunch.yml` to the project root. Docker Compose is the default, so the
following remains sufficient for Compose projects:

```yaml
compose_file: compose.yaml
```

The referenced Compose file belongs to the application. Brunch does not impose
a database or service stack: applications may define PostgreSQL, MySQL, Redis,
Sidekiq, Elasticsearch, or any other services they need.

Expose the application port with `BRUNCH_PORT`:

```yaml
services:
  web:
    ports:
      - "127.0.0.1:${BRUNCH_PORT}:3000"
```

In `unique` mode, the first port is deterministically selected from the IANA
registered range `1024-49151`. If it is occupied, Brunch prompts for a free
replacement and persists that selection privately in `.git/brunch/state.json`.

### Port modes

The default `shared` mode uses `127.0.0.1:3000` for every branch. It stops all
other environments before starting one, so stopped containers, networks, and
volumes remain isolated without holding the host port.

```yaml
port_mode: shared
shared_port: 3000
```

Use `unique` to retain a different persistent port for each branch and permit
parallel environments:

```yaml
port_mode: unique
```

### Parallel worktrees

Commit this configuration before creating worktrees so the new worktrees have
the same mode:

```yaml
mode: worktrees
compose_file: compose.yaml
```

Worktree mode automatically uses unique ports and keeps each worktree's
environment running when another one starts. `port_mode: shared` and
`lifecycle: active_only` are incompatible with it. Run `brunch install` again
after upgrading Brunch to install its worktree hooks.

```sh
ghe worktree add -b feature-a ../feature-a
ghe worktree add -b feature-b ../feature-b
cd ../feature-a
brunch port        # port for this worktree
brunch ports       # ports for all worktrees
```

`ghe worktree add`, `move`, and `remove` emit lifecycle events. Git's
`post-checkout` hook handles branch changes inside a worktree. If you use
plain `git worktree add`, run `brunch activate` in the new worktree; after a
plain move or removal, run `brunch cleanup` from a remaining worktree.

The source directory is never deleted by Brunch. It keeps a separate control
copy under `.git/brunch/controls` so it can shut down Compose or run a custom
`remove` command after a worktree has been removed. Switching branches within
one worktree keeps the old branch's environment stopped, with its own named
volumes. Removing the worktree removes all of its Brunch environments. The
`local_process` manager also writes its log to the control directory, keeping
the worktree clean. Custom `remove` commands that depend on project files must
be committed, because the control copy is based on the worktree's last commit.

Docker builds read uncommitted files from the live worktree. To see edits in
an already running container without rebuilding, configure a source bind
mount or another reload mechanism in the project's Compose file. In worktree
mode `brunch restart` rebuilds the current environment.

When migrating an existing project from branch mode, stop its currently
running environment with `brunch stop` before changing `brunch.yml`. Existing
branch-mode snapshots and volumes remain available in the Git state directory;
Brunch does not delete them as part of the mode switch.

### Custom manager commands

Use the `command` manager when the project is started by another tool. Brunch
creates the branch snapshot as usual, changes into it, and runs the configured
commands with these variables: `BRUNCH_REF`, `BRUNCH_PORT`, `BRUNCH_PROJECT`,
and `BRUNCH_SNAPSHOT`.

```yaml
manager: command
commands:
  create: bin/environment create
  start: bin/environment start
  stop: bin/environment stop
  remove: bin/environment remove
```

`create` provisions manager-owned resources after Brunch has created the
snapshot; it is optional for the `command` manager. `start` must return after
it has launched the environment (for example, by delegating to a daemon or
supervisor). `stop` is used when switching branches; `remove` is used only when
a Git ref has been deleted and should remove any manager-owned persistent
resources. This makes the adapter suitable for Podman, Kubernetes wrappers,
Foreman/Overmind wrappers, or a project-specific script.

Optional `status`, `health`, and `logs` commands power the corresponding Brunch
commands. A successful `health` command reports a healthy environment.

### Podman Compose

Podman Compose uses the same Compose file contract as Docker Compose:

```yaml
manager: podman_compose
compose_file: compose.yaml
```

### Local process

Use `local_process` for a branch-local development command such as `bin/dev`.
Brunch starts it in a dedicated process group, records its PID, stops that
group on a branch switch, and saves its output to `.brunch.log` in the snapshot.

```yaml
manager: local_process
command: bin/dev
```

### Lifecycle mode

In branch mode, shared ports default to `active_only`, which stops every
non-current environment before activation. Unique ports default to
`switch_only`, which stops only the previously active branch. For example:

```yaml
lifecycle: active_only
```

## Lifecycle

- In branch mode, a branch checkout creates and starts its environment.
- In worktree mode, each worktree keeps its own current environment and port.
- `switch_only` stops the previous environment; `active_only` stops every
  non-current environment.
- Checking out a remote branch into a new local tracking branch works through
  the same `post-checkout` hook.
- `brunch cleanup` removes the Compose projects, networks, volumes, and
  snapshots for refs that no longer exist.

Git 2.39 cannot reliably report a normal `git branch -d` operation to a hook.
Run `brunch cleanup` after deletion, or let the next managed hook event perform
the cleanup.

## Operations

```sh
brunch status    # active/sleeping environments, manager status, health, port
brunch ports     # branch-to-port list; active branch is marked in green
brunch port      # only the active branch port, suitable for scripts
brunch stop      # stop the active environment without deleting it
brunch restart   # recreate and start the active environment
brunch logs      # show the last 100 logs (or run commands.logs)
brunch logs --follow
brunch exec -- bin/rails console
brunch doctor    # verify Git, installed hooks, configuration, manager and ports
brunch cleanup   # delete environments whose Git refs no longer exist
```

Brunch serializes commands with `.git/brunch/lock`, writes `state.json`
atomically, and removes an interrupted pending setup on the next activation.

## Development

```sh
bundle install
bundle exec rake test
gem build brunch.gemspec
```
