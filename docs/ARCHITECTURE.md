# Architecture

The path when sessh connects to a remote for the first time (simplified):

1. sessh client invokes `ssh <HOST> <script>`.
2. The script (i.e. the bootstrapper) runs on the remote, reading
   newline-separated commands from stdin.
3. The client tells the script to execute a binary, identified by a list of
   sha256sums (there are multiple because the client doesn't yet know the
   remote os/arch)
4. The script writes to stdout, telling the client that it doesn't have the
   binary, but informing it of its os/arch.
5. The client sends the base64-encoded binary for the given os/arch.
6. The script saves the binary, writes OK to stdout, and executes the binary
   (the binary is running in host-broker mode)
7. The client sees the OK, switches to a protobuf-based protocol, and sends a
   request for the remote to start a new session.
8. The host-broker reads the request, and fork/execs itself (the
   binary is running in session-agent mode)
9. The session-agent creates a unix domain socket and listens for requests.
10. The host-broker connects to the unix domain socket and relays messages
   between the socket and its stdin/stdout (i.e. back to the client)
11. The session-agent allocates a PTY and implements a
    [headless terminal emulator](TERMINAL_EMULATOR.md) using libghostty-vt.
12. The client and session-agent exchange messages. The client forwards its
    stdin while the session-agent sends rendering instructions (in the form of
    ASCII and escape codes)

The same `sessh` binary supports all three modalities: client,
host-broker, and session-agent.

Networking behavior is documented in [NETWORKING](NETWORKING.md).
