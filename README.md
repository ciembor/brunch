# Brunch

Brunch runs an isolated environment for the currently checked out Git branch.
It uses `git-hooks-ext` for semantic ref events and the standard
`post-checkout` hook to stop the previous environment and activate the next
one. Docker Compose is the default manager, but projects can use custom
commands to integrate another process or infrastructure manager.

Each environment has a distinct Compose project name, network, and named
volumes. Brunch snapshots a branch with `git archive`, so environments never
share a working directory.

## Requirements

- Ruby 3.1 or newer
- Git 2.28 or newer
- Docker Desktop with Docker Compose v2
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

The first port is deterministically selected from the IANA registered range
`1024-49151`. If it is occupied, Brunch prompts for a free replacement and
persists that selection privately in `.git/brunch/state.json`.

### Custom manager commands

Use the `command` manager when the project is started by another tool. Brunch
creates the branch snapshot as usual, changes into it, and runs the configured
commands with these variables: `BRUNCH_REF`, `BRUNCH_PORT`, `BRUNCH_PROJECT`,
and `BRUNCH_SNAPSHOT`.

```yaml
manager: command
commands:
  start: bin/environment start
  stop: bin/environment stop
  remove: bin/environment remove
```

`start` must return after it has launched the environment (for example, by
delegating to a daemon or supervisor). `stop` is used when switching branches;
`remove` is used only when a Git ref has been deleted and should remove any
manager-owned persistent resources. This makes the adapter suitable for Podman,
Kubernetes wrappers, Foreman/Overmind wrappers, or a project-specific script.

## Lifecycle

- A branch checkout stops the previous environment and starts the current one.
- Checking out a remote branch into a new local tracking branch works through
  the same `post-checkout` hook.
- `brunch cleanup` removes the Compose projects, networks, volumes, and
  snapshots for refs that no longer exist.

Git 2.39 cannot reliably report a normal `git branch -d` operation to a hook.
Run `brunch cleanup` after deletion, or let the next managed hook event perform
the cleanup.

## Development

```sh
bundle install
bundle exec rake test
gem build brunch.gemspec
```
