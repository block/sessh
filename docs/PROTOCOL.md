We keep our client simple. Like normal `ssh` PTY handling, we:
1. forward input from the outer terminal to the remote
2. forward output from the remote to the outer terminal
3. Catch signals (e.g. SIGINT for ctrl-c, SIGWINCH for window size change) and
   transmit them to the remote

Our client has three additional capabilities:
1. It tracks sufficient state so that it can seamlessly reconnect
2. It can render banners independently of the remote
3. It can cleanup TTY state independently of the remote

## Seamless reconnect

The protocol is designed so that session agents don't retain state of
disconnected clients. Instead, a reconnecting client sends state to its session
agent, which combines that with its own state and then computes missing
scrollback and generates accurate repaint instructions for the client.

In the event of a network disconnection, the session agent will continue
terminal emulation. The virtual screen may update and/or generate additional
lines of scrollback. When the client reconnects, it sends a RepaintRequest that
may include an opaque scrollback cursor previously returned by Draw. The client
does not interpret the cursor. To the session agent, the cursor identifies enough
state to decide:
1. Are the client's scrollback contents stale? (i.e. are they from before
   scrollback was cleared?)
2. Which retained scrollback rows, if any, should be sent to the client?

If the client's scrollback contents are stale, then the remote will include an
instruction to clear the client's scrollback, along with instructions to render
all of the new scrollback. Otherwise the remote will compute how many rows of
scrollback the client is missing and include instructions to render them.

If the RepaintRequest omits the cursor, the session agent assumes the client has
current scrollback and sends only the screen repaint. If the request includes an
empty cursor, the session agent sends all retained scrollback available, subject
to any requested row cap.

Additionally the RepaintResponse includes instructions for redrawing the
screen and restoring any state (e.g. cursor position/visibility/style, terminal
modes such as mouse reporting or bracketed paste, etc).

Resize carries the client's current viewport offset when known. Omitted means
the viewports are aligned; `-1` means the client lost track of the offset after
a resize. The session agent answers an unknown offset by aligning the viewport
in the repaint response.

## Client-side banner rendering

We allow for the possibility of the client to render banners independently of
the remote, but the client doesn't have the ability to remove the banners by
itself. It can redraw a different banner, but the only way it can remove a
banner is by asking the remote to repaint. This capability allows the client to
notify the user when the connection has become stale.

## Client-side state cleanup

Both of the previous capabilities rely on the remote generating well-formed
packets of rendering instructions. The Draw message contains rendering
instructions, but the remote guarantees that they avoid leaking incidental
rendering state (e.g. bold/inverse/colors, OSC 8 hyperlinks, cursor movement,
etc): If any earlier instructions modify that state, then there must be later
instructions within that same Draw message to restore that state.

A Draw may intentionally leave terminal state set when that state is part of
the modeled session (e.g. alternate screen), but it contains a separate field
with instructions to restore that state when `sessh` exits.
