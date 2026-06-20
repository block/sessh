`sessh` delegates all networking to either `ssh` (for remote connections) or
unix-domain-sockets (for local connections).

`sessh` uses `ssh` in a way that causes special heuristics to kick in. Since we
allocate a PTY ourselves, we pass `-T` to disable PTY allocation. And we
specify a command for `ssh` to run. These things cause `ssh` to classify our
traffic as non-interactive. But that's not what we want: Our traffic is
interactive.

OpenSSH still disables Nagle's algorithm for this shape today, which keeps
interactive latency acceptable. If that changes, sessh will need to force
`TCP_NODELAY` another way, such as through an artificial `ProxyCommand`.

The other thing affected by non-interactive classification is our
[DSCP](https://en.wikipedia.org/wiki/Differentiated_services) setting. To work
around this, we run `ssh -G` and parse the output to learn the interactive DSCP
setting for the host as configured, then pass
`-oIPQoS=<interactive DSCP setting>` to `ssh`.

If the connection dies, the client will attempt a new connection, retrying
failed reconnections with exponential backoff.

Remote `sesshd` ACKs client input. After a timeout, if the client doesn't see
*any* messages from the terminal worker when there is unacknowledged input, then
the client will consider the connection unresponsive.

When the client detects that the connection is unresponsive it will attempt a
new connection. If the old connection recovers in the meantime, the client will
close the new connection.

See [RECONNECTION UX](RECONNECTION_UX.md) for details on the reconnection user
experience.
