# Contributing to sessh

Start with [README.md](README.md), then read
[Architecture](docs/ARCHITECTURE.md).

## Development Setup

sessh currently requires Zig 0.15.2. On macOS, install it with:

```sh
brew install zig@0.15
```

Run commands from the repository root. Use the repository check script for the
current implementation:

```sh
scripts/check
```

Run:
```
scripts/install
```

to build and install a binary in ~/.local/bin/sessh

## Testing

Testing strategy is described in [Testing](docs/TESTING.md). Prefer
process-level tests that invoke the `sessh` binary and exercise real protocol,
socket, PTY, filesystem, and terminal behavior.

Most behavior should be tested without ssh by using the `:local:` transport.
Use Podman only for slower end-to-end coverage across a real ssh boundary.

## Releases

See [RELEASING.md](RELEASING.md).

## Issues

Use GitHub issues for reproducible bugs. Include the command you ran and your
~/.config/sessh/sessh.env.

You can generate a transcript of TTY (for both the inner and outer terminals)
using --capture-tty-transcript. Please audit this transcript for personal data
before including it in bug reports.
