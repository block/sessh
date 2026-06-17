# Display Method

Sessh uses diagnostics to provide feedback when the connection becomes
disrupted (disconnected or unresponsive). Our ability to display diagnostics is
constrained by whether or not stderr is a TTY (some SSH commands - e.g. port
forwarding - don't use the TTY at all. It's also possible that we're running an
SSH command that normally would affect the TTY but we've redirected stdout),
whether or not the requested SSH command involves the TTY, and the filter-level
setting.

Normally stdin is used for diagnostics input and stderr is used for diagnostics
output, but that can be overridden with `--diagnostics-file`.

`--diagnostics-file PATH` can point at `/dev/tty`, a specific terminal device,
or a normal file. If `PATH` opens as a TTY, sessh uses it for diagnostics output
and reconnect input. If it opens as a normal file, sessh appends diagnostic
output there and does not read reconnect input from it. If the file does not
exist, sessh creates it. If `PATH` cannot be opened or created, sessh exits with
an error.

When outer `sessh` starts `sessh :proxy:`, it forwards the same
`--diagnostics-file` option. If the user did not specify one, and stdin/stderr
refer to the same TTY, outer `sessh` passes that TTY path to `sessh :proxy:` so
the proxy process can still show diagnostics and receive reconnect input while
stdin/stdout remain the SSH proxy byte stream.

We choose from the first available of the following human display methods:

1. overlay: diagnostics output must be a TTY and `filter-level=emulated`
2. status: diagnostics output must be a TTY and we have sole control of it
   (e.g. as we do when ssh port forwarding)
3. title: diagnostics output must be a TTY and `filter-level=hygienic`
4. line: human line output; this is the required fallback when diagnostics
   output is not a TTY
5. jsonl: only when requested specifically

`status` is only safe when sessh controls the diagnostics TTY well enough to
rewrite a single status line without trampling an arbitrary program's screen.
That is true for cases like port forwarding, where the diagnostics TTY is not
also carrying the remote terminal UI.

We provide a `diagnostics-level` setting. You can use it to specify the maximum
human display method. For example, `diagnostics-level=status` disables `overlay`
but still allows `status`, `title`, or `line`.

`jsonl` is special. It sorts below `line`, so sessh never picks it merely
because prettier methods are unavailable. `diagnostics-level=jsonl` means force
JSONL and do not use overlay, status, title, or human line output.

## `diagnostics-level=overlay`: An overlay rendered inside the terminal

If we don't have sole control of the TTY, but we're emulating a terminal, we'll
render updating statuses as an overlay on top of the terminal.

The overlay is rendered by the client only. When the connection is disconnected,
the client can draw the overlay immediately. When the connection is unresponsive,
the client immediately requests a repaint and shows an overlay. If remote output
arrives before the repaint, sessh holds it back, updates the overlay to say the
connection recovered and that we're waiting for a repaint, and only resumes
normal output once the repaint arrives.

If diagnostics input is also a TTY then we'll prompt for CTRL-R to reconnect now.

## `diagnostics-level=status`: An updating status line

When we have sole control of the TTY we can display an updating status line
with countdown to when we'll next attempt to reconnect, interleaved with normal
lines for non-status events (e.g. error messages from stderr from the
underlying ssh transport)

If diagnostics input is also a TTY then we'll prompt for CTRL-R to reconnect now.

## `diagnostics-level=title`: An updating window title

If we're not emulating a terminal, but we understand TTY state, we'll render
updating statuses in the window title.

If diagnostics input is also a TTY then we'll prompt for CTRL-R to reconnect now.

## `diagnostics-level=line`: human-readable events, one-per-line

As a last resort, we output human-readable events, one-per-line. We favor
brevity: Instead of counting down, we output the time at which we'll next
attempt to reconnect.

## `diagnostics-level=jsonl`: scriptable events in json form, one-per-line

We emit diagnostics in JSONL format: One JSON event per line. This is intended
for scripts that wish to react to diagnostics programmatically.

# Disconnections

When the transport disconnects, sessh reports the disconnected state, schedules
the next reconnect attempt, and updates diagnostics as the retry state changes.
Overlay, status, and title modes may update in place. Line mode emits sparse
events, including the absolute time of the next retry instead of printing a
countdown every second.

# Unresponsive connections

When the transport is still connected but stops responding, sessh treats it as
unresponsive. In overlay mode, the client requests a repaint immediately and
shows an unresponsive overlay. If the connection starts producing output again
before the repaint completes, sessh does not release that output directly to the
terminal; it keeps the overlay visible, changes it to a recovered state while
waiting for repaint, and resumes normal terminal output after the repaint
restores a known screen state.
