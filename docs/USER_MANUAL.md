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

Sessh accepts normal ssh options, plus a small set of sessh-specific options:

- `--log-level quiet|error|warn|info|debug|verbose`
- `--terminal-emulator` / `--no-terminal-emulator`
- `--filter-level raw|hygienic|emulated`
- `--capture-tty-transcript PATH.tar.gz`

`--filter-level emulated` is the default and naturally degrades when OpenSSH
must own the stream. `raw` suppresses reconnect diagnostics, and `hygienic`
uses the side-channel path when the visible client can support it.

# Config File

The config file uses `.env` syntax:

- `$XDG_CONFIG_HOME/sessh/sessh.env`, or
- `~/.config/sessh/sessh.env`

Supported keys with defaults:

```dotenv
scrollback-limit=2000
initial-scrollback=-1
client-log-level=warn
bootstrap=true
terminal-emulator=true
filter-level=emulated
cleanup-retry-hours=168
disconnected-reap-hours=168
```

`cleanup-retry-hours` controls how long the client-side daemon retries remote
cleanup after a local client disappears. `disconnected-reap-hours` controls how
long a remote session or proxy stream may remain disconnected before the remote
daemon hangs it up. Values less than or equal to zero disable the relevant
timeout.

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
