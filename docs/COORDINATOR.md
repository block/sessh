# Coordinator

`sesshd` is the durable per-user process behind `sessh`. It is the same binary
as `sessh`, entered internally as `sessh :internal-daemon:`, but installed under
a separate name so users can kill visible `sessh` clients without killing the
cleanup owner.

There is one local Unix-domain socket:

```text
d/sesshd.sock
```

Public `sessh` invocations connect to that socket, starting the daemon when it
is missing or stale. Remote bootstrap does the same thing on the server side.

# Filter Levels

`emulated` is the default. The visible client owns the terminal UI while remote
`sesshd` owns the PTY and terminal model.

`hygienic` uses OpenSSH for the visible stream but keeps a local client wrapper
when a tty is available, so sessh can still show replaceable diagnostics and
intercept reconnect controls at safe times.

`raw` lets OpenSSH own the stream without sessh diagnostics.

`unhygienic` has been removed. Its value was best-effort diagnostics without
the wrapper, and that complexity is not worth carrying into the daemon design.

# Cleanup

The client-side daemon owns cleanup records and retries remote cleanup until
`cleanup-retry-hours` is reached. Remote `sesshd` owns
`disconnected-reap-hours`, which bounds how long disconnected remote work may
remain alive without client input.

There is intentionally no public list/attach/kill command surface. The only
resume path is the original visible client reconnecting while it is still alive.
