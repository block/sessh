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
You may re-attach or kill the session with `sesshmux`, documented below.

# Advanced Usage

You may provide extra parameters for advanced usage:

```text
sessh [sessh-options] [ssh-options] HOST [-- cmd arg...]
```

All sessh-specific options must appear before `HOST`.

## Mux Commands

Use `sesshmux` for session management:

- `sesshmux attach ID`: attach using a local alias, cached remote route, or
  session GUID.
- `sesshmux attach HOST ID`: attach by resolving `ID` on `HOST`.
- `sesshmux attach --host HOST [ID]`: attach by resolving `ID` on `HOST`, or
  attach to the most recent attachable session on `HOST` if `ID` is omitted.
- `sesshmux list HOST`: list attachable sessions on `HOST`.
- `sesshmux kill HOST ID`: terminate the specified session on `HOST`.
- `sesshmux kill --all HOST`: terminate all sessions on `HOST`.

For remote commands, pass ssh options before the host or through
`--ssh-options "..."`, for example `sesshmux list --ssh-options "-F cfg" HOST`.

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
- `--alias NAME`: choose the alias for a new session. Remote sessions register
  the alias on the remote host and cache a local route after the first attach.
- `--runtime-dir DIR`: choose the runtime directory for live sockets and agent
  files. The default is `$SESSH_RUNTIME_DIR` if set, otherwise
  `$XDG_RUNTIME_DIR/sessh` when that path is short enough for session sockets,
  otherwise `/tmp/sessh-<uid>`.

Persistent client aliases and remote routes are stored under XDG state:
`$XDG_STATE_HOME/sessh`, or `~/.local/state/sessh` if `XDG_STATE_HOME` is unset.

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

Aliases are convenience names for GUIDs. A local session created without
`--alias` defaults to the first UUID segment after the `s-` prefix. A remote
session created without `--alias` gets a short `r...` alias generated by the
remote host. Client attachments use `c-`-prefixed GUIDs internally, so aliases
that look like GUIDs or typed references such as `c-<uuid>` are reserved.
After you attach to a remote session, sessh caches a local route so
later `sesshmux attach ALIAS` can reconnect without restating the host. If
`sesshmux attach HOST ALIAS` resolves to a route for another host, sessh fails
instead of following that route.

## Reconnects

Reconnect uses non-interactive ssh authentication. If reconnect would require a
password or another interactive prompt, sessh exits instead of prompting
through the session stream. The session is still attachable with
`sesshmux attach HOST ID`.

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
