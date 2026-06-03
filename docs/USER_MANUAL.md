# Basic Usage

`sessh` is a drop-in replacement for `ssh` with seamless connection recovery. 
The command-line interface is the same as `ssh`. You can use `sessh` exactly
like `ssh`:

```text
sessh [ssh-option ...] destination [command [argument ...]]
```

`sessh` connection recovery is strongest for terminal-emulator sessions. When
the terminal emulator is disabled, sessh uses a ProxyCommand-based stream so
OpenSSH owns ssh semantics directly, including PTY allocation for tty-shaped
commands. If the remote OS/arch has no matching sessh binary, sessh warns and
falls back to plain `ssh` without persistence.

If the `ssh` disconnects while `sessh` is running interactively then it will
retry the connection in the background (with exponential backoff) and reattach
to the same session. While disconnected, `sessh` shows a temporary overlay:

```text
--- sessh: disconnected: Retry connecting 10min. CTRL-R now. CTRL-C detach ---
```

`sessh` will switch to prepared connections automatically when it can do so
without a confusing user experience. Otherwise it displays a temporary overlay
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
- `--terminal-emulator` / `--no-terminal-emulator`: enable or disable sessh's
  terminal emulator for this connection. Disabling it uses a stream path instead
  of sessh's terminal renderer, which better preserves terminal features sessh
  does not model. The stream path uses a ProxyCommand transport and lets the
  visible `ssh` process own PTY allocation. The positive form is mainly useful
  for overriding config.
- `--filter-level raw|unhygienic|hygienic|emulated`: choose the maximum level of
  stream filtering sessh may apply. `emulated` is the default terminal-emulator
  UI and naturally degrades to `hygienic` when an ssh option requires OpenSSH to
  own the outer session. `hygienic`, `unhygienic`, and `raw` force the
  ProxyCommand-based stream path. `raw` suppresses reconnect diagnostics,
  `unhygienic` prints direct stderr diagnostics with CRLF line endings, and
  `hygienic` uses the side-channel path when the visible client can support it.

Sessh-specific behavior is configured in the config file documented below.

## Config file

The config file uses `.env` syntax. It can specify sessh-specific options, but
not arbitrary ssh options. Some keys also have command-line overrides for a
single invocation.

The default config path follows the XDG spec. If `$XDG_CONFIG_HOME` is defined:
`$XDG_CONFIG_HOME/sessh/sessh.env`. Otherwise: `~/.config/sessh/sessh.env`

See [FILESYSTEM LAYOUT](FILESYSTEM_LAYOUT.md) for details about other
directories used by sessh.

Config keys are case-insensitive. Supported keys with their default values:

```dotenv
scrollback-limit=2000
initial-scrollback=-1
client-log-level=warn
bootstrap=true
terminal-emulator=true
filter-level=emulated
```

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
- `terminal-emulator`: enable or disable sessh's terminal emulator by default.
  `false`/`no` and `true`/`yes` are accepted. Disabling it is equivalent to
  passing `--no-terminal-emulator`; `--terminal-emulator` enables it for a
  single invocation.
- `filter-level`: configure the default stream filtering level. Supported
  values are `raw`, `unhygienic`, `hygienic`, and `emulated`. The command-line
  `--filter-level` option overrides it for a single invocation.

## Mux Commands

Use `sesshmux` for session management:

- `sesshmux attach ID`: attach using a local alias, cached remote route, session
  GUID, or unique `s-` GUID prefix.
- `sesshmux attach --host HOST [ID]`: attach by resolving `ID` on `HOST`, or
  attach to the most recent attachable session on `HOST` if `ID` is omitted.
- `sesshmux force-compat --host HOST ID command ...`: run `command ...` through the
  exact sessh binary that started `ID`. If `ID` has a cached remote route, the
  `--host HOST` part can be omitted.
- `sesshmux list [--refresh] [--exited] [--jsonl] [HOST]`: list attachable sessions locally or on
  `HOST`. Without `HOST`, local sessions and cached remote routes are shown.
  Use `sesshmux list .` to show only local sessions. `--refresh` checks cached
  remote routes that were alive the last time sessh checked them. Without
  `--refresh`, cached remote status such as attached count and input time may be
  stale. `--exited` shows recently exited sessions instead of live sessions,
  including exit code, signal, or kill status when sessh observed it. Exited
  sessions are retained for one week and cleaned up by `list`; with `--refresh`,
  remote tombstones are cleaned up too. `--jsonl` emits one JSON object per
  session in the selected live/exited mode.
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

You may detach from a session in either of 2 ways:

1. The ssh-style escape sequence: `Enter ~ d`
2. While the session is reconnecting: `<CTRL-C>`

After detaching, sessh will print the command to re-attach to that session.

Additional ssh-style escape sequences are available at the beginning of a line:

1. `~.` requests that the sessh session be killed and detaches immediately. If
   the remote host is unreachable, sessh records the kill request locally and
   sends it automatically the next time you connect to that host.
2. `~k` requests that the sessh session be killed and waits until the remote
   host confirms the kill. While waiting, `~.` detaches immediately; the kill
   request remains queued.
3. `~p` requests repaint. This erases your current scrollback and draws all
   available scrollback, followed by the current screen. This is primarily
   useful if you have set initial-scrollback to a value >=0 and you want to see
   the rest of scrollback.
4. `~?` shows escape help.
5. `~~` sends a literal `~`.

## Plain SSH and Compat-Fallback

`sessh` falls back to plain ssh when the remote OS/arch has no matching sessh
binary. In that case there is no remote sessh program to run, so `sessh` prints
a warning to stderr and delegates to ordinary `ssh` without session
persistence.

SSH options that require OpenSSH to own the session use the ProxyCommand stream
path instead of plain-ssh fallback.

If the remote session agent is an incompatible `sessh` version, `sessh` may use
compat-fallback: it runs the remote compat binary that started that session
(over plain ssh), and that remote sessh client talks to the agent with the
protocol it knows.

`sesshmux force-compat --host HOST ID command ...` is the manual version of
that escape hatch. It resolves the session's `compat` binary on the remote host,
then runs the requested mux command through that binary.

## Local mode

You may specify `.` in place of host to use `sessh` locally without
`ssh`. This mode is a super-primitive version of `tmux`/`screen`, but with
native scrolling and mouse behavior. It's not very useful by itself, but that's
how we support the compat-fallback path documented above.
