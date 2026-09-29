# Brunch

Brunch runs isolated development environments for Git worktrees. The main
checkout is a worktree too: switching branches there reuses its port, while
additional worktrees run in parallel on different host ports. Docker Compose
is the default manager; Podman
Compose, local processes, and project commands are also supported.

Each branch environment has a distinct Compose project name, network, and
named volumes. The active environment runs from its live worktree directory,
including uncommitted changes when the manager rebuilds or reloads the app.

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
Unknown `brunch.yml` fields are errors, so configuration typos are not ignored.

Expose the application port with `BRUNCH_PORT`:

```yaml
services:
  web:
    ports:
      - "127.0.0.1:${BRUNCH_PORT}:3000"
```

The first activated worktree prefers `127.0.0.1:3000`. Every worktree keeps
its assigned host port while its branches take turns using it. Other worktrees
receive a different free port; running containers can never bind the same host
address and port. To prefer another starting port, set `preferred_port: 4000`.
Brunch persists assignments privately in `.git/brunch/state.json`.

### Parallel worktrees

There is no mode switch. Commit the same `brunch.yml` in your repository, then
create additional worktrees. Run `brunch install` again after upgrading Brunch
to install its worktree hooks.

```sh
ghe worktree add -b feature-a ../feature-a
ghe worktree add -b feature-b ../feature-b
cd ../feature-a
brunch port        # port for this worktree
brunch ports       # ports for all worktrees
```

`ghe worktree add`, `move`, and `remove` emit lifecycle events. Git's
`post-checkout` hook handles branch changes inside any worktree, including the
main checkout. If you use plain `git worktree add`, run `brunch activate` in the
new worktree; after a plain move or removal, run `brunch cleanup` from a
remaining worktree.

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
mount or another reload mechanism in the project's Compose file.
`brunch restart` rebuilds the current environment.

Before upgrading from an older branch-only configuration, stop its running
environment and clean up its legacy state. Brunch refuses to reinterpret an
old non-empty branch state as worktree state, preventing orphaned containers.

### Custom manager commands

Use the `command` manager when the project is started by another tool. Brunch
runs commands from the live worktree with these variables: `BRUNCH_REF`,
`BRUNCH_PORT`, `BRUNCH_PROJECT`, and `BRUNCH_SNAPSHOT`. The last variable points
to the live worktree for compatibility with manager adapters.

```yaml
manager: command
commands:
  create: bin/environment create
  start: bin/environment start
  stop: bin/environment stop
  remove: bin/environment remove
```

`create` provisions manager-owned resources; it is optional for the `command`
manager. `start` must return after
it has launched the environment (for example, by delegating to a daemon or
supervisor). `stop` is used when switching branches; `remove` is used when
a worktree is deleted and should remove any manager-owned persistent
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

Use `local_process` for a development command such as `bin/dev`.
Brunch starts it in a dedicated process group, records its PID, stops that
group on a branch switch, and saves its output under `.git/brunch/controls`.

```yaml
manager: local_process
command: bin/dev
```

## Lifecycle

- A branch checkout stops the previous environment in that worktree, then
  creates and starts the new one on the same port.
- Each worktree keeps its own current environment and port. Other worktrees
  continue running during branch switches.
- Checking out a remote branch into a new local tracking branch works through
  the same `post-checkout` hook.
- `brunch cleanup` removes environments belonging to deleted worktrees.

Git 2.39 cannot reliably report a normal `git branch -d` operation to a hook.
Stopped branch environments remain until their worktree is removed.

## Operations

```sh
brunch status    # current worktree environment, manager status and port
brunch ports     # worktree-to-port list; current worktree is marked in green
brunch port      # only the current worktree's port, suitable for scripts
brunch stop      # stop the active environment without deleting it
brunch restart   # recreate and start the active environment
brunch logs      # show the last 100 logs (or run commands.logs)
brunch logs --follow
brunch run -- bin/rails console  # runs on the host in the live worktree, not in a container
brunch doctor    # verify Git, installed hooks, configuration, manager and ports
brunch cleanup   # delete environments for removed worktrees
```

Brunch coordinates commands with locks under `.git/brunch`, writes `state.json`
atomically, and retries interrupted environment setup on the next activation.

## Development

```sh
bundle install
bin/install-pre-commit
bundle exec rake quality
gem build brunch.gemspec
```

Container E2E tests use real temporary Git repositories, Compose containers,
and HTTP requests. Run them with Docker or Podman:

```sh
BRUNCH_INTEGRATION_MANAGER=docker_compose bundle exec rake test
BRUNCH_INTEGRATION_MANAGER=podman_compose bundle exec rake test
```

CI runs both managers on pushes and pull requests. Without the environment
variable, container tests are skipped by the local quality check.

The pre-commit hook runs RuboCop with automatic corrections, Reek, and the full
test suite. SimpleCov requires 100% line and branch coverage of `lib/**/*.rb`. When
RuboCop changes a file, review and stage the correction before committing.
