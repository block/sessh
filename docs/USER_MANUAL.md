# Basic Usage

`sessh` is a drop-in replacement for `ssh` with seamless connection recovery. 
The command-line interface is the same as `ssh`. Extra parameters are
available, but they are for advanced use. You can use `sessh` exactly like
`ssh`:

```text
sessh [ssh-option ...] destination [command [argument ...]]
```

`sessh` connection recovery is limited to interactive use cases (when no
command is provided). Non-interactive invocation will cause `sessh` to fallback
to plain `ssh`.

If the `ssh` disconnects while `sessh` is running interactively then it will
automatically reconnect (with exponential backoff) and reattach to the same
session. While disconnected, `sessh` shows a temporary banner. The banner
disappears when `sessh` successfully reconnects.

```text
--- sessh: disconnected. Retry in 10min. SPACE retries now. CTRL-C aborts ---
```

Even if you abort the reconnect, the session will remain running on the remote.
You may re-attach (with `--attach`) or kill the session (with `--kill`). Both
are documented below.

# Advanced Usage

You may provide extra parameters for advanced usage:

```text
sessh [ssh-options] HOST [sessh-options]
```

## Action-type parameters

- `--attach [ID]`: attach to an existing session. Without an id, attach to the
  most recent attachable session
- `--list`: list attachable sessions.
- `--kill ID`: terminate the specified session.
- `--kill-all`: terminate all sessions on the host.

## Config file

The config file uses `.env` syntax. It can specify defaults for sessh-specific
options, but not arbitrary ssh options. Command-line arguments always win over
config values.

The default config path follows the XDG spec. If `$XDG_CONFIG_HOME` is defined:
`$XDG_CONFIG_HOME/sessh/sessh.env`. Otherwise: `~/.config/sessh/sessh.env`

Config keys are case-insensitive, and underscores may be used instead of
hyphens. Supported keys with their default values:

```dotenv
leader=None
scrollback-limit=2000
initial-scrollback=-1
client-log-level=warn
bootstrap=true
```

- `leader`: set the leader key for client commands or disable with `None`. The leader key is must be in the form `CTRL-<letter>`.
- `scrollback-limit`: set the maximum number of retained scrollback lines.
- `initial-scrollback`: set how many retained scrollback lines are drawn when
  attaching to an existing session. `-1` means all retained scrollback, `0`
  means draw only the current screen.
- `client-log-level`: configure client logging level. Supported values
  are `quiet`, `error`, `warn`, `info`, `debug`, and `verbose`. If unset, the
  ssh transport infers `info`, `debug`, or `verbose` from `-v`, `-vv`, or
  `-vvv`; otherwise it defaults to `warn`. Client logs will be buffered while
  attached and displayed upon detach.
- `bootstrap`: enable or disable loading the `sessh` binary onto hosts. If
  disabled, `sessh` will attempt to find itself remotely in `$PATH`.

## Option-type parameters

The options in the config file can be overridden on the command-line:

- `--leader`
- `--scrollback-limit`
- `--initial-scrollback`
- `--log-level`
- `--bootstrap` or `--no-bootstrap`

## Sessions

Running `sessh HOST` starts the user's interactive login shell under a remote
PTY. The session agent models that PTY's screen, terminal state, and retained
scrollback so the session can be reattached after a disconnect.

Each sessh PTY has `$SESSH_ID` set to its session id. This lets shells,
prompts, and scripts tell whether they are running inside `sessh` and which
session they are in.

## Reconnects

Reconnect uses non-interactive ssh authentication. If reconnect would require a
password or another interactive prompt, sessh exits instead of prompting
through the session stream. The session is still attachable with a later
`sessh HOST --attach`.

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

You may specify `:local:` in place of host to use `sessh` locally without
`ssh`. This mode is a super-primitive version of `tmux`/`screen`, but with
native scrolling and mouse behavior. It's not very useful by itself, but that's
how we support the compat-fallback path documented above.
