`sessh` delegates all networking to either `ssh` (for remote connections) or
unix-domain-sockets (for local connections).

`sessh` uses `ssh` in a way that causes special heuristics to kick in. Since we
allocate a PTY ourselves, we pass `-T` to disable PTY allocation. And we
specify a command for `ssh` to run. These things cause `ssh` to classify our
traffic as non-interactive. But that's not what we want: Our traffic is
interactive.

Even though our traffic is being classified as non-interactive, Nagle's
algorithm is still being disabled, according to my local testing. I ran `sessh`
with `-vvv` which gets forwarded to `ssh` and I see:

```
debug2: fd 7 setting TCP_NODELAY
```

This is good. If we see reports of `sessh` not disabling Nagle's algorithm then
we might need to insert an artificial `ProxyCommand` to force the TCP
connection to be `TCP_NODELAY`.

The other thing that being classified as non-interactive affects is our
[DSCP](https://en.wikipedia.org/wiki/Differentiated_services) setting. To
workaround this, we run `ssh -G` and parse the output to learn the interactive
DSCP setting for the host as configured, then pass
`-oIPQoS=<interactive DSCP setting>` to `ssh`.

If the connection dies, the client will attempt a new connection, retrying
failed reconnections with exponential backoff.

Remote `sesshd` ACKs client input. After a timeout, if the client doesn't see
*any* messages from the remote terminal process when there is unacknowledged input, then
the client will consider the connection unresponsive.

When the client detects that the connection is unresponsive it will attempt a
new connection. If the old connection recovers in the meantime, the client will
close the new connection.

See [RECONNECTION UX](RECONNECTION_UX.md) for details on the reconnection user
experience.
