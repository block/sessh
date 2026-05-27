`sessh` follows the
[XDG spec](https://specifications.freedesktop.org/basedir/latest/) for file
layout:

- `XDG_CONFIG_HOME` for user-defined `sessh` config (TODO: we should support `XDG_CONFIG_DIRS` too)
- `XDG_CACHE_HOME` for bootstrapping the binary when connecting to a new host
- `XDG_STATE_HOME` for client routes and session-agent logs
- `XDG_RUNTIME_DIR` for live session sockets and runtime identity.

# `XDG_RUNTIME_DIR`

We use `XDG_RUNTIME_DIR` for sessions, falling back to `/tmp/sessh-<uid>` if
`XDG_RUNTIME_DIR` is not defined. Since sessions never live through a reboot,
we want these to get cleaned up on reboot. The XDG spec guarantees this: "Files
in the directory MUST not survive reboot or a full logout/login cycle." If we
fall back to `/tmp/sessh-<uid>` we don't have this guarantee, though it's often
still true. The session agent will clean up old session directories upon a clean
exit.

Each session directory lives under `guid/` followed by the `s-`-prefixed guid
representation for the session. This directory includes:

- `agent.sock`: symlink to the real socket path under `s/`
- `meta.json`: runtime identity for the session agent (`agent_pid`, `version`)
- `compat`: symlink to the exact sessh binary for this session agent.

We use a symlink for `agent.sock` because Unix-domain socket path lengths are
platform-limited; for example, macOS `unix(4)` documents
`sockaddr_un.sun_path` as 104 bytes: https://manpages.org/unix/4

The actual socket path lives under `s/` followed by a compact representation of
the guid (or random hex bytes if `XDG_RUNTIME_DIR` is too long to allow the
full guid to fit).

The XDG spec explicitly permits periodic cleanup of files in `XDG_RUNTIME_DIR`,
and says runtime files should either have their access time updated at least
every 6 hours of monotonic time or have the sticky bit set:
https://specifications.freedesktop.org/basedir/latest/

Even when we fallback to `/tmp/sessh-<uid>` we need to protect against periodic
cleanup. For example MacOS will periodically delete files within /tmp that
haven't been recently accessed:
https://superuser.com/questions/187071/in-macos-how-often-is-tmp-deleted

To prevent live session directories from being deleted prematurely, each session
agent runs a daemon thread which touches its runtime files (including its socket
target) once per hour. We set the sticky bit too.

# `XDG_STATE_HOME`

Client routes and session-agent logs live under `guid/<session-guid>/`.
`route.json` stores the durable route. `agent.log` stores session-agent
diagnostics.
