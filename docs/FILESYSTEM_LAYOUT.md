# Filesystem Layout

`sessh` follows the XDG base directory spec:

- `XDG_CONFIG_HOME` for user config
- `XDG_CACHE_HOME` for bootstrapped binaries
- `XDG_STATE_HOME` for durable session state and logs
- `XDG_RUNTIME_DIR` for live sockets and process-local runtime files

If `XDG_RUNTIME_DIR` is missing, sessh falls back to `/tmp/sessh-<uid>`.

# Runtime

Runtime guid directories live under `guid/<s-guid>/` for sessions and
`guid/<p-guid>/` for proxy streams. A session directory may contain:

- `agent.sock`: symlink to the live agent socket
- `meta.json`: runtime identity for the agent

The real remote agent socket lives under `a/<compact-guid>`. Client-side
coordination sockets for ProxyCommand mode live under `c/<compact-guid>`.
Keeping those namespaces separate avoids collisions when both ends happen to
run on the same machine.

# State

State lives under `$XDG_STATE_HOME/sessh` or `~/.local/state/sessh`.

- `guid/<s-guid>/agent.log` stores session-agent diagnostics.

# Cache

Bootstrapped binaries live under `$XDG_CACHE_HOME/sessh/bin/<version>/<sha>/`.
The executable is named `sessh`.
