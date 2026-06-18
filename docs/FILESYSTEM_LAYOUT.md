# Filesystem Layout

`sessh` follows the XDG base directory spec:

- `XDG_CONFIG_HOME` for user config
- `XDG_CACHE_HOME` for bootstrapped binaries
- `XDG_STATE_HOME` for durable cleanup records
- `XDG_RUNTIME_DIR` for live daemon sockets and process-local runtime files

If `XDG_RUNTIME_DIR` is missing, sessh falls back to `/tmp/sessh-<uid>`.

# Runtime

The local daemon socket is scoped by compatibility namespace:

```text
<protocol-major>/sesshd.sock
<protocol-major.dev.hash>/sesshd.sock
```

The namespace directory also contains `sesshd`, `sessh-broker`, `sessh-proxy`,
`sessh-terminal-remote`, and `sessh-proxy-remote` symlinks pointing at the
active executable.

Live terminal-emulator sessions and proxy streams are tracked by the daemon in
memory. If the daemon exits, those live processes are expected to exit too, so
there is no per-GUID runtime state to recover.
The public topology is the single `sesshd` socket, not one user-addressable
socket per GUID.

# State

State lives under `$XDG_STATE_HOME/sessh` or `~/.local/state/sessh`.

Cleanup records live under `procs/`, one JSON file per remote resource GUID.
Those records survive local daemon death and laptop reboot so a future daemon can
ask the remote daemon to hang up stale work. There is intentionally no public
list/attach/kill state model.

# Cache

Bootstrapped binaries live under `$XDG_CACHE_HOME/sessh/bin/<version>/<sha>/`.
The executable is named `sessh`.
