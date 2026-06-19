# Contributing to sessh

Start with [README.md](README.md), then read
[Architecture](docs/ARCHITECTURE.md).

## Guidelines

Keep docs high-level. Details live in comments in code.

Trivial blocks of code don't need comments, but all substantial blocks should
have comments summarizing what they do, and why (if it's not obvious)

Favor small sets of arguments to functions. When larger sets of arguments are
warranted and the arguments are non-obvious, use named-parameter-structs.

Don't use threads. Use non-blocking IO instead.

## Development Setup

sessh currently requires Zig 0.15.2. On macOS, install it with:

```sh
brew install zig@0.15
```

Run commands from the repository root. Use the fast repository check script for
quick local smoke coverage:

```sh
scripts/check --fast
```

Also run the specific tests that cover the code you changed. Run
`scripts/check --ci` before releasing or when you need the same coverage as
continuous integration. `scripts/check --full` adds the slow Podman ssh harness.

Run:
```
scripts/install
```

to build and install a binary in ~/.local/bin/sessh

## Testing

Structure test/debug code so that it is compiled out of release artifacts.

Structure code for modularity and testability. Avoid mocks.

Test at the module level and at the process level.

Process-level tests should invoke the `sessh` binary and exercise real
protocol, socket, PTY, filesystem, and terminal behavior (i.e. avoid mocks).
Most behavior should be tested without `ssh` in the interests of speed -
instead we fake out `ssh` and run locally.

For limited test cases where it's beneficial to use actual `ssh`, use Podman.

When fixing a bug or introducing new functionality, write a test first, and
ensure it fails in the correct way. Commit these tests together with the code
changes.

## Releases

See [RELEASING.md](RELEASING.md).

## Issues

Use GitHub issues for reproducible bugs. Include the command you ran and your
~/.config/sessh/sessh.env.

You can generate a transcript of TTY (for both the inner and outer terminals)
using --capture-tty-transcript. Please audit this transcript for personal data
before including it in bug reports.
