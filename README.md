# sessh

`sessh` is `ssh` with persistent sessions: if your connection drops you can re-attach.

## Basic Use

```sh
sessh HOST
sessh HOST --list
sessh HOST --attach
sessh HOST --attach ID
sessh HOST COMMAND [ARG...]
```

When a live session disconnects, `sessh` prints:

```text
--- sessh detached k7m4q2 ---
To attach to this session, run:
  sessh work.example.com --attach k7m4q2
```

## Architecture

`sessh` has a local Python CLI and a POSIX `sh` program that runs remotely.
TTY-backed commands run SSH under a client-side PTY relay. The relay passes
terminal bytes through unchanged except for nonce-scoped sessh metadata frames,
which let the local client learn the selected session id and clean remote exit
status.

Each command starts one SSH transaction. The remote script initializes state and
creates or attaches a tmux session on a `sessh`-owned socket.

`sessh` configures tmux to be quiet: no status bar, no mouse reporting, no
normal tmux prefix, and no user tmux socket/config interference.

Remote commands also use tmux. By default, their arguments follow ssh's
shell-evaluated command model. `--preserve-args` quotes the command arguments
so the remote command sees the same argv boundaries that sessh received. Remote
commands stream output from a tmux `pipe-pane` transcript and exit locally with
the remote command status. If the live SSH transaction disconnects before the
run is drained, `--attach` replays the transcript from the beginning and follows
new output until completion. For now, remote commands require stdout and stderr
to be TTYs.

The use of tmux means that `sessh` is able to persist and restore the
scrollback buffer.

## Requirements

- No server required (other than `sshd`), but `tmux` must be installed on the remote host.

## Installation

From a checkout:

```sh
uv tool install .
```

For local development without installing:

```sh
uv run --with-editable . sessh --help
```

## Configuration

By default, `sessh` reads `~/.config/sessh/config.yaml`, or
`$XDG_CONFIG_HOME/sessh/config.yaml` when `XDG_CONFIG_HOME` is set.

```yaml
defaults:
  shell: zsh
  history-limit: 10000
remote-init: |
  export PATH="$HOME/bin:$PATH"
```

`shell` must be `bash` or `zsh`. `remote-init` runs before sessh starts tmux on
the remote host.

## SSH Compatibility

`sessh` aims to accept common `ssh` options before `HOST` and pass them through
unchanged, so commands like `sessh -p 2222 -J jump.example.com work.example.com`
work as expected.

Like `ssh`, arguments after `HOST` are interpreted as a remote command:

```sh
sessh HOST COMMAND [ARG...]
```

`--attach` and `--list` are sessh options and may appear after `HOST`. Use `--`
to end sessh option parsing when the remote command itself starts with `--`.

By default, sessh matches ssh's evaluated remote command behavior. Use
`--preserve-args` when the remote command should receive the exact argv
boundaries that sessh received:

```sh
sessh HOST --preserve-args printf '%s\n' 'hello quoted world'
```

Options that remove the remote TTY, remove the remote command, background the
connection, or replace the SSH stream are incompatible with sessh's tmux-backed
session model.

## Release

See [RELEASE.md](RELEASE.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
