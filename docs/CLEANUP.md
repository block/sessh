# Runtime dir

Our runtime dir (`$XDG_RUNTIME_DIR/sessh` or `/tmp/sessh-<uid>`) contains a
record of active clients/agents. When a process exits cleanly, it will remove
its record. This directory gets automatically cleaned upon reboot, which takes
care of any unclean exits.

We detect reboots by looking for the presence of the sessh runtime dir. If this
directory doesn't exist, it means sessh is running for the first time after
reboot, and we need to perform extra bookkeeping.

# State dir

Our state dir (`$XDG_STATE_DIR/sessh` or `~/.local/state/sessh/`) contains
records of the agents to which our clients are currently connected, or were
connected in the past (including tombstones of recently killed agents).

The state dir does NOT get cleaned upon reboot. This is important, because we
want to be able to see records of recent sessions, and possibly reconnect to
them.

`sesshmux list` will scan the state dir and clean old entries. We do this
automatically upon reboot. In the future we might do it periodically.

# Cache dir

The cache dir (`$XDG_CACHE_DIR/sessh` or `~/.local/cache/sessh`) contains
bootstrapped binaries. These are not automatically cleaned up, but we could
potentially keep track of binaries that haven't been used recently and delete
them.

# Cleaning up agents

Suppose you have 100 `sessh` connections to a remote server and then your
laptop dies. Similarly, suppose you have 100 detached `sessh` sessions running
on a remote server and you forgot about them. Without mindreading, `sessh`
can't discern whether you will ever re-attach to these sessions.

It would be bad if remote `sessh` agents continued to use resources on the
remote server indefinitely, `sessh` has a `reap-hours` setting (default 168
hours aka 1 week). Each `sessh` agent will automatically kill itself after
being disconnected for that length of time. 

`sessh` will attempt to proactively clean-up agents when it can:

1. Connection agent is no longer useful once the client dies.
2. It's possible to explicitly request a remote session agent to be killed via
   `~k`, `~.`, or `sesshmux kill`

## Blocking kills

`~k` and `sesshmux kill` are blocking kills: We'll send a signal to the remote
requesting the kill and wait for the ack. If `sessh` can't connect to the
remote it will display an error.

## Non-blocking kills

 `~.` is an escape code from `ssh`, so we attempt to preserve the same
behavior: We need to exit quickly. The same applies if we are exiting a
connection in response to a signal like SIGTERM.

Before exiting the client process, we make a best effort to kill the remote
agent, but we only wait 100ms in order to keep things snappy. If we don't get
an ACK in time, we write one pending request file under the pending directory
for the remote host GUID. The filename contains the target guid, so
enqueue naturally deduplicates without taking a lock or rewriting shared state.

When running `list --refresh`, we'll ask each reachable host for its live
connections before draining that host's pending kills. That ordering matters:
if a session has been attached since the kill was requested, the remote side can
decline the stale kill and the local client can drop the pending row without
tombstoning the session. We use advisory file-locking so simultaneous refreshes
do not all attempt the same kill work.

The pending directory for a host is keyed by an `h-` GUID reported by the
remote agent. The remote stores that GUID in its state directory, so different
local aliases, config files, or client machines can still agree that they are
talking to the same sessh host. A `meta.json` records the best-known connection
`name` and `port`; action files ignore it except as a fallback when there is no
cached route. Request files are currently named `kill-s-<guid>.json` or
`kill-p-<guid>.json`. Each entry has a local `type` field, currently `kill`,
plus the host GUID, target guid, and the time at which kill was requested.

We kill by invoking `sesshmux kill --jsonl --request {...} --request {...} ...`.
The local client converts the recorded request time into a request age before
sending it to the remote, so clock drift between the two machines does not make
freshly reattached sessions look stale. The remote output is jsonl describing
the result of each kill, allowing us to populate our local tombstones.

## Process death and reboots

Some signals cause our process to die without giving us a chance to intercept.
We also might not get any notice when a reboot happens.

We can infer this has happened when there is a record of a connection in our
state dir that refers to a non-existent pid, but this requires scanning our
state dir. We detect when a reboot occurred and queue all pre-existing
connections for cleanup.
