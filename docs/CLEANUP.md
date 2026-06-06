# Cleanup

Sessh no longer has a public session manager. The visible client may disconnect
from its remote agent, and reconnect may recover the same session while the
original client is still alive. Detached remote sessions are not meant to be
resumed later by another command.

Remote session agents therefore clean themselves up with two mechanisms:

- A normal session exit removes live routing and runtime files.
- `reap-hours` lets an agent exit after it has been disconnected for too long.

`reap-hours` is recorded when the agent is created, so later config changes do
not rewrite the meaning of an existing session.

Future guardian-process work may add stronger cleanup for orphaned remote
processes. That should not reintroduce a public list/attach/kill surface.
