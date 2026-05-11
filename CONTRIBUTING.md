# Contributing to sessh

Thanks for taking the time to improve sessh.

## Development Setup

Install `uv`, then run commands from the repository root.

```sh
uv run --with-editable . sessh --help
```

The full verification suite uses Podman for integration tests that exercise a
real SSH server and remote tmux session. For a faster local check that skips
those tests:

```sh
scripts/check --fast
```

Before opening a pull request, run the full suite:

```sh
scripts/check
```

## Testing

Unit tests are standard `unittest` tests under `tests/`.

```sh
uv run --no-project --with-editable . python -m unittest discover -s tests
```

To run the Podman-backed SSH integration suite directly:

```sh
env SESSH_RUN_PODMAN_TESTS=1 uv run --no-project --with-editable . python -m unittest tests.integration.test_ssh_bootstrap_podman.PodmanSshBootstrapTests
```

## Releases

Releases are cut from version tags. See [RELEASE.md](RELEASE.md) for the exact
release process.

## Issues

Use GitHub issues for reproducible bugs. Include the command you ran, the local
and remote environments, the remote `tmux` version, and relevant terminal output.
