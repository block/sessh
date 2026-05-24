# Contributing to sessh

Start with [README.md](README.md), then read
[Architecture](docs/ARCHITECTURE.md).

Keep docs high-level. Details live in comments in code.

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

Prefer process-level tests that invoke the `sessh` binary and exercise real
protocol, socket, PTY, filesystem, and terminal behavior (i.e. avoid mocks).

Most behavior should be tested without ssh by using the `:local:` transport.
Use Podman only for slower end-to-end coverage across a real ssh boundary.

When fixing a bug or introducing new functionality, write a test first, and
ensure it fails in the correct way. Commit these tests together with the code
changes. You can use test-driven development for removing old features, but
don't commit tests that simply check if old functionality is no longer there.

## Releases

See [RELEASING.md](RELEASING.md).

## Issues

Use GitHub issues for reproducible bugs. Include the command you ran and your
~/.config/sessh/sessh.env.

You can generate a transcript of TTY (for both the inner and outer terminals)
using --capture-tty-transcript. Please audit this transcript for personal data
before including it in bug reports.
