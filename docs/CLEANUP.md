# Cleanup

Sessh trades the problem of processes dying too quickly for the problem of
processes not dying quickly enough. Sessh cleans up stale remote processes with
three policies.

## Daemon fast path

Each visible `sessh` client is connected to a local daemon which also holds the
connection to the remote. When the local daemon sees the client die, it attempts
to send `RemoteProcessCleanupRequest` to the remote daemon, which will hang up
the remote process.

## Periodic scan

Daemons wake up every `cleanup-wakeup-interval-hours` to check if there are
stale remote processes, enqueueing `RemoteProcessCleanupRequest` messages onto
the same pooled transport machinery used by live sessh clients.

During cleanup the daemon scans durable cleanup records in the state directory.
Each record ties together three facts: the local process that originally owned
the session, the remote host endpoint, and the exact remote process/socket
identity that can be safely cleaned up later. The record is intentionally
durable because the cleanup path must survive local daemon death and laptop
reboot.

The cleaner reads each file one by one. If the local process still exists, it
skips ahead. Otherwise it makes sure there is a pooled transport for the remote
host and queues a cleanup request. The file stays in place until the remote
daemon replies; if the transport dies first, the next periodic scan retries.

If the receiving remote daemon owns the socket path specified in the request,
it will hang up the process directly. Otherwise it falls back to sending
`SIGHUP` directly after verifying the remote pid and start time. This is
intentionally a last-resort cross-version fallback; normally the daemon that owns
the process can perform a more ssh-shaped cleanup.

Once the process is signaled, or if it no longer exists,
`RemoteProcessCleanupResponse` is sent back, and the local side deletes the
file.

### Avoiding duplicate work

Daemons acquire a global flock so that only one does the work. Records older
than `cleanup-retry-limit-hours` are abandoned: the local side deletes the
record and stops trying to clean up that remote process.

As long as cleanup is required, at least one daemon must stay alive. An idle
daemon can shut down after it either loses the global cleanup flock to another
daemon or finishes the cleanup work it acquired the flock to perform.

Sessh avoids keeping idle daemons alive just to own cleanup. A daemon with live
local clients is the best owner for the global cleanup flock because it is
already doing useful work. Daemons with a local client therefore attempt to
acquire and hold the flock while that client is live. Daemons without a live
local client give up the flock as soon as they finish a round of cleanup
attempts.

## Disconnected Timeout

There is a setting (`disconnected-reap-hours`) controlling how long a remote
daemon should keep a process alive after the last disconnection.
