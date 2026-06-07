# Cleanup

Sessh no longer has a public session manager. The visible client may disconnect
from its remote runtime, and reconnect may recover the same session while the
original client is still alive. Detached remote sessions are not meant to be
resumed later by another command.

Remote work is cleaned up with two mechanisms:

- A normal session exit removes live routing and runtime files.
- `cleanup-retry-hours` limits how long the client-side daemon retries cleanup
  after a local client disappears.
- `disconnected-reap-hours` lets remote work exit after its coordinator tunnel
  has been disconnected for too long.

`disconnected-reap-hours` is recorded when the remote work is created, so later
config changes do not rewrite the meaning of an existing session.

Future guardian-process work may add stronger cleanup for orphaned remote
processes. That should not reintroduce a public list/attach/kill surface.
