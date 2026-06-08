# Architecture

`sessh` is an ssh-shaped client with a per-user daemon named `sesshd`.
The packaged artifact is still just `sessh`; runtime namespaces contain
role-shaped symlinks such as `sesshd`, `sessh-broker`, and `sessh-proxy`.

The visible `sessh` process parses ssh-compatible arguments, starts or connects
to local `sesshd`, then chooses either the terminal-emulator path or the
OpenSSH-owned proxy stream path.

## Startup

For a terminal-emulator session, the first connection looks like this:

1. The visible client runs `ssh HOST <bootstrap-script>`.
2. The bootstrapper finds or installs the matching `sessh` binary.
3. The remote binary starts or connects to remote `sesshd`.
4. Remote `sesshd` owns the PTY and terminal model for one `s-` GUID.
5. The visible client and remote daemon exchange protobuf frames for input,
   output, repaint, resize, reconnect, and shutdown state.

Proxy streams use the same bootstrap path, but OpenSSH owns the visible stream
and `sesshd` owns the durable byte-stream endpoint.

## Internal Modalities

Special first arguments are compatibility entrypoints, not public commands.
Steady-state internal processes usually enter by executable name through the
runtime symlinks:

- `:internal-daemon:`
- `:internal-broker:`
- `:internal-proxy-stream:`

Everything else is parsed as a normal ssh-shaped `sessh` invocation.

## Other Docs

Networking behavior is documented in [NETWORKING](NETWORKING.md). Runtime and
state layout is documented in [FILESYSTEM_LAYOUT](FILESYSTEM_LAYOUT.md).
