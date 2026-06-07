# sesshd Coordinator Plan

This is the proposed architecture after removing `sesshmux` and the
session/proxy-stream runtime split. It intentionally describes the destination shape
before field numbers or exact file layout.

The important shift is that `sesshd` becomes the durable local process for
sessh. There is one `sesshd` per machine, listening on a global Unix domain
socket in the runtime directory. Public `sessh` invocations connect to that
socket, starting `sesshd` if needed. The coordinator role inside `sesshd`
replaces both old per-session and per-stream runtime processes.

`sesshd` should be a separate executable name, likely a symlink or hardlink to
the same binary as `sessh`. Daemon mode is invoked through the shared binary as
`sessh :internal-daemon:`. The process name matters: `killall sessh` should be
able to kill visible client processes without also killing the daemon that is
responsible for remote cleanup. `sesshd` is a per-user daemon, not a root/system
ssh server.

## Roles

The same `sesshd` process has different coordinator responsibilities depending
on where it is running.

On the client machine:

- accept local requests from `sessh` clients and ProxyCommand helpers
- maintain cleanup records in the client state directory
- maintain one coordinator tunnel per resolved remote host when possible
- multiplex logical streams over that tunnel
- reconnect tunnels and resume streams after connection loss
- detect local client death and request remote hangup for the matching stream

On the server machine:

- accept coordinator tunnels from client coordinators
- host terminal-emulator sessions directly
- open local connections to sshd for OpenSSH-owned proxy streams
- apply remote-side reap policy for sessions/streams that no longer receive
  client input
- hang up remote sessions/streams when requested by the client coordinator

There are no per-session or per-stream daemon processes in this architecture.

## Local Startup

Public `sessh` remains ssh-shaped. Early startup is:

1. `sessh` parses enough argv/config to know the filter level, host, command
   shape, tty state, and whether OpenSSH must own the visible connection.
2. `sessh` connects to the local `sesshd` socket.
3. If the socket is missing or stale, `sessh` starts `sesshd` and
   retries the connection.
4. The visible client either stays alive and talks to the coordinator, or execs
   OpenSSH with a ProxyCommand/ProxyUseFdpass helper that connects OpenSSH to
   the coordinator.

The local coordinator owns durable state and cleanup retries. The visible
client owns only user-facing terminal behavior while it is alive.

## Filter Levels

The coordinator architecture keeps `emulated`, `raw`, and `hygienic`.
`unhygienic` is removed. Its only purpose was best-effort diagnostics without a
local wrapper, and that is not worth carrying once diagnostics would require
extra daemon-to-tty machinery.

### Emulated

```
visible client <- uds -> client coordinator <- ssh tunnel -> server coordinator <- pty -> remote process
```

The visible client handles terminal input/output, overlays, repaint requests,
and local tty cleanup. The server coordinator owns the PTY and terminal model.
The client coordinator mostly forwards framed messages, but it also owns tunnel
sharing, reconnect, resume, and cleanup records.

### Raw

```
ssh <- uds/fdpass -> client coordinator <- ssh tunnel -> server coordinator <- localhost:sshd -> remote process
```

The visible `sessh` process execs OpenSSH. OpenSSH speaks to the client
coordinator through a ProxyCommand/ProxyUseFdpass socket. The server
coordinator opens one local connection to sshd per OpenSSH-visible logical
stream. Raw mode does not attempt user-facing diagnostics beyond normal OpenSSH
behavior.

### Hygienic

```
visible client <- pty -> ssh <- uds/fdpass -> client coordinator <- ssh tunnel -> server coordinator <- localhost:sshd -> remote process
```

The visible client wraps OpenSSH in a local PTY. That preserves the ability to
track terminal output, show replaceable connection status, and intercept
CTRL-R only while reconnect is available. The coordinator still owns the
network tunnel and stream resume.

## Local Client Protocol

The local client/coordinator connection uses the same stream item protocol as
the coordinator tunnel, but it is not multiplexed. Each local Unix socket
represents one request or one visible client stream, so the stream id can be
implicit on that local socket.

Candidate messages:

- `ClientOpenSession`: request a terminal-emulator session for a host
- `ClientOpenProxyStream`: request an OpenSSH-owned proxy stream for a host
- `ClientAttachProxyFd`: hand the coordinator the fd OpenSSH will use after
  ProxyUseFdpass
- `ClientDiagnosticCapabilities`: output mode and CTRL-R availability for
  visible-client and hygienic wrapper modes
- `ClientClose`, `ClientCtrlR`
- `CoordinatorSessionReady`, `CoordinatorProxyReady`
- `CoordinatorEnded`, `CoordinatorError`

Once a stream is open, payloads are ordered stream items. The current `Te*`
messages can remain recognizable, but they should become terminal-emulator
stream items, not runtime-private messages.

## Coordinator Tunnel Protocol

Coordinator-to-coordinator traffic is multiplexed. It should still use sessh's
length-prefixed frame mechanism, but the frame envelope should distinguish
tunnel control from stream payload.

Every stream frame carries a stream id. A stream id is scoped to one
coordinator tunnel and is not a durable GUID. Durable records may still include
an `s-` or `p-` GUID for cleanup and user diagnostics.

Candidate tunnel control messages:

- `TunnelHello`: coordinator identity, protocol version, supported features
- `TunnelResume`: tunnel generation, known live stream ids, last received
  offsets, and durable GUIDs that need cleanup
- `TunnelPing`, `TunnelPong`
- `TunnelGoAway`: graceful tunnel shutdown

Candidate stream messages:

- `StreamOpen`: stream id, durable GUID, stream kind, target, initial window
- `StreamOpenOk`
- `StreamData`: stream id, offset, bytes
- `StreamItem`: stream id, offset, encoded stream item bytes
- `StreamAck`: stream id, first unreceived offset, receive-window credit
- `StreamEof`: stream id, offset
- `StreamReset`: stream id, reason
- `StreamHangupRequest`: durable GUID, remote pid, remote start time
- `StreamHangupResult`: durable GUID, killed/missing/not-matching/failure

Proxy streams use `StreamData` with opaque bytes. Terminal-emulator sessions
use `StreamItem`, where each item is a length-delimited protobuf payload inside
the durable byte stream. The stream offset advances by encoded item bytes. This
gives terminal sessions the same byte-offset resume model as proxy streams
while preserving typed terminal messages.

Candidate terminal stream items:

- `TeInput`
- `TeInputAck`
- `TeResize`
- `TeRepaintRequest`
- `TeDraw`
- `TeRepaintResponse`
- `TeTtyTranscriptChunk`
- `StreamDiagnostic`

`StreamDiagnostic` is coordinator-injected. It is not remote process output.
The visible client interprets it and renders the appropriate local UI. It
should be structured, not a plain string, so clients can choose overlay, title,
or status-line presentation without parsing prose.

Candidate diagnostic shape:

- `kind`: `DISCONNECTED`, `CONNECTING`, `RECONNECTED`, `UNRESPONSIVE`,
  `RECONNECT_FAILED`, `CLEANUP_PENDING`
- `stream_guid`: durable stream/session GUID
- `attempt`: optional reconnect attempt number
- `next_retry_unix_ms`: optional absolute retry time
- `detail`: optional human text for logs or expanded diagnostics

The client coordinator can inject `DISCONNECTED`, `CONNECTING`, and
`RECONNECTED` items into terminal-emulator streams when the coordinator tunnel
drops and recovers. The server coordinator can inject remote-side diagnostics
when it owns the relevant state. These diagnostics flow through the same stream
protocol as terminal output, so reconnect UI does not need a side channel.

## Backpressure

Each logical stream has fixed-size buffers in both coordinators:

- outbound bytes accepted locally but not yet acknowledged by the peer
- inbound bytes received from the peer but not yet written to the local sink

When a stream's inbound buffer is full, the receiver stops granting credit for
that stream. The sender must stop sending data for that stream once its credit
is exhausted. Other streams on the same tunnel may continue to make progress.

This is why fairness matters. Without scheduling rules, one stream with a large
amount of ready output can keep filling the TCP socket and delay small
interactive streams behind it, even though each stream has its own buffer.
Fixed per-stream buffers prevent unbounded memory growth, but they do not by
themselves decide which ready stream gets the next tunnel frame.

Recommended first policy:

- keep a per-stream output queue bounded by the fixed buffer size
- when writing tunnel frames, round-robin across streams that have data and
  peer credit
- cap each write turn to a small chunk, for example 16 KiB or one frame
- prioritize control frames, acks, resets, and terminal input ahead of bulk
  output

That is enough to avoid obvious starvation without building a complex QoS
system. We can add weights later if port forwarding or large file transfers
make interactive sessions feel sluggish.

## Reconnect And Resume

The client coordinator owns reconnect for the coordinator tunnel. When the TCP
connection to the server coordinator is lost:

1. local visible clients stay connected to the client coordinator when their
   filter level allows it
2. streams stop accepting unlimited input once their fixed buffers fill
3. the client coordinator reconnects with exponential backoff
4. the new tunnel begins with `TunnelResume`
5. both sides compare stream ids, durable GUIDs, and byte offsets
6. each side retransmits unacknowledged bytes and resumes accepting new bytes

Proxy streams and terminal-emulator sessions both resume as durable streams
with byte offsets in each direction. Proxy stream bytes are the user's opaque
OpenSSH traffic. Terminal-emulator bytes are encoded stream items, including
terminal messages and coordinator-injected diagnostics.

For terminal-emulator sessions, stream offsets resume message delivery but do
not by themselves prove the visible terminal is visually correct. The server
coordinator still owns the PTY and terminal model, so the visible client keeps
the repaint protocol after reconnect or resize. The coordinator-injected
diagnostic items tell the visible client when to show disconnected, connecting,
and reconnected UI while the same durable stream catches up.

## Cleanup Records

Cleanup records live on the client machine in the state directory. They are
roughly the successor to the old route record: a durable description of remote
work the client coordinator is responsible for cleaning up.

A cleanup record should contain:

- durable GUID
- kind: terminal session or proxy stream
- resolved host identity used by the client coordinator
- remote pid
- remote process start time as an opaque string, captured from `ps`
- created time
- last local client connection state
- first cleanup-request time, if cleanup has started
- last cleanup-attempt time and retry state

When the local client or OpenSSH process disappears, the client coordinator
marks the record as cleanup-pending and sends a hangup request to the server
coordinator. The server coordinator only kills the remote pid if the pid's
startup-time string exactly matches the record. The string does not need to be
normalized across platforms because it is only compared with later observations
from the same remote machine. If the pid is missing, or the startup-time string
no longer matches, the remote process is already gone or the pid was reused,
and the client coordinator may delete the record.

The client coordinator deletes the cleanup record immediately after confirmed
hangup delivery. It does not need proof that the process was fully killed; it
only needs confirmation that the server coordinator delivered SIGHUP or the
chosen hangup action to the matching remote process.

On startup, the client coordinator scans cleanup records. Any pending record is
retried. Any non-pending record whose local owner is gone becomes pending.

## Remote Reaping

Remote reaping is separate from client cleanup. It exists for the case where
the client machine never reconnects.

The server coordinator records a remote-side timeout when it creates a session
or proxy stream. The `disconnected-reap-hours` timer starts when the
coordinator tunnel drops. If that timeout expires before the stream reconnects,
the server coordinator hangs it up and records the result locally long enough
to answer a later cleanup retry from the client coordinator.

The cleanup knobs are:

- `cleanup-retry-hours`: client-side duration for retrying cleanup requests
  before abandoning a cleanup record
- `disconnected-reap-hours`: remote-side duration a session or proxy stream may
  remain disconnected before the server coordinator hangs it up

A session that is connected but quiet should not be killed merely because the
user has not typed recently.

## State And Socket Layout

The coordinator needs a stable local socket. Candidate runtime layout:

- `sesshd.sock`: global per-user coordinator socket

All GUID-based socket names go away. The old `a/<compact-guid>` socket
namespace disappears, and the old `c/<compact-guid>` local
ProxyCommand rendezvous socket namespace is not part of the destination
architecture. Individual sessions and proxy streams are logical objects inside
coordinator connections, not filesystem sockets.

Durable state should move toward cleanup records and coordinator logs rather
than per-runtime route directories.

Resolved user/host/port is sufficient host identity for choosing a coordinator
tunnel. The system must tolerate duplicate TCP connections between the same two
coordinators. At worst, aliasing or resolution differences create more tunnels
than necessary; they must not compromise stream correctness or cleanup safety.

## Migration Order

1. Add the local `sesshd` process and socket startup path while keeping the
   current session/stream implementation behind it.
2. Move client-side cleanup records into the coordinator.
3. Move session/proxy-stream runtimes into remote coordinator-owned objects.
4. Introduce the multiplexed coordinator tunnel for proxy streams first.
5. Move terminal-emulator sessions onto the same tunnel.
6. Remove legacy per-object sockets, broker entrypoints, and per-runtime filesystem
   layout.
7. Collapse `sessh.proto` around two explicit protocol families:
   client/coordinator and coordinator/coordinator.

Proxy streams are the better first target because byte-offset resume is already
the natural model. Terminal-emulator sessions have repaint semantics layered on
top and should move after tunnel reconnect is solid.
