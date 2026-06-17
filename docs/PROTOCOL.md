# Framing

Each wire frame is a 4-byte big-endian length followed by a protobuf envelope.
The handshake uses `HelloFrame`, whose `oneof` carries only `HelloRequest`,
`HelloOk`, or `Error`. Once both sides have accepted the handshake, all
subsequent frames use the versioned `Frame` envelope from `sessh.proto`.

Proxy-control traffic uses normal local client connections to `sesshd`. The
visible client sends `ProxyControlOpen` with the stream's `p-` GUID. The
ProxyCommand process does not open a separate control channel; its normal
`ProxyStreamItem.Open` carries the same GUID, and the daemon relays
`ConnectionEvent` and `RetryNow` frames between the visible client connection and
that proxy stream. When proxy functionality is handled directly by `sesshd`,
the ProxyCommand process instead sends `ProxyFdPassOpen` with an SCM_RIGHTS fd
for the raw OpenSSH byte stream, then exits after `sesshd` accepts the fd.

The `HelloFrame`/`Frame` separation is designed to allow us maximum protocol
flexibility in the future. We could migrate off of protobuf for everything past
`HelloOk` while still emitting clean `Error` responses for incompatible
versions.

# Client capabilities

Like normal `ssh` PTY handling, we:
1. forward input from the outer terminal to the remote
2. forward output from the remote to the outer terminal
3. Catch signals (e.g. SIGINT for ctrl-c, SIGWINCH for window size change) and
   transmit them to the remote

Our client has 4 additional capabilities:
1. It tracks sufficient state so that it can seamlessly reconnect
2. It avoids executing stale rendering operations while resizing
2. It can render overlays independently of the remote
3. It can cleanup TTY state independently of the remote

We are able to implement these 4 additional capabilities with minimal client
logic, which hopefully means it's easier to preserve compatibility across
versions.

## Seamless reconnect

The protocol is designed so that the remote terminal process does not retain
state of disconnected clients. Instead, a reconnecting client sends state to
remote `sesshd`, which combines that with its own terminal state and then computes
missing scrollback and generates accurate repaint instructions for the client.

In the event of a network disconnection, remote `sesshd` will continue
terminal emulation. The virtual screen may update and/or generate additional
lines of scrollback. When the client reconnects, it sends a `TeResize` message
with an embedded `TeRepaintRequest` message containing enough information for the
remote terminal process to decide:
1. Are the client's scrollback contents stale? (i.e. are they from before
   scrollback was cleared?)
2. Which retained scrollback rows, if any, should be sent to the client?

`TeRepaintResponse` includes an embedded `TeDraw` message with instructions to add
missing scrollback rows, possibly clearing older scrollback if stale. These
instructions also clear and re-render the screen, and restore state (e.g.
cursor position/visibility/style, terminal modes such as mouse reporting or
bracketed paste, etc).

## Smart resize

When the terminal window is resized our client receives a SIGWINCH which we
handle by sending a `TeResize` message to the remote, the same message that gets
embedded within `TeSessionAttach`. Resizing is treated as a logical reconnection.

The `TeResize` contains a `TeRepaintRequest` and we drop any `TeDraw` packets until
the matching `TeRepaintResponse` is received. It doesn't make sense to try to apply
rendering operations that were generated for a different sized window.

`TeResize` carries the client's current viewport offset when known. The remote
the remote side answers an unknown offset by aligning the viewport in the repaint
response.

## Client-side overlay rendering

We allow for the possibility of the client to render overlays independently of
the remote, but the client doesn't have the ability to remove the overlays by
itself. It can redraw a different overlay, but the only way it can remove an
overlay is by asking the remote to repaint. After requesting repaint, the client
ignores subsequent `TeDraw` packets up until the matching `TeRepaintResponse` so that
the overlay doesn't end up in the outer terminal's scrollback.

The client uses overlays to notify the user when the connection has died or
become unresponsive.

## TeInput acknowledgements

Each `TeInput` frame carries a client-assigned sequence number. Remote `sesshd`
answers with `TeInputAck` after receiving a nonzero input sequence. The client uses
the highest acknowledged sequence to know whether input was still pending when
a connection died, and to detect unresponsive connections after user input.

## Client-side state cleanup

Both of the previous capabilities rely on the remote generating well-formed
packets of rendering instructions. The `TeDraw` message contains rendering
instructions, but the remote guarantees that they avoid leaking incidental
rendering state (e.g. bold/inverse/colors, OSC 8 hyperlinks, cursor movement,
etc): If any earlier instructions modify that state, then there must be later
instructions within that same `TeDraw` message to restore that state.

A `TeDraw` may intentionally leave terminal state set when that state is part of
the modeled session (e.g. alternate screen), but it contains a separate field
with instructions to restore that state when `sessh` exits.
