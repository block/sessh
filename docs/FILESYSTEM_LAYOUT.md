`sessh` follows the
[XDG spec](https://specifications.freedesktop.org/basedir/latest/) for file
layout:

- `XDG_CONFIG_HOME` for user-defined `sessh` config (TODO: we should support `XDG_CONFIG_DIRS` too)
- `XDG_CACHE_HOME` for bootstrapping the binary when connecting to a new host
- `XDG_STATE_HOME` for client routes and session-agent logs
- `XDG_RUNTIME_DIR` for live agent sockets and runtime identity.

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

- `agent.sock`: symlink to the real socket path under `a/`
- `meta.json`: runtime identity for the session agent (`type`, `created_at_unix_ms`, `agent_pid`, `version`)
- `compat`: symlink to the exact sessh binary for this session agent.

We use a symlink for `agent.sock` because Unix-domain socket path lengths are
platform-limited; for example, macOS `unix(4)` documents
`sockaddr_un.sun_path` as 104 bytes: https://manpages.org/unix/4

The actual agent socket path lives under `a/` followed by a compact
representation of the guid (or random hex bytes if `XDG_RUNTIME_DIR` is too
long to allow the full guid to fit). Both terminal-emulator session agents and
proxy stream agents use this namespace.

Client-side sockets for local client-to-ProxyCommand coordination live under
`c/` followed by the same compact-guid naming scheme. These sockets are owned
by the local client process and are separate from remote agent sockets under
`a/`.

Runtime guid directories include small metadata files so `sesshmux list --all`
can explain what each live guid represents. Local session directories use
`meta.json` with `type: local-session`. Client and proxy stream
directories can be owned from both sides of a connection at once, so each side
writes its own file: `incoming-meta.json` for incoming entries and
`outgoing-meta.json` for outgoing entries. Proxy streams use `p-` GUIDs.
Teardown removes only the metadata file it owns; the
last side to leave removes the now-empty directory.

On the session host, each client hint contains an `agent.sock` symlink to the
session agent so commands like `sesshmux detach c-...` can reach the right agent
without scanning every session. On the client machine, remote sessions also use
the same directory for a `route.json` symlink to the durable route in
`XDG_STATE_HOME`, so the command can first hop to the right host. The hints are
removed when that client detaches.

Remote sessions themselves are not runtime guid entries on the client machine;
they are durable routes in `XDG_STATE_HOME`.

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

Exited sessions move out of `guid/` into `tombstone/<session-guid>.json`.
Tombstones keep the display route, aliases that pointed at the session, end
time, end reason, expiration time, and exit or signal status when available.
The expiration time is derived from the `tombstone-hours` value recorded in the
route when the agent was created.

Queued remote cleanup lives beside tombstones under `pending/`. Each resolved
ssh endpoint gets a directory. Sessh asks `ssh -G` for the endpoint name and
port so aliases that resolve to the same place share cleanup. Safe endpoint
names use a readable `<name>-<port>` directory; unsafe names fall back to
`:<sha256(name, port)>`. The directory has a `meta.json` with `name` and
`port`, and entries inside are one JSON file per request, such as
`kill-s-<guid>.json` or `kill-p-<guid>.json`. The filename deduplicates
repeated requests without any enqueue-time lock. Entry JSON has a local `type`
field so future clients can add other bookkeeping. Today `type: "kill"` entries
contain the resolved host, port, an `s-` session or `p-` proxy-stream GUID, and
when the kill was requested. The client draining a host takes that host
directory's lock and removes only the request files it handled.
