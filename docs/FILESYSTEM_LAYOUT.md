# Filesystem Layout

`sessh` follows the XDG base directory spec:

- `XDG_CONFIG_HOME` for user config
- `XDG_CACHE_HOME` for bootstrapped binaries
- `XDG_STATE_HOME` for durable session state and logs
- `XDG_RUNTIME_DIR` for live daemon sockets and process-local runtime files

If `XDG_RUNTIME_DIR` is missing, sessh falls back to `/tmp/sessh-<uid>`.

# Runtime

The stable local daemon socket lives at:

```text
d/sesshd.sock
```

Runtime GUID directories live under `guid/<s-guid>/` for terminal-emulator
sessions and `guid/<p-guid>/` for proxy streams. They are implementation
details used by the daemon while a stream is live. The public topology is the
single `sesshd` socket, not one user-addressable socket per GUID.

# State

State lives under `$XDG_STATE_HOME/sessh` or `~/.local/state/sessh`.

Session state is keyed by GUID while the original client may still reconnect.
There is intentionally no public list/attach/kill state model.

# Cache

Bootstrapped binaries live under `$XDG_CACHE_HOME/sessh/bin/<version>/<sha>/`.
The executable is named `sessh`.
