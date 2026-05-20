# sessh

`sessh` is `ssh` with persistent sessions and seamless connection recovery.

- no more losing work due to network disconnections
- no need to install anything remotely: `sessh` will bootstrap
- no extra ports: `sessh` communicates over `ssh`
- scrollback and mouse behavior behave normally
- same command-line interface as `ssh`
- terminal state is restored automatically
- `ssh` is 3 syllables; `sessh` is 1

To get started:

```sh
% brew install block/tap/sessh
% sessh [ssh-options ...] destination
```

User-facing commands and configuration:
[User Manual](docs/USER_MANUAL.md).

Implementation details in [Architecture](docs/ARCHITECTURE.md).
