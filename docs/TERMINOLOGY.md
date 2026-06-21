# Terminology

Sessh has a few moving pieces with names that should stay boring and precise.
This file defines those names so source code, protocol comments, and docs do
not invent a new dialect every time they touch the architecture.

# Session

A session is one logical sessh-managed user operation.

A terminal-emulator session is a session where sessh owns the remote PTY and
translates terminal state into the terminal-emulator protocol. A proxy session
is a session where sessh carries opaque bytes between OpenSSH and the remote
sshd.

Both kinds of session are one-to-one with a visible client. The visible client
that starts a session is the client that owns it.

# Worker

A worker is the code, and sometimes the process, that owns the live remote side
of one session.

A terminal worker owns the remote PTY, terminal model, and requested process for
one terminal-emulator session. A proxy worker owns the remote side of one proxy
session and normally connects to localhost:sshd on the remote machine.

Workers can run inside `sesshd` or in a separate role-shaped process, depending
on `isolation-mode`. The term is about responsibility, not process placement.

# Transport And Tunnel

An ssh transport process is an `ssh` process spawned by sessh or `sesshd` to
carry bytes to the remote machine. It is a child process in the Unix process-tree
sense, but code should prefer `SshTransportProcess` unless parentage is the
point being discussed.

A daemon tunnel is the framed sessh protocol running over an ssh transport
process. The tunnel is multiplexed: it can carry multiple logical mux streams
over one transport.

A mux stream is one logical stream inside a daemon tunnel. Terminal-emulator
sessions and proxy sessions both use mux streams, but they are not themselves
called mux streams unless we are talking about the tunnel layer.

# Runtime Directories

Runtime is filesystem language only. Avoid using it for execution logic.

`xdg-runtime-dir` means the directory named by `XDG_RUNTIME_DIR`.

`sessh-runtime-dir` means the root directory sessh uses for live sockets and
process-local files. It is `xdg-runtime-dir` when that environment variable is
available, otherwise `/tmp/sessh-<uid>`.

A daemon namespace directory is the version-scoped directory under
`sessh-runtime-dir`, such as `3.dev.94dbb8bb/`. It contains `sesshd.sock` and
the role-shaped symlinks used to make process names clear.

Durable cleanup records are not runtime files. They live in the state directory
because they must survive daemon death and laptop reboot.

# Event Loops And Blocking Waits

Long-lived daemon work runs on the daemon dispatcher loop. Daemon-owned fds
should be registered with the dispatcher and advanced by small state-machine
callbacks. A daemon callback must not enter its own blocking wait, because that
would stop unrelated clients, tunnels, cleanup work, and log subscribers from
making progress.

`Blocking` is the explicit capability for a foreground blocking wait. Main and
tests create it; code that needs to wait synchronously must accept it in its
signature instead of quietly calling `poll(2)`, `sleep`, `waitpid`, or
`Child.run`.

`PROCESS_GLOBAL_REGISTRY` marks process-global state that is intentionally owned
by one single-threaded process. These registries let dispatcher callbacks,
cleanup, and idle shutdown observe the same live work without passing a large
registry object through every callback.

The process dispatcher is initialized by the entrypoint and accessed with
`dispatcher.get()`. Helpers should register fd/timer work on that dispatcher
instead of creating nested dispatchers.

Protocol frame IO should be dispatcher-owned or explicit foreground setup IO.
Daemon-owned protocol fds use `FrameReader`, `FrameWriteState`, or a queue from
fd callbacks. Blocking frame helpers belong in test support, not in the
production protocol API.
