# Framing

Each wire frame is a 4-byte big-endian length followed by a protobuf envelope.
The handshake uses `HelloFrame`, whose `oneof` carries only `HelloRequest`,
`HelloOk`, or `Error`. Once both sides have accepted the handshake, all
subsequent frames use the versioned `Frame` envelope from `sessh.proto`.

Post-handshake frames are grouped by who is talking. `ClientDaemonItem` is the
local API between a client-side process and its local `sesshd`. `ClientRemoteItem`
is logical client-to-remote traffic: terminal-emulator and proxy items live
inside it on local IPC, then inside `DaemonTunnelItem.MuxStreamFrame.Payload`
when they cross the daemon-to-daemon tunnel.

Proxy diagnostics and retry control also use the local `ClientDaemonItem` API.
In process-isolated proxy mode, the long-lived `sessh-proxy` process owns the
OpenSSH byte stream and can use `ProxyDiagnosticsOpen`/`RetryNow` routing for
diagnostics. In direct daemon placement, `sessh-proxy` instead sends
`ProxyFdPassOpen` with an SCM_RIGHTS fd for the raw OpenSSH byte stream, waits
for `ProxyFdPassAccepted`, and exits. The raw OpenSSH byte stream is never the
framed daemon IPC socket.

The `HelloFrame`/`Frame` separation keeps compatibility negotiation isolated
from the post-handshake schema. That leaves room to change the post-handshake
encoding while still emitting clean `Error` responses for incompatible versions.

# Attached bytes and file descriptors

Most frames are just the protobuf envelope. Some frames also carry bytes
immediately after the protobuf envelope, described by `Frame.Attached`.

`RAW` attached bytes are uninterpreted stream data. The daemon can forward those
bytes without treating them as protobuf fields.

`SCM_RIGHTS` attached bytes are different: the byte is only a marker that lets a
Unix-domain-socket `recvmsg` collect the file descriptor attached at that byte
position. The marker byte is discarded. This is used for `ProxyFdPassOpen`, where
`sessh-proxy` asks `sesshd` to take ownership of a raw OpenSSH byte stream while
the framed daemon IPC connection remains framed.

# Daemon tunnel streams

`DaemonTunnelItem.MuxStreamFrame` is the only daemon-to-daemon multiplexing
envelope. It names the logical stream, then carries one of:

- `Open` / `OpenOk` to start or resume a stream without imposing an extra
  round trip. They carry the peer's durable receive offset.
- `Payload` to carry a typed terminal-emulator or proxy item.
- `Ack` to report receive progress.
- `Eof` to close one outbound direction gracefully.
- `Reset` to abort a stream abruptly, in the same spirit as TCP RST or
  HTTP/2 `RST_STREAM`.

Mux fairness/backpressure is only partially implemented today. The daemon
already avoids letting one stream's local write backlog make unrelated streams
unreadable. Protocol-level credit is future work; once implemented, a full local
buffer for one stream will stop reads for that stream without freezing unrelated
mux streams for terminal-emulator or proxy sessions on the same TCP connection.

# Connection and cleanup events

`ConnectionEvent` is semantic connection state, not remote process output. It is
used for ssh connection progress, bootstrapping, remote-daemon connection state,
transport stderr, disconnected state, and unresponsive state. Visible clients
decide how to render those events based on diagnostics policy.

Remote process cleanup is daemon-tunnel traffic, not a public session registry.
When a remote terminal or proxy process becomes a cleanup target, remote `sesshd`
sends `RemoteProcessStarted`. The local daemon durably records the process
identity and replies with `RemoteProcessRecorded`. If the local owner later
dies, the local daemon can ask the remote daemon to clean up that exact
pid/start-time/socket-path identity with `RemoteProcessCleanupRequest`; the
remote answers `Cleaned` or `Missing`.

# Client capabilities

Like normal `ssh` PTY handling, we:
1. forward input from the outer terminal to the remote
2. forward output from the remote to the outer terminal
3. catch signals (e.g. SIGINT for ctrl-c, SIGWINCH for window size change) and
   transmit them to the remote

Our client has four additional capabilities:
1. It tracks sufficient state so that it can seamlessly reconnect
2. It avoids executing stale rendering operations while resizing
3. It can render overlays independently of the remote
4. It can clean up TTY state independently of the remote

The protocol keeps these capabilities in a small amount of client-side logic so
compatibility-sensitive behavior stays concentrated.

## Seamless reconnect

The protocol is designed so that the terminal worker does not retain state of
disconnected clients. Instead, a reconnecting client sends state to remote
`sesshd`, which combines that with its own terminal state and then computes
missing scrollback and generates accurate repaint instructions for the client.

In the event of a network disconnection, remote `sesshd` will continue
terminal emulation. The virtual screen may update and/or generate additional
lines of scrollback. When the client reconnects, it sends a
`TerminalEmulatorItem.Resize` message with an embedded `RepaintRequest`
containing enough information for the terminal worker to decide:
1. Are the client's scrollback contents stale? (i.e. are they from before
   scrollback was cleared?)
2. Which retained scrollback rows, if any, should be sent to the client?

`RepaintResponse` includes an embedded `Draw` message with instructions to add
missing scrollback rows, possibly clearing older scrollback if stale. These
instructions also clear and re-render the screen, and restore state (e.g. cursor
position/visibility/style, terminal modes such as mouse reporting or bracketed
paste, etc).

## Smart resize

When the terminal window is resized our client receives a SIGWINCH which we
handle by sending a `TerminalEmulatorItem.Resize` message to the remote.
Resizing is treated as a logical reconnection.

The `Resize` contains a `RepaintRequest` and we drop any `Draw` packets until
the matching `RepaintResponse` is received. It doesn't make sense to try to
apply rendering operations that were generated for a different sized window.

`Resize` carries the client's current viewport offset when known. The remote side
answers an unknown offset by aligning the viewport in the repaint response.

## Client-side overlay rendering

The visible client renders reconnect overlays independently of the remote
terminal worker. The client can redraw the overlay in place, but it cannot
remove it safely by itself because only the remote terminal model knows the
screen underneath. To clear an overlay, the client asks the remote to repaint.
After requesting repaint, the client ignores subsequent `Draw` packets up until
the matching `RepaintResponse` so that overlay text does not leak into the outer
terminal's scrollback.

The client uses overlays to notify the user when the connection has died or
become unresponsive.

## Input Acknowledgements

Each `TerminalEmulatorItem.Input` frame carries a client-assigned sequence
number. Remote `sesshd` answers with `InputAck` after receiving a nonzero input
sequence. The client uses the highest acknowledged sequence to know whether
input was still pending when a connection died, and to detect unresponsive
connections after user input.

## Client-side state cleanup

Overlay rendering and input acknowledgement both rely on the remote generating
well-formed packets of rendering instructions. The `Draw` message contains
rendering instructions, but the remote guarantees that they avoid leaking incidental
rendering state (e.g. bold/inverse/colors, OSC 8 hyperlinks, cursor movement,
etc): If any earlier instructions modify that state, then there must be later
instructions within that same `Draw` message to restore that state.

A `Draw` may intentionally leave terminal state set when that state is part of
the modeled session (e.g. alternate screen), but it contains a separate field
with instructions to restore that state when `sessh` exits.
