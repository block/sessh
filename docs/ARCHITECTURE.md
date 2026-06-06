# Architecture

`sessh` is a single ssh-shaped binary. Public invocation parses ssh-compatible
arguments, chooses either the terminal-emulator path or the ProxyCommand stream
path, and then lets the remote runtime do the small amount of work sessh still
owns.

## Remote Startup

For a terminal-emulator session, the first connection looks like this:

1. The visible client runs `ssh HOST <bootstrap-script>`.
2. The bootstrapper finds or installs the matching `sessh-<os>-<arch>` binary.
3. The client asks that binary to start `:internal-session-broker:`.
4. The broker starts a session agent for one `s-` GUID.
5. The agent allocates the remote PTY and implements the
   [headless terminal emulator](TERMINAL_EMULATOR.md).
6. The visible client and agent exchange protobuf frames for input, output,
   repaint, resize, reconnect, and shutdown state.

ProxyCommand streams also use the bootstrapper, but the remote process is a
stream broker/agent rather than a terminal-emulator session agent. The public
shape remains `sessh [ssh-option ...] host [command ...]`.

## Internal Modalities

Special first arguments are internal entrypoints, not public commands:

- `:internal-session-broker:`
- `:internal-session-agent:`
- `:internal-stream-broker:`
- `:internal-stream-agent:`
- `:internal-proxy-stream:`

Everything else is parsed as a normal ssh-shaped `sessh` invocation.

## Other Docs

Networking behavior is documented in [NETWORKING](NETWORKING.md). Runtime and
state layout is documented in [FILESYSTEM_LAYOUT](FILESYSTEM_LAYOUT.md).
