# Contributing to sessh

sessh is being rewritten around a single native binary, per-session agents, and
a runtime protocol. Start with [README.md](README.md), then read
[Architecture](docs/ARCHITECTURE.md) before changing implementation behavior.

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

## Testing

Testing strategy is described in [Testing](docs/TESTING.md). Prefer
process-level tests that invoke the `sessh` binary and exercise real protocol,
socket, PTY, filesystem, and terminal behavior.

Most behavior should be tested without ssh by using the `:local:` transport.
Use Podman only for slower end-to-end coverage across a real ssh boundary.

## Releases

Releases are cut from version tags. See [RELEASING.md](RELEASING.md) for the exact
release process.

## Issues

Use GitHub issues for reproducible bugs. Include the command you ran, the local
and remote environments, whether you used ssh or `:local:`, and relevant
terminal output.
