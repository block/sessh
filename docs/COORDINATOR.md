# Coordinator

`sesshd` is the durable per-user process behind `sessh`. It is the same binary
as `sessh`, but the daemon namespace contains a `sesshd` symlink beside the
socket so users can kill visible `sessh` clients without killing the cleanup
owner.

There is one local Unix-domain socket per compatible build namespace:

```text
<protocol-major>/sesshd.sock
<protocol-major.dev.hash>/sesshd.sock
```

Public `sessh` invocations connect to that socket, starting the daemon when it
is missing or stale. Dev builds include a short executable hash in the
namespace, so a local rebuild naturally starts a fresh daemon. Remote bootstrap
passes the client-selected namespace into `:internal-broker:` so the remote side
does not need to derive it independently. With `--no-bootstrap`, no namespace is
passed; the remote broker uses its own default namespace and the handshake
catches version mismatches. Minor version compatibility remains a protocol
handshake concern, not a socket-name concern.

# Filter Levels

`emulated` is the default. The visible client owns the terminal UI while remote
`sesshd` owns the PTY and terminal model.

`hygienic` uses OpenSSH for the visible stream but keeps a local client wrapper
when a tty is available, so sessh can still show replaceable diagnostics and
intercept reconnect controls at safe times.

`unhygienic` lets OpenSSH own the stream without sessh filtering. Any diagnostic
output shares the user's tty with the ordinary ssh stream, so it can interleave
with remote output.

# Cleanup

The client-side daemon owns cleanup records and retries remote cleanup until
`cleanup-retry-limit-hours` is reached. Remote `sesshd` owns
`disconnected-reap-hours`, which bounds how long disconnected remote work may
remain alive without client input.

There is intentionally no public list/attach/kill command surface. The only
resume path is the original visible client reconnecting while it is still alive.
