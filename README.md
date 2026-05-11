# sessh

`sessh` is `ssh` with persistent sessions: if your connection drops you can
re-attach.

## Usage

```sh
sessh HOST
sessh HOST --list
sessh HOST --attach
sessh HOST --attach ID
sessh HOST COMMAND [ARG...]
```

Start a session with `sessh HOST`. List existing sessions with `--list`, or
attach to one with `--attach`.

Arguments after `HOST` run as a remote command, following ssh's usual
shell-evaluated command model.

## How It Works

`sessh` runs a local Python CLI and a small POSIX `sh` bootstrap over ssh. The
remote side creates or attaches to a tmux session on a `sessh`-owned socket,
with tmux configured to stay out of the way.

Because the session lives in tmux on the remote host, shell state and scrollback
survive local disconnects.

## Requirements

- No server install beyond `sshd`.
- `tmux` must be installed on the remote host.

## SSH Compatibility

Common ssh options before `HOST` are passed through unchanged:

```sh
sessh -p 2222 -J jump.example.com work.example.com
```

For the full option list, run `sessh --help`.

## Release

See [RELEASE.md](RELEASE.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
