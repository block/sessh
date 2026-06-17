# Processes and Threads

Sessh processes are single-threaded with non-blocking IO. Zig coroutine support
is still in flux, so we use explicit state machines to manage state in response
to file descriptors becoming readable/writable.

The processes involved depend on your `filter-level` and `isolation-mode`
settings, described below. The default settings are `filter-level=emulated` and
`isolation-mode=process`.

## Processes and Threads - filter-level=emulated

Under `filter-level=emulated` `sessh` runs the requested process within a
terminal emulator, which then communicates with the local client via a custom
protocol. If the `ssh` invocation does not create a remote PTY, such as for port
forwarding, there is no terminal stream for sessh to emulate. The connection
runs at `filter-level=unhygienic`.

The diagram below shows the default `isolation-mode=process` layout.

```
                            +--------+     unix     +--------+
                            | sessh  | <- domain -> | local  | 
                            | client |    socket    | sesshd |
                            +--------+              +--------+
                                                         ^
      local                                              |
    --------------- network boundary ---------------    ssh
      remote                                             |
                                                         v
                                                     +--------+
                                                     | sessh  |
                                                     | broker |
                                                     +--------+
                                                         ^
                                                         |
                                                    stdin/stdout
                                                         |
                                                         v
+-----------+    stdin     +----------+    unix      +--------+
| requested | <- stdout -> | sessh    | <- domain -> | remote |
| process   |    stderr    | terminal |    socket    | sesshd |
+-----------+              +----------+              +--------+
```

`sessh` will set up a connection to the local `sesshd` (creating it if
necessary). `sesshd` will communicate over a pooled connection to the broker,
which provides a bridge to the remote `sesshd`, which sets up the terminal
process, which creates the actual requested remote process (typically a shell).

The local `sesshd` process serves two purposes:
1. Watch for the `sessh` client to die, and signal the remote to clean up in
   response.
2. Pool connections

The broker process is needed to allow reconnecting to the same remote `sesshd`
in the event of `ssh` disconnecting.

## Processes and Threads - filter-level=hygienic

Under `filter-level=hygienic` `sessh` starts an `ssh` process and communicates
with it over stdin/stdout/stderr. `sessh` will allocate a PTY so that `ssh`
sees a PTY, but `sessh` can filter its output. If the `ssh` invocation does not
create a remote PTY, such as for port forwarding, there is no terminal stream to
filter. The connection runs at `filter-level=unhygienic`.

The diagram below shows the default `isolation-mode=process` layout.

```
+--------+    stdin     +-----+    stdin     +-------+     unix     +--------+
| sessh  | <- stdout -> | ssh | <- stdout -> | sessh | <- domain -> | sesshd |
| client | <- stdout -> |     |    stderr    | proxy |    socket    +--------+
+--------+    stderr    +-----+              +-------+
                                                                        ^
      local                                                             |
   ---------------------- network boundary ----------------------      ssh
      remote                                                            |
                                                                        v
                                                                    +--------+
                                                                    | sessh  |
                                                                    | broker |
                                                                    +--------+
                                                                        ^
                                                                        |
                                                                   stdin/stdout
                                                                        |
                                                                        v
            +-----------+    stdin     +----------+      tcp        +--------+
            | requested | <- stdout -> | sshd     | <- localhost -> | remote |
            | process   |    stderr    |          |    port 22      | sesshd |
            +-----------+              +----------+   (typically)   +--------+
```

## Processes and Threads - filter-level=unhygienic

This is like `filter-level=hygienic` but the outer `sessh` is replaced by `ssh`
via `exec(2)`. There is no PTY filtering.

The diagram below shows the default `isolation-mode=process` layout.

```
                        +-----+    stdin     +-------+     unix     +--------+
                        | ssh | <- stdout -> | sessh | <- domain -> | sesshd |
                        |     |    stderr    | proxy |    socket    +--------+
                        +-----+              +-------+
                                                                        ^
      local                                                             |
   ---------------------- network boundary ----------------------      ssh
      remote                                                            |
                                                                        v
                                                                    +--------+
                                                                    | sessh  |
                                                                    | broker |
                                                                    +--------+
                                                                        ^
                                                                        |
                                                                   stdin/stdout
                                                                        |
                                                                        v
            +-----------+    stdin     +----------+      tcp        +--------+
            | requested | <- stdout -> | sshd     | <- localhost -> | remote |
            | process   |    stderr    |          |    port 22      | sesshd |
            +-----------+              +----------+   (typically)   +--------+
```

`sessh :proxy:` will send its stderr file-descriptor to the local `sesshd` via
unix-domain-socket ancillary data, but we can't see what `ssh` is
reading/writing to the TTY. Any diagnostics `sesshd` writes will be blindly
interleaved with the normal TTY output. This is why the mode is named
`unhygienic`.

The benefit of `unhygienic` is lower overhead. The lack of hygiene is not
necessarily a problem. If it is, you can disable output with
`--no-diagnostics`.

If the requested `ssh` command doesn't use stdin (e.g. port forwarding) then we
can potentially use stdin ourselves (assuming its a TTY), allowing us to show
richer diagnostic information, such as prompting the user to type CTRL-R to
attempt reconnection immediately.

## Isolation modes

`sessh` is designed to be robust in the face of `ssh` disconnections, but not
necessarily in the face of other `sessh` processes crashing. `isolation-mode`
can be one of `full`, `process`, or `none`.

| `isolation-mode` | Connection pooling | Terminal/proxy functionality |
| --- | --- | --- |
| `full` | Disabled | Handled directly within a unique `sesshd` for this invocation. |
| `process` | Enabled | Handled by separate terminal/proxy processes so we can recover even if the shared `sesshd` dies. |
| `none` | Enabled | Handled directly within the shared `sesshd`. |

When proxy functionality is handled directly within `sesshd` we use
`ProxyUseFdPass`. The `sessh` `ProxyCommand` process runs briefly to set up the
unix-domain-socket connection to the local `sesshd`, then passes that
file-descriptor back to `ssh` and exits. After that `ssh` communicates directly
with the local `sesshd` process. Under `isolation-mode=process`, the proxy
functionality lives in a separate process and `ProxyUseFdPass` is not used.

## Manual ProxyCommand

You can use `sessh :proxy:` as your `ssh_config(5)` `ProxyCommand`. In this
case your `filter-level` is effectively `unhygienic`. If you set
`ProxyUseFdPass` then you must pass `--use-fd-pass` to `sessh :proxy:`. If you
do not pass `--use-fd-pass`, `sessh :proxy:` uses the normal `ProxyUseFdPass=no`
stdin/stdout protocol.

You can control whether the proxy uses a shared daemon with
`--isolation-mode=full`, `--isolation-mode=process`, or `--isolation-mode=none`.
`full` uses a private daemon namespace for this connection.

`sessh :proxy:` has a `--stdin-from-stderr` option. When passed, and when stderr
is a TTY, it opens that same TTY as a control input for reconnect keystrokes
while keeping stdin/stdout reserved for the SSH proxy byte stream. If stderr is
not a TTY, the flag does nothing. The outer `sessh` only passes this flag after
checking that stdin and stderr refer to the same TTY. You should not hard-code
`--stdin-from-stderr` inside an `ssh_config(5)` alias, because you cannot know
ahead of time whether ssh will be run with stdin redirected, but you can use it
one-off via `SESSH_STDIN_FROM_STDERR=1 ssh ...`.


# Other Docs

Networking behavior is documented in [NETWORKING](NETWORKING.md). Runtime and
state layout is documented in [FILESYSTEM_LAYOUT](FILESYSTEM_LAYOUT.md).
