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

During cleanup the daemon scans the global `state/procs/` dir. Each file within
the procs dir is JSON, named `<guid>.json`; the filename is the resource
identity.  The file mtime is the recorded-at timestamp used for
`cleanup-retry-limit-hours`. The files are created atomically and are never
mutated other than being deleted. Each contains:

1. `local_pid`
2. `local_start_time`
3. `remote_user`
4. `remote_host`
5. `remote_port`
6. `remote_pid`
7. `remote_start_time`
8. `remote_socket_path`

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

Daemons acquire a global flock and update the file timestamp so that only one
does the work. Records older than `cleanup-retry-limit-hours` are abandoned:
the local side deletes the record and stops trying to clean up that remote
process.

As long as cleanup is required, at least one daemon must stay alive. A daemon
will shutdown when the following are satisfied:

1. It has no local client, and
2. Either:
   a) It has attempted, and failed, to acquire the global cleanup flock, or
   b) It has acquired the global cleanup flock and finished cleanup work

We'd prefer that we don't keep a daemon alive unnecessarily. If there is a
daemon that has local clients, it's better for it to acquire the global cleanup
flock. To achieve this, daemons with local client will attempt to acquire and
hold the global cleanup flock as long as they have a live local client. Daemons
without a live local client will give up the global cleanup flock as soon as
they finish a round of cleanup attempts.

## Disconnected Timeout

There is a setting (`disconnected-reap-hours`) controlling how long a remote
daemon should keep a process alive after the last disconnection.
