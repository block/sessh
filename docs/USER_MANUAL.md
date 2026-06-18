# Basic Usage

`sessh` is an `ssh`-shaped command with connection recovery:

```text
sessh [ssh-option ...] destination [command [argument ...]]
```

Interactive terminal-emulator sessions get the strongest recovery. When an ssh
option requires OpenSSH to own the visible session, sessh uses its ProxyCommand
stream path instead. If the remote OS/arch has no matching sessh binary, sessh
prints a warning and falls back to plain `ssh` without persistence.

If an interactive connection drops, sessh retries in the background and shows a
temporary overlay such as:

```text
--- sessh: disconnected: Retry connecting 10sec. CTRL-R now ---
```

`CTRL-R` asks sessh to switch to a prepared reconnect when one is available.
The ssh-style escape `Enter ~ .` closes the visible client.
There is intentionally no public resume/list/kill command surface.

# Options

Sessh accepts normal ssh options, plus a small set of sessh-specific options.
Sessh-specific options must appear before `destination`; after `destination`,
all tokens are treated as the remote command, matching `ssh`.

- `--log-level quiet|error|warn|info|debug|verbose`
- `--terminal-emulator` / `--no-terminal-emulator`
- `--filter-level unhygienic|hygienic|emulated`
- `--diagnostics-level overlay|status|title|line|jsonl`
- `--isolation-mode full|process|none`
- `--diagnostics-file PATH`
- `--capture-tty-transcript PATH.tar.gz`
- `--daemon-log`

`--filter-level emulated` is the default and naturally degrades when OpenSSH
must own the stream. `unhygienic` lets OpenSSH own the visible stream without
filtering, and `hygienic` uses the side-channel path when the visible client can
support it.

`--daemon-log` follows new local daemon log entries on stdout until stopped.

`--diagnostics-level` caps the richest diagnostics display method sessh may
use. `jsonl` is explicit-only and forces scriptable JSONL diagnostics.

`--diagnostics-file PATH` sends connection diagnostics to `PATH`.
If `PATH` is a terminal device, sessh can also read reconnect keystrokes from
it. If `PATH` is a normal file, sessh appends diagnostic lines there, creating
the file if necessary.

`--isolation-mode process` is the default. `full` uses a private local
daemon namespace for that invocation, so it does not pool TCP connections with
other sessh clients. `none` runs terminal/proxy work directly inside the shared
daemon, as described in
`docs/ARCHITECTURE.md`.

# Config File

The config file uses `.env` syntax:

- `$XDG_CONFIG_HOME/sessh/sessh.env`, or
- `~/.config/sessh/sessh.env`

Supported keys with defaults:

```dotenv
scrollback-limit=2000
client-log-level=warn
bootstrap=true
terminal-emulator=true
filter-level=emulated
diagnostics-level=overlay
isolation-mode=process
cleanup-wakeup-interval-hours=1
cleanup-retry-limit-hours=168
disconnected-reap-hours=168
```

`cleanup-wakeup-interval-hours` controls how often local daemons coordinate a
fallback cleanup scan. `cleanup-retry-limit-hours` controls how long the local
side keeps trying to clean up stale remote work after a local client
disappears. `disconnected-reap-hours` controls how long a remote session or
proxy stream may remain disconnected before the remote daemon hangs it up.
Values less than or equal to zero disable the relevant timeout.

# Sessions

Running `sessh HOST` starts the user's interactive login shell under a remote
PTY. Remote `sesshd` models that PTY's screen, terminal state, and retained
scrollback so the original client can recover after a disconnect.

Each session has an `s-`-prefixed GUID exported as `$SESSH_GUID`. The session
also exports `$SESSH_PATH`, the directory containing the sessh binary used by
remote `sesshd`, and prepends that directory to `$PATH`.

Available ssh-style escapes at the beginning of a line:

- `~.` disconnects the visible client.
- `~p` requests repaint.
- `~?` shows escape help.
- `~~` sends a literal `~`.

Reconnect uses non-interactive ssh authentication. If reconnect would require a
password or another interactive prompt, sessh exits instead of prompting through
the session stream.
