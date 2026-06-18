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

Both kinds of session are one-to-one with a visible client. Sessh does not have
the old sesshmux-style model where detached clients later attach to existing
remote sessions.

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
