# Basic Usage

`sessh` is a drop-in replacement for `ssh` with seamless connection recovery. 
The command-line interface is the same as `ssh`. You can use `sessh` exactly
like `ssh`:

```text
sessh [ssh-option ...] destination [command [argument ...]]
```

`sessh` connection recovery is limited to interactive use cases (when no
command is provided). Non-interactive invocation will cause `sessh` to fallback
to plain `ssh`.

If the `ssh` disconnects while `sessh` is running interactively then it will
retry the connection in the background (with exponential backoff) and reattach
to the same session. While disconnected, `sessh` shows a temporary banner:

```text
--- sessh: disconnected: Retry connecting 10min. CTRL-R now. CTRL-C detach ---
```

`sessh` will switch to prepared connections automatically when it can do so
without a confusing user experience. Otherwise it displays a temporary banner
like:

```text
--- sessh: disconnected: Connection ready. CTRL-R switch. CTRL-C detach ---
```

Even if you detach during reconnect, the session will remain running on the remote.
You may re-attach or kill the session with `sesshmux`, documented below.

# Advanced Usage

You may provide extra parameters for advanced usage:

```text
sessh [[ssh-option|sessh-option] ...] destination [command [argument ...]]
```
- `--alias NAME`: choose the alias for a new session. Remote sessions register
  the alias on the remote host and cache a local route after the first attach.
- `--log-level quiet|error|warn|info|debug|verbose`: override
  `client-log-level` for the local client.
- `--force-compat`: run the compat-fallback path immediately, without first
  trying the normal bootstrap/runtime path.

Sessh-specific behavior is configured in the config file documented below.

## Config file

The config file uses `.env` syntax. It can specify sessh-specific options, but
not arbitrary ssh options. `client-log-level` can be overridden with
`--log-level`; the other keys are config-only.

The default config path follows the XDG spec. If `$XDG_CONFIG_HOME` is defined:
`$XDG_CONFIG_HOME/sessh/sessh.env`. Otherwise: `~/.config/sessh/sessh.env`

See [FILESYSTEM LAYOUT](FILESYSTEM_LAYOUT.md) for details about other
directories used by sessh.

Config keys are case-insensitive. Supported keys with their default values:

```dotenv
leader=None
scrollback-limit=2000
initial-scrollback=-1
client-log-level=warn
bootstrap=true
```

- `leader`: set the leader key for client commands or disable with `None`. The
  leader key is must be in the form `CTRL-<letter>`.
- `scrollback-limit`: set the maximum number of retained scrollback lines.
- `initial-scrollback`: set how many retained scrollback lines are drawn when
  attaching to an existing session. `-1` means all retained scrollback, `0`
  means draw only the current screen.
- `client-log-level`: configure client logging level. Supported values
  are `quiet`, `error`, `warn`, `info`, `debug`, and `verbose`. If unset, sessh
  infers `info`, `debug`, or `verbose` from `-v`, `-vv`, or
  `-vvv`; otherwise it defaults to `warn`. Client logs will be buffered while
  attached and displayed upon detach.
- `bootstrap`: enable or disable loading the `sessh` binary onto hosts. If
  disabled, `sessh` will attempt to find itself remotely in `$PATH`.

## Mux Commands

Use `sesshmux` for session management:

- `sesshmux attach ID`: attach using a local alias, cached remote route, session
  GUID, or unique `s-` GUID prefix.
- `sesshmux attach --host HOST [ID]`: attach by resolving `ID` on `HOST`, or
  attach to the most recent attachable session on `HOST` if `ID` is omitted.
- `sesshmux list [--refresh] [--jsonl] [HOST]`: list attachable sessions locally or on
  `HOST`. Without `HOST`, local sessions and cached remote routes are shown.
  Use `sesshmux list .` to show only local sessions. `--refresh` checks cached
  remote routes that were alive the last time sessh checked them. Without
  `--refresh`, cached remote status such as attached count and input time may be
  stale. `--jsonl` emits one JSON object per session.
- `sesshmux kill [HOST] ID`: terminate the specified local or remote session.
- `sesshmux kill --all [HOST]`: terminate all local sessions or all sessions on
  `HOST`.

For remote commands, pass ssh options through `--ssh-options "..."`, for
example `sesshmux list --ssh-options "-F cfg" HOST`.

## Diagnostics

- `--capture-tty-transcript PATH.tar.gz`: capture raw outer terminal and inner
  PTY byte streams for debugging. This can record secrets and private terminal
  contents. The transcript is buffered in memory and flushed to the specified
  path upon clean exit.

## Sessions

Running `sessh HOST` starts the user's interactive login shell under a remote
PTY. The session agent models that PTY's screen, terminal state, and retained
scrollback so the session can be reattached after a disconnect.

Each sessh session has a stable `s-`-prefixed GUID, stored in the environment
variable `$SESSH_GUID`. This lets shells, prompts, and scripts tell whether
they are running inside `sessh` and which session they are in.

The session also exports `$SESSH_PATH`, the directory containing the `sesshmux`
binary used by the session agent. `sessh` appends that directory to `$PATH` so
commands inside the session can invoke `sesshmux`.

Each attached client uses a `c-`-prefixed GUID.

When creating a new session, you can specify a custom alias with `--alias`. Any
valid filename is allowed except

1. Neither of the first two characters can be `-`
2. `/` is not allowed.

If you don't specify one, `sessh` generates a 10-character alias
such as `s-550e8400`.

After you attach to a remote session, sessh caches a local route so later
`sesshmux attach ALIAS` can reconnect without restating the host. If
`sesshmux attach --host HOST ALIAS` resolves to a route for another host, sessh
fails instead of following that route.

## Reconnects

Reconnect uses non-interactive ssh authentication. If reconnect would require a
password or another interactive prompt, sessh exits instead of prompting
through the session stream. The session is still attachable with
`sesshmux attach ID`.

## Interacting with attached sessions

You may detach from a session in any of 3 ways:

1. The standard ssh disconnect key sequence: `Enter ~ .`
2. If you have defined a leader: `<leader> d` (same as tmux)
3. While the session is reconnecting: `<CTRL-C>`

After detaching, sessh will print the command to re-attach to that session.

If you have a leader defined, there are two additionals commands available:

1. You may request repaint: `<leader> r`. This will erase your current
   scrollback and draw all available scrollback, followed by the current
   screen. This is primarily useful if you have set initial-scrollback to a
   value >=0 and you want to see the rest of scrollback.
2. You may simulate network disconnection: `<leader> s`. You can use this to
   see `sessh` reconnections in action.

## Plain-SSH-Fallback and Compat-Fallback

`sessh` falls back to plain-ssh when:

1. remote OS/arch is unsupported, or
2. an incompatible `ssh` option is passed

Under plain-ssh-fallback, `sessh` will print a warning to stderr and then
delegate to ordinary `ssh`, which means there will be no session persistence.

If the remote session agent is an incompatible `sessh` version, `sessh` may use
compat-fallback: it runs the remote compat binary that started that session,
and that remote sessh client talks to the agent with the protocol it knows. If
doing that automatically would require another interactive ssh authentication
prompt, sessh exits instead of prompting through the session stream.

`--force-compat` runs the compat-fallback path immediately, without first
trying the normal bootstrap/runtime path.

## Local mode

You may specify `.` in place of host to use `sessh` locally without
`ssh`. This mode is a super-primitive version of `tmux`/`screen`, but with
native scrolling and mouse behavior. It's not very useful by itself, but that's
how we support the compat-fallback path documented above.
