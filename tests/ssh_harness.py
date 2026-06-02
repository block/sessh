#!/usr/bin/env python3
import hashlib
import fcntl
import json
import os
import pty
import re
import select
import shlex
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import termios
import time
from pathlib import Path

from harness_cleanup import cleanup_runtime, sessions_dir
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("SESSH_BIN", str(ROOT / "zig-out" / "bin" / "sessh")))
DEFAULT_MUX_BIN = BIN if BIN.name == "sesshmux-dev" else BIN.with_name("sesshmux")
MUX_BIN = Path(os.environ.get("SESSHMUX_BIN", str(DEFAULT_MUX_BIN)))
GUID_RE = re.compile(r"^s-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
COMPACT_GUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")


def sessh_argv(args):
    if BIN.name == "sesshmux-dev":
        return [str(BIN), ":internal-sessh:", *args]
    return [str(BIN), *args]


FAKE_SSH = """#!/bin/sh
set -eu

saw_t=0
request_tty=0
config_query=0
host=
config=
batch_mode=0
verbose=
plain_option=
ipqos_option=
proxy_command=
x11_option=
agent_option=
forward_option=
forward_value=

trace_fake_ssh_start() {
  if [ -n "${SESSH_FAKE_SSH_TRACE:-}" ]; then
    {
      printf 'pid=%s event=start argc=%s\\n' "$$" "$#"
      i=0
      for arg in "$@"; do
        printf 'pid=%s arg%d=%s\\n' "$$" "$i" "$arg"
        i=$((i + 1))
      done
    } >>"$SESSH_FAKE_SSH_TRACE"
  fi
}

trace_fake_ssh_parsed() {
  if [ -n "${SESSH_FAKE_SSH_TRACE:-}" ]; then
    {
      printf 'pid=%s event=parsed host=%s config=%s config_query=%s saw_t=%s request_tty=%s batch_mode=%s remaining=%s\\n' "$$" "$host" "$config" "$config_query" "$saw_t" "$request_tty" "$batch_mode" "$#"
      if [ "$#" -eq 1 ]; then
        printf 'pid=%s remote_command=%s\\n' "$$" "$1"
      fi
    } >>"$SESSH_FAKE_SSH_TRACE"
  fi
}

record_o_option() {
  case "$1" in
    [Pp][Rr][Oo][Xx][Yy][Cc][Oo][Mm][Mm][Aa][Nn][Dd]=*)
      proxy_command=${1#*=}
      ;;
    [Pp][Rr][Oo][Xx][Yy][Cc][Oo][Mm][Mm][Aa][Nn][Dd]\\ *)
      proxy_command=${1#* }
      ;;
    [Ii][Pp][Qq][Oo][Ss]=*)
      if [ -z "$ipqos_option" ]; then
        ipqos_option=${1#*=}
      fi
      ;;
    [Ii][Pp][Qq][Oo][Ss]\\ *)
      if [ -z "$ipqos_option" ]; then
        ipqos_option=${1#* }
      fi
      ;;
  esac
}

trace_fake_ssh_start "$@"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift
      if [ "$#" -eq 0 ]; then
        printf 'fake ssh: missing -o argument\\n' >&2
        exit 97
      fi
      if [ "$1" = "BatchMode=yes" ]; then
        batch_mode=1
      fi
      record_o_option "$1"
      shift
      ;;
    -o*)
      option_value=${1#-o}
      if [ "$option_value" = "BatchMode=yes" ]; then
        batch_mode=1
      fi
      record_o_option "$option_value"
      shift
      ;;
    -G)
      config_query=1
      shift
      ;;
    -T)
      saw_t=1
      shift
      ;;
    -t|-tt)
      request_tty=1
      plain_option=$1
      shift
      ;;
    -X|-Y|-x)
      x11_option=$1
      shift
      ;;
    -A|-a)
      agent_option=$1
      shift
      ;;
    -L|-R|-D|-W|-w)
      forward_option=$1
      shift
      if [ "$#" -eq 0 ]; then
        printf 'fake ssh: missing %s argument\\n' "$forward_option" >&2
        exit 97
      fi
      forward_value=$1
      shift
      ;;
    -L*|-R*|-D*|-W*|-w*)
      forward_option=$(printf '%s' "$1" | cut -c1-2)
      forward_value=$(printf '%s' "$1" | cut -c3-)
      shift
      ;;
    -F)
      shift
      if [ "$#" -eq 0 ]; then
        printf 'fake ssh: missing -F argument\\n' >&2
        exit 97
      fi
      config=$1
      shift
      ;;
    -p)
      shift
      if [ "$#" -eq 0 ]; then
        printf 'fake ssh: missing -p argument\\n' >&2
        exit 97
      fi
      shift
      ;;
    -v*)
      verbose=${1#-}
      case "$verbose" in
        *[!v]*)
          printf 'fake ssh: unsupported option: %s\\n' "$1" >&2
          exit 97
          ;;
      esac
      shift
      ;;
    -N)
      plain_option=$1
      shift
      ;;
    -n)
      if [ -n "${SESSH_FAKE_SSH_ALLOW_PLAIN:-}" ]; then
        plain_option=$1
        shift
      else
        printf 'fake ssh: unsupported option: %s\\n' "$1" >&2
        exit 97
      fi
      ;;
    -*)
      printf 'fake ssh: unsupported option: %s\\n' "$1" >&2
      exit 97
      ;;
    *)
      host=$1
      shift
      break
      ;;
  esac
done

trace_fake_ssh_parsed "$@"

if [ "$config_query" -eq 1 ]; then
  if [ -z "$host" ]; then
    printf 'fake ssh: missing host for -G\\n' >&2
    exit 97
  fi
  if [ -n "${SESSH_FAKE_SSH_G_FAIL:-}" ]; then
    exit "$SESSH_FAKE_SSH_G_FAIL"
  fi
  if [ -n "$ipqos_option" ]; then
    printf 'hostname %s\\n' "$host"
    case "$ipqos_option" in
      *\\ *) printf 'ipqos %s\\n' "$ipqos_option" ;;
      *) printf 'ipqos %s %s\\n' "$ipqos_option" "$ipqos_option" ;;
    esac
  else
    printf 'hostname %s\\n' "$host"
    printf 'ipqos %s\\n' "${SESSH_FAKE_SSH_G_IPQOS:-af21 cs1}"
  fi
  exit 0
fi

if [ -n "$proxy_command" ]; then
  printf 'invoked=1\\n' >>"$SESSH_FAKE_SSH_LOG"
  printf 'proxy_ssh=1\\n' >>"$SESSH_FAKE_SSH_LOG"
  printf 'proxy_host=%s\\n' "$host" >>"$SESSH_FAKE_SSH_LOG"
  printf 'proxy_command=%s\\n' "$proxy_command" >>"$SESSH_FAKE_SSH_LOG"
  if [ -n "$x11_option" ]; then
    printf 'proxy_x11_option=%s\\n' "$x11_option" >>"$SESSH_FAKE_SSH_LOG"
  fi
  if [ -n "$agent_option" ]; then
    printf 'proxy_agent_option=%s\\n' "$agent_option" >>"$SESSH_FAKE_SSH_LOG"
  fi
  if [ -n "$forward_option" ]; then
    printf 'proxy_forward_option=%s\\n' "$forward_option" >>"$SESSH_FAKE_SSH_LOG"
    printf 'proxy_forward_value=%s\\n' "$forward_value" >>"$SESSH_FAKE_SSH_LOG"
  fi
  if [ "$#" -gt 0 ]; then
    printf 'proxy_remote_command=%s\\n' "$*" >>"$SESSH_FAKE_SSH_LOG"
  fi
  printf 'PROXY_SSH host=%s\\n' "$host"
  exit 0
fi

if [ "$saw_t" -ne 1 ]; then
  if [ -n "${SESSH_FAKE_SSH_ALLOW_PLAIN:-}" ]; then
    printf 'invoked=1\\n' >>"$SESSH_FAKE_SSH_LOG"
    printf 'plain_ssh=1\\n' >>"$SESSH_FAKE_SSH_LOG"
    printf 'plain_host=%s\\n' "$host" >>"$SESSH_FAKE_SSH_LOG"
    if [ -n "$plain_option" ]; then
      printf 'plain_option=%s\\n' "$plain_option" >>"$SESSH_FAKE_SSH_LOG"
    fi
    if [ "$#" -gt 0 ]; then
      printf 'plain_remote_command=%s\\n' "$*" >>"$SESSH_FAKE_SSH_LOG"
    fi
    export SESSH_TEST_HOST=$host
    if [ "$#" -gt 0 ] && [ "$*" = "tty" ]; then
      if [ "$plain_option" = "-tt" ] || { [ "$plain_option" = "-t" ] && [ -t 0 ]; }; then
        printf '/dev/pts/5\\n'
      else
        printf 'not a tty\\n'
      fi
    else
      printf 'PLAIN_SSH host=%s\\n' "$host"
    fi
    exit 0
  fi
  if [ "$request_tty" -ne 1 ]; then
    printf 'fake ssh: missing -T\\n' >&2
    exit 97
  fi
fi
if [ -z "$host" ]; then
  printf 'fake ssh: missing host\\n' >&2
  exit 97
fi
if [ "$#" -ne 1 ]; then
  printf 'fake ssh: expected one remote command\\n' >&2
  exit 97
fi

printf 'invoked=1\\n' >>"$SESSH_FAKE_SSH_LOG"
if [ -n "$config" ]; then
  printf 'config=%s\\n' "$config" >>"$SESSH_FAKE_SSH_LOG"
fi
if [ "$batch_mode" -eq 1 ]; then
  printf 'batch_mode=1\\n' >>"$SESSH_FAKE_SSH_LOG"
fi
if [ -n "$verbose" ]; then
  printf 'verbose=%s\\n' "$verbose" >>"$SESSH_FAKE_SSH_LOG"
fi
if [ -n "${SESSH_FAKE_SSH_LOG_IPQOS:-}" ] && [ -n "$ipqos_option" ]; then
  printf 'ipqos=%s\\n' "$ipqos_option" >>"$SESSH_FAKE_SSH_LOG"
fi
export SESSH_TEST_HOST=$host
if [ "$batch_mode" -eq 1 ] && [ -n "${SESSH_FAKE_SSH_DELAY_ON_BATCH:-}" ]; then
  sleep "$SESSH_FAKE_SSH_DELAY_ON_BATCH"
fi
if [ "$batch_mode" -eq 1 ] && [ -n "${SESSH_FAKE_SSH_STDERR_ON_BATCH:-}" ]; then
  printf '%s\n' "$SESSH_FAKE_SSH_STDERR_ON_BATCH" >&2
fi
if [ "$batch_mode" -eq 1 ] && [ -n "${SESSH_FAKE_SSH_EXIT_ON_BATCH_FILE:-}" ] && [ -e "$SESSH_FAKE_SSH_EXIT_ON_BATCH_FILE" ]; then
  printf 'fake ssh failed on batch reconnect\\n' >&2
  exit "${SESSH_FAKE_SSH_EXIT_ON_BATCH_STATUS:-255}"
fi
if [ -n "${SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND:-}" ]; then
  printf 'fake ssh failed before remote command\\n' >&2
  exit "$SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND"
fi
if [ -n "${SESSH_FAKE_SSH_STDERR_BEFORE_COMMAND:-}" ]; then
  printf '%s\n' "$SESSH_FAKE_SSH_STDERR_BEFORE_COMMAND" >&2
fi
if [ -n "${SESSH_FAKE_SSH_REMOTE_PATH:-}" ]; then
  PATH=$SESSH_FAKE_SSH_REMOTE_PATH:$PATH
  export PATH
fi
if [ -n "${SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR:-}" ]; then
  XDG_RUNTIME_DIR=$SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR
  export XDG_RUNTIME_DIR
fi
if [ -n "${SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME:-}" ]; then
  XDG_STATE_HOME=$SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME
  export XDG_STATE_HOME
fi
if [ -n "${SESSH_FAKE_SSH_REMOTE_SHELL:-}" ]; then
  SHELL=$SESSH_FAKE_SSH_REMOTE_SHELL
  export SHELL
fi
if [ -n "${SESSH_FAKE_SSH_STDERR_AFTER_SIGNAL:-}" ]; then
  (
    while [ ! -e "$SESSH_FAKE_SSH_STDERR_SIGNAL_FILE" ]; do
      sleep 0.01
    done
    printf '%s\n' "$SESSH_FAKE_SSH_STDERR_AFTER_SIGNAL" >&2
    if [ -n "${SESSH_FAKE_SSH_STDERR_DONE_FILE:-}" ]; then
      : >"$SESSH_FAKE_SSH_STDERR_DONE_FILE"
    fi
  ) &
fi
if [ "$saw_t" -eq 1 ] && [ -n "${SESSH_FAKE_SSH_SIMULATE_NO_PTY:-}" ] && [ -t 0 ]; then
  python3 - "$1" <<'PY'
import os
import select
import subprocess
import sys

proc = subprocess.Popen(
    ["sh", "-c", sys.argv[1]],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
)
stdin_open = True
stdout_open = True
stdout_fd = proc.stdout.fileno()
try:
    while stdin_open or stdout_open:
        fds = []
        if stdin_open:
            fds.append(0)
        if stdout_open:
            fds.append(stdout_fd)
        if not fds:
            break
        ready, _, _ = select.select(fds, [], [])
        if stdin_open and 0 in ready:
            data = os.read(0, 4096)
            if data:
                try:
                    proc.stdin.write(data)
                    proc.stdin.flush()
                except BrokenPipeError:
                    stdin_open = False
                    proc.stdin.close()
            else:
                stdin_open = False
                proc.stdin.close()
        if stdout_open and stdout_fd in ready:
            data = os.read(stdout_fd, 4096)
            if data:
                os.write(1, data)
            else:
                stdout_open = False
                proc.stdout.close()
        if proc.poll() is not None and not stdout_open:
            break
finally:
    if stdin_open:
        proc.stdin.close()
    if stdout_open:
        proc.stdout.close()
sys.exit(proc.wait())
PY
fi
if [ "$saw_t" -eq 1 ] && [ "$batch_mode" -eq 1 ] && [ -n "${SESSH_FAKE_SSH_KILL_BATCH_ONCE_FILE:-}" ]; then
  printf 'kill_batch_wrapper=1\\n' >>"$SESSH_FAKE_SSH_LOG"
  exec 3<&0
  python3 - "$1" "$SESSH_FAKE_SSH_KILL_BATCH_ONCE_FILE" <<'PY'
import os
import signal
import subprocess
import sys
import time

command = sys.argv[1]
kill_file = sys.argv[2]
log_path = os.environ.get("SESSH_FAKE_SSH_LOG")
stdin_file = os.fdopen(os.dup(3), "rb", closefd=True)
proc = subprocess.Popen(["sh", "-c", command], stdin=stdin_file, start_new_session=True)
if log_path:
    with open(log_path, "a") as log:
        log.write(f"kill_batch_pid={proc.pid}\\n")
try:
    while proc.poll() is None:
        if os.path.exists(kill_file):
            if log_path:
                with open(log_path, "a") as log:
                    log.write("kill_batch_triggered=1\\n")
            try:
                os.unlink(kill_file)
            except FileNotFoundError:
                pass
            # Killing only the shell wrapper can leave the stream-remote child
            # alive with the transport fds open. Kill the command's process
            # group so the fake ssh channel closes the same way a lost ssh
            # transport would close.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            if log_path:
                with open(log_path, "a") as log:
                    log.write(f"kill_batch_wait={proc.returncode}\\n")
            sys.exit(255)
        time.sleep(0.01)
    sys.exit(proc.returncode)
finally:
    stdin_file.close()
    if proc.poll() is None:
        proc.kill()
PY
fi
exec sh -c "$1"
"""


def write_fake_ssh(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(FAKE_SSH)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_fake_uname(path, os_name, arch):
    path.write_text(
        "#!/bin/sh\n"
        "case \"$1\" in\n"
        f"  -s) printf '%s\\n' {shlex.quote(os_name)} ;;\n"
        f"  -m) printf '%s\\n' {shlex.quote(arch)} ;;\n"
        f"  *) printf '%s\\n' {shlex.quote(os_name)} ;;\n"
        "esac\n"
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_sessh(args, env, timeout=5.0):
    return subprocess.run(
        sessh_argv(args),
        cwd=ROOT,
        env=env,
        text=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def write_sessh_config(env, text):
    config_dir = Path(env["XDG_CONFIG_HOME"]) / "sessh"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "sessh.env").write_text(text)


def configure_ctrl_b_leader(env):
    write_sessh_config(env, "leader=CTRL-B\n")


def optional_text(path):
    return path.read_text() if path.exists() else "<missing>"


def process_diagnostics(result):
    return (
        f"returncode={result.returncode}\n"
        f"args={result.args!r}\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )


def ssh_failure_diagnostics(message, result, fake_log, fake_trace):
    return (
        f"{message}\n"
        f"\nfake ssh log:\n{optional_text(fake_log)}"
        f"\nfake ssh trace:\n{optional_text(fake_trace)}"
        f"\nsessh result:\n{process_diagnostics(result)}"
    )


def run_sesshmux(args, env, timeout=5.0):
    return subprocess.run(
        [str(MUX_BIN), *args],
        cwd=ROOT,
        env=env,
        text=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def read_until_pipe(pipe, needle, timeout=10.0):
    deadline = time.monotonic() + timeout
    data = b""
    while needle not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(f"timed out waiting for {needle!r}; got {data!r}")
        ready, _, _ = select.select([pipe], [], [], remaining)
        if not ready:
            raise AssertionError(f"timed out waiting for {needle!r}; got {data!r}")
        chunk = os.read(pipe.fileno(), 4096)
        if not chunk:
            raise AssertionError(f"process exited before {needle!r}; got {data!r}")
        data += chunk
    return data


def read_available_pipe(pipe, timeout=0.25):
    deadline = time.monotonic() + timeout
    data = b""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return data
        ready, _, _ = select.select([pipe], [], [], remaining)
        if not ready:
            return data
        chunk = os.read(pipe.fileno(), 4096)
        if not chunk:
            return data
        data += chunk


def wait_for_path(path, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {path}")


def wait_for_file_count(path, needle, minimum, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            text = path.read_text()
            if text.count(needle) >= minimum:
                return text
        time.sleep(0.01)
    current = path.read_text() if path.exists() else "<missing>"
    raise AssertionError(f"timed out waiting for {minimum} occurrences of {needle!r} in {path}; got {current!r}")


def run_sessh_until_stdout(args, env, needle, timeout=10.0):
    argv = sessh_argv(args)
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = read_until_pipe(proc.stdout, needle.encode("utf-8"), timeout)
    proc.stdin.close()
    returncode = proc.wait(timeout=timeout)
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def run_sesshmux_until_stdout(args, env, needle, timeout=10.0):
    proc = subprocess.Popen(
        [str(MUX_BIN), *args],
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = read_until_pipe(proc.stdout, needle.encode("utf-8"), timeout)
    proc.stdin.close()
    returncode = proc.wait(timeout=timeout)
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        [str(MUX_BIN), *args],
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def read_pty_until(fd, output, needle, timeout=10.0):
    deadline = time.monotonic() + timeout
    while needle not in output:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(f"timed out waiting for {needle!r}; got {output!r}")
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            raise AssertionError(f"timed out waiting for {needle!r}; got {output!r}")
        try:
            chunk = os.read(fd, 4096)
        except OSError as exc:
            raise AssertionError(f"pty closed waiting for {needle!r}; got {output!r}") from exc
        if not chunk:
            raise AssertionError(f"pty closed waiting for {needle!r}; got {output!r}")
        output += chunk
    return output


def read_pty_until_count(fd, output, needle, minimum, timeout=10.0):
    deadline = time.monotonic() + timeout
    while output.count(needle) < minimum:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(f"timed out waiting for {minimum} occurrences of {needle!r}; got {output!r}")
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            raise AssertionError(f"timed out waiting for {minimum} occurrences of {needle!r}; got {output!r}")
        try:
            chunk = os.read(fd, 4096)
        except OSError as exc:
            raise AssertionError(f"pty closed waiting for {needle!r}; got {output!r}") from exc
        if not chunk:
            raise AssertionError(f"pty closed waiting for {needle!r}; got {output!r}")
        output += chunk
    return output


def run_sesshmux_in_pty(
    args,
    env,
    steps,
    timeout=10.0,
    child_tty_setup=None,
    binary=None,
    capture_tty_attrs=False,
):
    argv = [str(binary or MUX_BIN), *args]
    sync_r = sync_w = None
    if capture_tty_attrs:
        sync_r, sync_w = os.pipe()
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        if sync_r is not None:
            os.close(sync_w)
            os.read(sync_r, 1)
            os.close(sync_r)
        if child_tty_setup is not None:
            child_tty_setup(0)
        os.execvpe(argv[0], argv, env)

    output = b""
    waited = False
    tty_attrs_before = None
    tty_attrs_after = None
    try:
        if sync_r is not None:
            os.close(sync_r)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        if capture_tty_attrs:
            # Release builds call std.process.exit, so defers do not run. Keep
            # the child parked until the parent records the initial tty state;
            # otherwise a fast child could put the pty in raw mode before the
            # test has a baseline to compare against.
            tty_attrs_before = termios.tcgetattr(fd)
            os.write(sync_w, b"x")
            os.close(sync_w)
            sync_w = None
        for needle, to_send in steps:
            output = read_pty_until(fd, output, needle, timeout)
            if callable(to_send):
                to_send(fd)
            elif to_send:
                os.write(fd, to_send)

        deadline = time.monotonic() + timeout
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                returncode = wait_status_to_returncode(status)
                output += read_available_pty(fd)
                if capture_tty_attrs:
                    tty_attrs_after = termios.tcgetattr(fd)
                result = subprocess.CompletedProcess(
                    argv,
                    returncode,
                    output.decode("utf-8", "replace"),
                    "",
                )
                result.tty_attrs_before = tty_attrs_before
                result.tty_attrs_after = tty_attrs_after
                return result
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timed out waiting for pty command to exit; got {output!r}")
            ready, _, _ = select.select([fd], [], [], min(remaining, 0.05))
            if ready:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    chunk = b""
                if chunk:
                    output += chunk
    finally:
        if sync_w is not None:
            os.close(sync_w)
        if not waited:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        os.close(fd)


def set_no_terminal_emulator_tty_mode_probe(fd):
    # This runs in the child side of pty.fork before sessh starts, so sessh
    # should capture these modes and apply them to the remote
    # no-terminal-emulator PTY.
    attrs = termios.tcgetattr(fd)
    attrs[0] &= ~termios.ICRNL
    attrs[3] &= ~(termios.ECHO | termios.ICANON)
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def set_no_terminal_emulator_output_mode_probe(fd):
    attrs = termios.tcgetattr(fd)
    attrs[1] &= ~termios.OPOST
    if hasattr(termios, "ONLCR"):
        attrs[1] &= ~termios.ONLCR
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def tty_attr_summary(attrs):
    if attrs is None:
        return "<none>"
    return (
        f"iflag=0x{attrs[0]:x} oflag=0x{attrs[1]:x} "
        f"cflag=0x{attrs[2]:x} lflag=0x{attrs[3]:x} "
        f"ispeed={attrs[4]} ospeed={attrs[5]}"
    )


def resize_pty_then_send(rows, cols, data):
    def action(fd):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        if data:
            os.write(fd, data)

    return action


def wait_status_to_returncode(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return -os.WTERMSIG(status)
    return 255


def read_available_pty(fd):
    output = b""
    while True:
        ready, _, _ = select.select([fd], [], [], 0)
        if not ready:
            return output
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            return output
        if not chunk:
            return output
        output += chunk


def run_sessh_reconnect_probe(
    args,
    env,
    ready,
    after,
    during=None,
    timeout=30.0,
    expect_countdown=False,
    expect_reconnecting=False,
):
    argv = sessh_argv(args)
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = read_until_pipe(proc.stdout, ready.encode("utf-8"), timeout)
    proc.stdin.write(b"\x02s")
    proc.stdin.flush()
    stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", timeout)
    if expect_countdown:
        stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 9sec", timeout)
    if during is not None:
        proc.stdin.write(during.encode("utf-8") + b"\n")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, b"\x07", timeout)
    proc.stdin.write(b"\x12")
    proc.stdin.flush()
    if expect_reconnecting:
        stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Reconnecting... CTRL-C detach", timeout)
    stdout += read_until_pipe(proc.stdout, ready.encode("utf-8"), timeout)
    proc.stdin.write(after.encode("utf-8") + b"\n")
    proc.stdin.flush()
    after_needle = f"REMOTE:{after}".encode("utf-8")
    if after_needle not in stdout:
        stdout += read_until_pipe(proc.stdout, after_needle, timeout)
    proc.stdin.close()
    returncode = proc.wait(timeout=timeout)
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


OSC_RE = re.compile(r"\x1b\][^\x1b]*(?:\x1b\\|\x07)")
CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
UI_MESSAGE_RE = re.compile(r"(?:---\s*)?(?:ssh|sessh): [^\r\n]+")


def normalized_ui_messages(text):
    stripped = OSC_RE.sub("", text)
    stripped = CSI_RE.sub("", stripped)
    messages = []
    for match in UI_MESSAGE_RE.finditer(stripped):
        message = re.sub(r"\s+", " ", match.group(0).strip())
        if message not in messages:
            messages.append(message)
    return messages


def title_sequence(title):
    return f"\x1b]2;{title}\x1b\\"


def strip_bootstrap_status(stderr):
    return stderr.replace("\rsessh: bootstrapping...", "").replace("\r\x1b[K", "")


def run_sessh_enter_alt_then_reconnect_banner(args, env, primary, alt_ready, timeout=30.0):
    argv = sessh_argv(args)
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        read_until_pipe(proc.stdout, primary.encode("utf-8"), timeout)
        proc.stdin.write(b"enter-alt\n")
        proc.stdin.flush()
        read_until_pipe(proc.stdout, alt_ready.encode("utf-8"), timeout)
        proc.stdin.write(b"\x02s")
        proc.stdin.flush()
        stdout = read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", timeout)
        proc.stdin.write(b"\x03")
        proc.stdin.flush()
        proc.stdin.close()
        returncode = proc.wait(timeout=timeout)
    finally:
        if proc.poll() is None:
            proc.kill()
            returncode = proc.wait(timeout=timeout)
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def run_sessh_detach_reconnect_probe(args, env, ready, detach_bytes=b"\x03", timeout=10.0):
    argv = sessh_argv(args)
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = read_until_pipe(proc.stdout, ready.encode("utf-8"), timeout)
    proc.stdin.write(b"\x02s")
    proc.stdin.flush()
    stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", timeout)
    proc.stdin.write(detach_bytes)
    proc.stdin.flush()
    proc.stdin.close()
    returncode = proc.wait(timeout=timeout)
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def run_sessh_detach_probe(args, env, ready, timeout=10.0):
    argv = sessh_argv(args)
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = read_until_pipe(proc.stdout, ready.encode("utf-8"), timeout)
    proc.stdin.write(b"\x02d")
    proc.stdin.flush()
    proc.stdin.close()
    returncode = proc.wait(timeout=timeout)
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_local_platform():
    sysname = os.uname().sysname
    machine = os.uname().machine
    if sysname == "Darwin":
        os_name = "macos"
    elif sysname == "Linux":
        os_name = "linux"
    else:
        raise AssertionError(f"unsupported test OS: {sysname}")

    if machine in ("x86_64", "amd64"):
        arch = "x86_64"
    elif machine in ("i386", "i486", "i586", "i686"):
        arch = "x86"
    elif machine in ("arm", "armv6l", "armv7l", "armv8l"):
        arch = "arm32"
    elif machine in ("aarch64", "arm64"):
        arch = "aarch64"
    elif machine == "riscv64":
        arch = "riscv64"
    else:
        raise AssertionError(f"unsupported test arch: {machine}")
    return os_name, arch


def local_artifact():
    os_name, arch = canonical_local_platform()
    return ROOT / "zig-out" / "libexec" / "sessh" / f"sesshmux-{os_name}-{arch}"


def remote_path_artifact():
    if BIN.name == "sesshmux-dev":
        return BIN if BIN.is_absolute() else ROOT / BIN
    return local_artifact()


def artifact_cache_path(env, artifact):
    return Path(env["XDG_CACHE_HOME"]) / "sessh" / "bin" / sessh_version() / sha256(artifact) / "sesshmux"


def seed_remote_artifact_cache(env, artifact=None):
    if artifact is None:
        artifact = remote_path_artifact()
    cached = artifact_cache_path(env, artifact)
    cached.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(artifact, cached)
    cached.chmod(0o700)
    return cached


def sessh_version():
    for line in (ROOT / "src" / "config.zig").read_text().splitlines():
        if line.startswith("pub const version = "):
            return line.split('"')[1]
    raise AssertionError("could not find sessh version")


def aliases_dir(env):
    return state_root(env) / "alias"


def state_root(env):
    return Path(env["XDG_STATE_HOME"]) / "sessh"


def state_sessions_dir(env):
    return state_root(env) / "guid"


def tombstones_dir(env):
    return state_root(env) / "tombstone"


def runtime_root(env):
    return Path(env["XDG_RUNTIME_DIR"])


def sessions_dir(env):
    return runtime_root(env) / "guid"


def compact_guid(guid):
    if COMPACT_GUID_RE.match(guid):
        return guid.lower()
    if not GUID_RE.match(guid):
        raise AssertionError(f"invalid guid: {guid}")
    return guid[2:].replace("-", "").lower()


def canonical_guid(guid):
    if GUID_RE.match(guid):
        return guid.lower()
    if COMPACT_GUID_RE.match(guid):
        compact = guid.lower()
        return f"s-{compact[0:8]}-{compact[8:12]}-{compact[12:16]}-{compact[16:20]}-{compact[20:32]}"
    raise AssertionError(f"invalid guid: {guid}")


def guid_for_alias(alias):
    match = re.fullmatch(r"s([0-9]+)", alias)
    if match:
        return f"s-00000000-0000-4000-8000-{int(match.group(1)):012x}"
    digest = hashlib.sha256(alias.encode("utf-8")).hexdigest()
    return f"s-{digest[0:8]}-{digest[8:12]}-{digest[12:16]}-{digest[16:20]}-{digest[20:32]}"


def list_rows(list_stdout):
    rows = []
    for line in list_stdout.splitlines()[1:]:
        if not line.strip():
            continue
        if len(line) < 58:
            raise AssertionError(f"invalid list row: {line!r}\n{list_stdout}")
        rows.append(
            [
                line[0:10].strip(),
                line[12:20].strip(),
                line[22:30].strip(),
                line[32:56].strip(),
                line[58:].strip(),
            ]
        )
    return rows


def has_list_header(list_stdout):
    header = list_stdout.splitlines()[0] if list_stdout.splitlines() else ""
    return all(column in header for column in ("ID", "ATTACHED", "INPUT", "HOST", "VERSION"))


def list_has_session(list_stdout, session_id):
    for row in list_rows(list_stdout):
        if row[0] == session_id:
            return True
    return False


def ensure_alias(env, alias, guid=None):
    guid = canonical_guid(guid or guid_for_alias(alias))
    alias_path = aliases_dir(env) / alias
    alias_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if alias_path.exists() or alias_path.is_symlink():
        return
    alias_path.symlink_to(Path("../guid") / guid)


def write_ssh_route(env, alias, guid, host, ssh_options=(), detached_at_unix_ms=None):
    guid = canonical_guid(guid)
    ensure_alias(env, alias, guid)
    session = state_sessions_dir(env) / guid
    session.mkdir(mode=0o700, parents=True, exist_ok=True)
    remote_session_dir = runtime_root(env) / "guid" / guid
    (session / "route.json").write_text(
        json.dumps(
            {
                "guid": guid,
                "primary_alias": alias,
                "session_dir": str(remote_session_dir),
                "host": host,
                "agent_version": "cached-test",
                "alive": True,
                "attached_count": None,
                "last_input_at_unix_ms": None,
                "detached_at_unix_ms": detached_at_unix_ms,
                "ssh_options": list(ssh_options),
            },
            separators=(",", ":"),
        )
        + "\n"
    )
    return session


def write_client_route_hint(env, client_guid, session_id):
    hint = runtime_root(env) / "guid" / client_guid / "route.json"
    hint.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if hint.exists() or hint.is_symlink():
        hint.unlink()
    hint.symlink_to(route_file(env, session_id))
    (hint.parent / "outgoing-meta.json").write_text(
        json.dumps(
            {
                "type": "outgoing-client",
                "created_at_unix_ms": 1,
            },
            separators=(",", ":"),
        )
        + "\n"
    )
    return hint


def session_path(env, session_id="s1"):
    if GUID_RE.match(session_id) or COMPACT_GUID_RE.match(session_id):
        return sessions_dir(env) / canonical_guid(session_id)
    alias_path = aliases_dir(env) / session_id
    if alias_path.is_symlink():
        return sessions_dir(env) / canonical_guid(Path(os.readlink(alias_path)).name)
    ensure_alias(env, session_id)
    return sessions_dir(env) / canonical_guid(Path(os.readlink(alias_path)).name)


def route_file(env, session_id="s1"):
    if GUID_RE.match(session_id) or COMPACT_GUID_RE.match(session_id):
        return state_sessions_dir(env) / canonical_guid(session_id) / "route.json"
    alias_path = aliases_dir(env) / session_id
    if not alias_path.is_symlink():
        ensure_alias(env, session_id)
    return state_sessions_dir(env) / canonical_guid(Path(os.readlink(alias_path)).name) / "route.json"


def actual_socket_path(env, session_id="s1"):
    if GUID_RE.match(session_id) or COMPACT_GUID_RE.match(session_id):
        guid = canonical_guid(session_id)
    else:
        alias_path = aliases_dir(env) / session_id
        if not alias_path.is_symlink():
            ensure_alias(env, session_id)
        guid = canonical_guid(Path(os.readlink(alias_path)).name)
    return runtime_root(env) / "s" / compact_guid(guid)


def ensure_agent_socket_link(env, session_id="s1"):
    session = session_path(env, session_id)
    session.mkdir(mode=0o700, parents=True, exist_ok=True)
    (runtime_root(env) / "s").mkdir(mode=0o700, parents=True, exist_ok=True)
    link = session / "agent.sock"
    if not link.exists() and not link.is_symlink():
        link.symlink_to(Path("../../s") / actual_socket_path(env, session_id).name)


def session_compat_path(env, session_id="s1"):
    return session_path(env, session_id) / "compat"


def assert_session_compat_points_to_cached_artifact(env, artifact, session_id, context):
    cached = artifact_cache_path(env, artifact)
    compat = session_compat_path(env, session_id)
    assert_cached_artifact(env, artifact, context)
    if not compat.is_symlink():
        raise AssertionError(f"{context}: session compat path is not a symlink")
    if not compat.exists() or not os.path.samefile(cached, compat):
        raise AssertionError(f"{context}: session compat path does not resolve to cached artifact")


def assert_cached_artifact(env, artifact, context):
    cached = artifact_cache_path(env, artifact)
    if not cached.exists():
        raise AssertionError(f"{context}: cached artifact was not created at {cached}")
    if cached.read_bytes() != artifact.read_bytes():
        raise AssertionError(f"{context}: cached artifact does not match source binary")
    if not os.access(cached, os.X_OK):
        raise AssertionError(f"{context}: cached artifact is not executable")


def write_compat_marker(path, marker):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(
        "#!/bin/sh\n"
        "printf 'compat_invoked=1\\n' >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "printf 'compat_args=%s\\n' \"$*\" >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "printf 'compat_env_guid=%s\\n' \"${SESSH_GUID-unset}\" >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "printf 'compat_env_client_version=%s\\n' \"${SESSH_CLIENT_VERSION-unset}\" >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "printf 'compat_env_compat=%s\\n' \"${SESSH_COMPAT-unset}\" >>\"$SESSH_FAKE_SSH_LOG\"\n"
        f"printf '{marker}\\n'\n"
    )
    path.chmod(0o700)


def version_mismatch_frame():
    payload = protobuf_string_field(1, b"VERSION_MISMATCH")
    payload += protobuf_string_field(2, b"existing remote sessh is incompatible with this client")
    payload += protobuf_string_field(3, b"Use the matching remote sessh binary")
    hello_frame = protobuf_bytes_field(3, payload)
    return struct.pack(">I", len(hello_frame)) + hello_frame


def start_version_mismatch_agent(env, session_id="s1"):
    ensure_agent_socket_link(env, session_id)
    session = session_path(env, session_id)
    (session / "meta.json").write_text(
        json.dumps({"agent_pid": os.getpid(), "version": "0.0.0-compat-test"}, separators=(",", ":")) + "\n"
    )
    (session / "detached").write_text("")
    sock_path = actual_socket_path(env, session_id)
    try:
        sock_path.unlink()
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(sock_path))
    server.listen(1)
    observed = {}

    def serve():
        try:
            server.settimeout(10.0)
            conn, _ = server.accept()
            with conn:
                conn.settimeout(10.0)
                header = conn.recv(4)
                observed["header"] = header
                if len(header) == 4:
                    (payload_len,) = struct.unpack(">I", header)
                    conn.recv(payload_len)
                conn.sendall(version_mismatch_frame())
        except Exception as exc:
            observed["error"] = repr(exc)

    thread = threading.Thread(target=serve)
    thread.start()
    return server, thread, observed


def protobuf_string_field(field_number, value):
    return protobuf_bytes_field(field_number, value)


def protobuf_bytes_field(field_number, value):
    key = (field_number << 3) | 2
    return protobuf_varint(key) + protobuf_varint(len(value)) + value


def protobuf_varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def test_fake_ssh_exports_host_to_remote_command(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = subprocess.run(
        ["ssh", "-T", "test-host", "printf 'host=%s\\n' \"$SESSH_TEST_HOST\""],
        cwd=ROOT,
        env=env,
        text=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5.0,
        check=False,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "host=test-host\n":
        raise AssertionError(result)
    if result.stderr:
        raise AssertionError(result)


def test_ssh_transport_uploads_artifact_and_reaches_broker(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    fake_config = tmp / "ssh_config"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_ATTACH_READY"
    fake_config.write_text("Host test-host\n")
    remote_shell.write_text(
        f"#!/bin/sh\n"
        f"printf '{marker}\\n'\n"
        "printf 'SESSH_PATH=%s\\n' \"$SESSH_PATH\"\n"
        "printf 'SESSHMUX_BIN=%s\\n' \"$(command -v sesshmux || true)\"\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["--alias", "s1", "-F", str(fake_config), "test-host"], env, timeout=30.0)

    if not fake_log.exists():
        raise AssertionError(ssh_failure_diagnostics("fake ssh was not invoked", result, fake_log, fake_trace))
    expected_log = f"invoked=1\nconfig={fake_config}\n"
    if fake_log.read_text() != expected_log:
        raise AssertionError(
            ssh_failure_diagnostics(
                f"unexpected fake ssh log; expected:\n{expected_log}",
                result,
                fake_log,
                fake_trace,
            )
        )
    if result.returncode != 0:
        raise AssertionError(ssh_failure_diagnostics("sessh returned non-zero", result, fake_log, fake_trace))
    if marker not in result.stdout:
        raise AssertionError(
            ssh_failure_diagnostics("ssh attach did not render remote output", result, fake_log, fake_trace)
        )
    if "ssh runtime attach is not implemented yet" in result.stderr:
        raise AssertionError(
            ssh_failure_diagnostics("ssh runtime attach fallback was used", result, fake_log, fake_trace)
        )
    if any(token in result.stdout or token in result.stderr for token in ("MISSING ", "UPLOAD ", "OK\n")):
        raise AssertionError(
            ssh_failure_diagnostics("bootstrap protocol leaked to client output", result, fake_log, fake_trace)
        )
    status_start = result.stderr.find("sessh: bootstrapping...")
    status_clear = result.stderr.find("\x1b[K", status_start + 1)
    if status_start < 0 or status_clear < 0 or status_clear < status_start:
        raise AssertionError(
            ssh_failure_diagnostics("bootstrap status was not displayed and cleared", result, fake_log, fake_trace)
        )
    if "ssh ts_ms=" in result.stderr:
        raise AssertionError(ssh_failure_diagnostics("bootstrap status was captured as ssh stderr", result, fake_log, fake_trace))

    artifact = remote_path_artifact()
    installed = artifact_cache_path(env, artifact)
    if installed.read_bytes() != artifact.read_bytes():
        raise AssertionError("uploaded artifact was not installed")
    if not os.access(installed, os.X_OK):
        raise AssertionError("uploaded artifact is not executable")
    if f"SESSH_PATH={installed.parent.resolve()}" not in result.stdout:
        raise AssertionError(result)
    if f"SESSHMUX_BIN={installed.resolve()}" not in result.stdout:
        raise AssertionError(result)
    tombstones = list(tombstones_dir(env).glob("*.json"))
    if len(tombstones) != 1:
        raise AssertionError("uploaded broker did not create a session tombstone")
    tombstone = tombstones[0]
    tombstone_json = json.loads(tombstone.read_text())
    if tombstone_json.get("primary_alias") != "s1" or "s1" not in tombstone_json.get("aliases", []):
        raise AssertionError(tombstone_json)
    if tombstone_json.get("end_reason") != "process_exited":
        raise AssertionError(tombstone_json)
    if tombstone_json.get("exit_status") != {"kind": "exited", "status": 0}:
        raise AssertionError(tombstone_json)
    if (aliases_dir(env) / "s1").exists() or (aliases_dir(env) / "s1").is_symlink():
        raise AssertionError("ended session alias was not released")


def test_ssh_clean_remote_exit_tombstones_local_route(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_runtime = tmp / "remote-runtime"
    remote_state = tmp / "remote-state"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_REMOTE_EXIT_READY"
    alias = "remote-exit"
    remote_runtime.mkdir(mode=0o700)
    remote_state.mkdir(mode=0o700)
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\nexit 7\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR"] = str(remote_runtime)
    env["SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME"] = str(remote_state)
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["--alias", alias, "test-host"], env, timeout=30.0)

    if result.returncode != 7:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)

    listed = run_sesshmux(["list", "--exited", "--jsonl"], env, timeout=30.0)
    if listed.returncode != 0:
        raise AssertionError(listed)
    rows = [json.loads(line) for line in listed.stdout.splitlines() if line.strip()]
    matches = [row for row in rows if row.get("id") == alias]
    if len(matches) != 1:
        raise AssertionError(process_diagnostics(listed))
    row = matches[0]
    if row.get("host") != "test-host" or alias not in row.get("aliases", []):
        raise AssertionError(row)
    if row.get("end_reason") != "process_exited":
        raise AssertionError(row)
    if row.get("exit_status") != {"kind": "exited", "status": 7}:
        raise AssertionError(row)

    guid = row.get("guid")
    if not guid:
        raise AssertionError(row)
    if (state_sessions_dir(env) / guid / "route.json").exists():
        raise AssertionError("local cached route was not tombstoned")
    if (aliases_dir(env) / alias).exists() or (aliases_dir(env) / alias).is_symlink():
        raise AssertionError("local cached route alias was not released")
    if not (remote_state / "sessh" / "tombstone" / f"{guid}.json").exists():
        raise AssertionError("remote session did not write its own tombstone")


def test_ssh_pre_attach_stderr_forwards_immediately(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_PRE_ATTACH_STDERR_READY"
    raw_ssh_error = "pre-attach ssh warning: \x1b[31mred"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_STDERR_BEFORE_COMMAND"] = raw_ssh_error
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["test-host"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    if raw_ssh_error not in result.stderr:
        raise AssertionError(result)
    if "ssh ts_ms=" in result.stderr:
        raise AssertionError(result)


def test_ssh_transport_pins_ipqos_to_interactive_config_value(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_IPQOS_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_LOG_IPQOS"] = "1"
    env["SESSH_FAKE_SSH_G_IPQOS"] = "af31 cs1"
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["test-host"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "ipqos=af31" not in log_text or "ipqos=cs1" in log_text:
        raise AssertionError(log_text)


def test_ssh_transport_respects_explicit_user_ipqos(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_USER_IPQOS_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_LOG_IPQOS"] = "1"
    env["SESSH_FAKE_SSH_G_IPQOS"] = "af31 cs1"
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["-oIPQoS=none", "test-host"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "ipqos=none" not in log_text or "ipqos=ef" in log_text:
        raise AssertionError(log_text)


def test_ssh_transport_pins_explicit_two_value_ipqos_to_interactive_value(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_USER_TWO_VALUE_IPQOS_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_LOG_IPQOS"] = "1"
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["-oIPQoS=ef cs0", "test-host"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "ipqos=ef\n" not in log_text or "ipqos=cs0" in log_text:
        raise AssertionError(log_text)


def test_ssh_transport_preserves_config_when_ipqos_query_fails(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_IPQOS_QUERY_FAILED_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_LOG_IPQOS"] = "1"
    env["SESSH_FAKE_SSH_G_FAIL"] = "97"
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["test-host"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "ipqos=" in log_text:
        raise AssertionError(log_text)


def test_ssh_session_uses_remote_shell_not_local_client_shell(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    local_shell = tmp / "local-shell"
    remote_shell = tmp / "remote-shell"
    local_marker = "LOCAL_CLIENT_SHELL_USED"
    remote_marker = "REMOTE_LOGIN_SHELL_USED"
    local_shell.write_text(f"#!/bin/sh\nprintf '{local_marker}\\n'\n")
    remote_shell.write_text(f"#!/bin/sh\nprintf '{remote_marker}\\n'\n")
    local_shell.chmod(0o700)
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_SHELL"] = str(remote_shell)
    env["SHELL"] = str(local_shell)

    result = run_sessh(["test-host"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if remote_marker not in result.stdout:
        raise AssertionError(result)
    if local_marker in result.stdout:
        raise AssertionError(result)


def test_ssh_verbose_flags_are_passed_to_ssh(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_VERBOSE_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh_until_stdout(["-vvv", "test-host"], env, marker, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    if "verbose=vvv" not in fake_log.read_text():
        raise AssertionError(fake_log.read_text())


def test_ssh_failure_uses_ssh_exit_status_and_visible_args(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND"] = "255"

    result = run_sessh(["-vvv", "test-host"], env, timeout=5.0)

    if result.returncode != 255:
        raise AssertionError(result)
    if "fake ssh failed before remote command" not in result.stderr:
        raise AssertionError(result)
    if "sessh: `ssh -vvv test-host` failed (exitcode=255)" not in result.stderr:
        raise AssertionError(result)
    if "EndOfStream" in result.stderr or "ssh bootstrap failed before response" in result.stderr:
        raise AssertionError(result.stderr)


def test_ssh_unsupported_option_falls_back_to_plain_ssh(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_ALLOW_PLAIN"] = "1"

    result = run_sessh(["-n", "test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "PLAIN_SSH host=test-host" not in result.stdout:
        raise AssertionError(result)
    if "fallback to plain-ssh due to ssh option incompatible with sessh transport" not in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "plain_ssh=1" not in log_text or "plain_option=-n" not in log_text:
        raise AssertionError(log_text)
    if "bootstrapper=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_x11_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["-X", "test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    if "PROXY_SSH host=test-host" not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "proxy_x11_option=-X" not in log_text:
        raise AssertionError(log_text)
    if ":internal-proxy-stream:" not in log_text:
        raise AssertionError(log_text)
    if "proxy_remote_command=echo hello" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_forwarding_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["-L", "8080:localhost:80", "test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "proxy_forward_option=-L" not in log_text:
        raise AssertionError(log_text)
    if "proxy_forward_value=8080:localhost:80" not in log_text:
        raise AssertionError(log_text)
    if ":internal-proxy-stream:" not in log_text:
        raise AssertionError(log_text)


def test_ssh_force_proxy_mode_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["--force-proxy-mode", "test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if ":internal-proxy-stream:" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_force_proxy_mode_config_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "force-proxy-mode=true\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if ":internal-proxy-stream:" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_no_force_proxy_mode_overrides_config(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "force-proxy-mode=yes\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["--no-force-proxy-mode", "test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "hello\n":
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" in log_text or ":internal-proxy-stream:" in log_text:
        raise AssertionError(log_text)
    if "batch_mode=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_remote_command_uses_direct_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "hello\n":
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_remote_command_stream_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "printf 'EXIT_STATUS_STDOUT\\n'; exit 7"], env, timeout=5.0)

    if result.returncode != 7:
        raise AssertionError(result)
    if result.stdout != "EXIT_STATUS_STDOUT\n":
        raise AssertionError(result)


def test_ssh_remote_command_stream_waits_for_exit_status_after_output_eof(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "exec >/dev/null 2>/dev/null; sleep 0.2; exit 9"], env, timeout=5.0)

    if result.returncode != 9:
        raise AssertionError(result)
    if result.stdout or result.stderr:
        raise AssertionError(result)


def test_ssh_remote_command_stream_preserves_stderr_channel(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(
        ["test-host", "printf 'STDOUT\\n'; printf 'STDERR\\n' >&2"],
        env,
        timeout=5.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "STDOUT\n":
        raise AssertionError(result)
    if result.stderr != "STDERR\n":
        raise AssertionError(result)


def test_ssh_tty_stdin_remote_command_does_not_allocate_tty_without_t(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "test-host", "tty"],
        env,
        ((b"not a tty", None),),
        timeout=10.0,
    )

    if result.returncode != 1:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_tty_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "-t", "test-host", "exit 67"],
        env,
        (),
        timeout=10.0,
    )

    if result.returncode != 67:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_tty_propagates_resize(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = "printf 'READY:%s\\n' \"$(stty size)\"; IFS= read -r _; printf 'RESIZED:%s\\n' \"$(stty size)\""
    result = run_sesshmux_in_pty(
        [":internal-sessh:", "-t", "test-host", command],
        env,
        (
            (b"READY:24 100", resize_pty_then_send(31, 120, b"\n")),
            (b"RESIZED:31 120", None),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_remote_command_uses_direct_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["--no-terminal-emulator", "test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "hello\n":
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_remote_command_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["--no-terminal-emulator", "test-host", "exit 11"], env, timeout=5.0)

    if result.returncode != 11:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", "exit 13"],
        env,
        (),
        timeout=10.0,
    )

    if result.returncode != 13:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_propagates_resize(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = "printf 'READY:%s\\n' \"$(stty size)\"; IFS= read -r _; printf 'RESIZED:%s\\n' \"$(stty size)\""
    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", command],
        env,
        (
            (b"READY:24 100", resize_pty_then_send(32, 121, b"\n")),
            (b"RESIZED:32 121", None),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_forced_tty_marks_stream_as_tty(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["--no-terminal-emulator", "-tt", "test-host", "tty"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "/dev/" not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_requested_tty_uses_stream_path(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_interleaved_tty_and_no_terminal_emulator_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "-t", "--no-terminal-emulator", "test-host", "exit 3"],
        env,
        (),
        timeout=10.0,
    )

    if result.returncode != 3:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_false_config_uses_stream_path(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "terminal-emulator=false\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_cli_overrides_disabled_config(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "terminal-emulator=no\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--terminal-emulator", "-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "plain_ssh=1" in log_text or "batch_mode=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_tty_uses_single_stream_guid(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_command_in_tty_uses_single_stream_guid(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "test-host", "echo", "hello"],
        env,
        ((b"hello", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text:
        raise AssertionError(log_text)


def test_ssh_tty_uses_emulated_term_not_outer_term(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["TERM"] = "ansi"
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "-tt", "test-host", "printf '%s\\n' \"$TERM\""],
        env,
        ((b"xterm-256color", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "ansi" in result.stdout:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_copies_outer_term(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["TERM"] = "ansi"
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", "printf '%s\\n' \"$TERM\""],
        env,
        ((b"ansi", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_copies_local_tty_modes(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = (
        "tokens=$(stty -a | tr ' ;' '\\n\\n'); "
        "printf '%s\\n' \"$tokens\" | grep -x -- -echo >/dev/null && "
        "printf '%s\\n' \"$tokens\" | grep -x -- -icanon >/dev/null && "
        "printf '%s\\n' \"$tokens\" | grep -x -- -icrnl >/dev/null && "
        "printf 'REMOTE_TTY_MODES\\r\\n' || { stty -a; exit 7; }"
    )
    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", command],
        env,
        ((b"REMOTE_TTY_MODES", None),),
        timeout=10.0,
        child_tty_setup=set_no_terminal_emulator_tty_mode_probe,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_copies_local_output_modes(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = (
        "tokens=$(stty -a | tr ' ;' '\\n\\n'); "
        "printf '%s\\n' \"$tokens\" | grep -x -- -opost >/dev/null && "
        "printf 'REMOTE_OUTPUT_MODES\\r\\n' || { stty -a; exit 7; }"
    )
    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", command],
        env,
        ((b"REMOTE_OUTPUT_MODES", None),),
        timeout=10.0,
        child_tty_setup=set_no_terminal_emulator_output_mode_probe,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_sets_ssh_tty(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = "test -n \"${SSH_TTY:-}\" && test -c \"$SSH_TTY\" && printf 'SSH_TTY_OK\\r\\n'"
    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", command],
        env,
        ((b"SSH_TTY_OK", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_interactive_shell_keeps_prompt_aligned(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_shell = tmp / "fake-remote-shell"
    write_fake_ssh(fake_bin / "ssh")
    fake_shell.write_text(
        "#!/bin/sh\n"
        "printf 'REMOTE_PROMPT\\n%% '\n"
        "while IFS= read -r line; do\n"
        "  case \"$line\" in\n"
        "    'echo hello') printf 'hello\\nREMOTE_PROMPT\\n%% ' ;;\n"
        "    exit) exit 0 ;;\n"
        "    *) printf 'UNKNOWN:%s\\nREMOTE_PROMPT\\n%% ' \"$line\" ;;\n"
        "  esac\n"
        "done\n"
    )
    fake_shell.chmod(fake_shell.stat().st_mode | stat.S_IXUSR)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_SHELL"] = str(fake_shell)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "test-host"],
        env,
        (
            (b"REMOTE_PROMPT\r\n% ", b"echo hello\n"),
            (b"hello\r\nREMOTE_PROMPT\r\n% ", b"exit\n"),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "REMOTE_PROMPT\n% " in result.stdout:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_release_artifact_restores_local_tty_on_exit(tmp):
    artifact = local_artifact()
    if not artifact.exists():
        print(f"SKIP release artifact tty restore test; missing {artifact}", file=sys.stderr)
        return

    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_shell = tmp / "fake-remote-shell"
    write_fake_ssh(fake_bin / "ssh")
    fake_shell.write_text(
        "#!/bin/sh\n"
        "printf 'REMOTE_READY\\n%% '\n"
        "while IFS= read -r line; do\n"
        "  case \"$line\" in\n"
        "    exit) exit 0 ;;\n"
        "    *) printf 'REMOTE_READY\\n%% ' ;;\n"
        "  esac\n"
        "done\n"
    )
    fake_shell.chmod(fake_shell.stat().st_mode | stat.S_IXUSR)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_SHELL"] = str(fake_shell)
    seed_remote_artifact_cache(env, artifact)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "test-host"],
        env,
        ((b"REMOTE_READY\r\n% ", b"exit\n"),),
        timeout=10.0,
        binary=artifact,
        capture_tty_attrs=True,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if result.tty_attrs_before != result.tty_attrs_after:
        raise AssertionError(
            "no-terminal-emulator release artifact did not restore local tty modes\n"
            f"before: {tty_attr_summary(result.tty_attrs_before)}\n"
            f"after:  {tty_attr_summary(result.tty_attrs_after)}\n"
            f"output: {result.stdout!r}"
        )


def test_ssh_terminal_emulator_release_artifact_restores_local_tty_on_exit(tmp):
    artifact = local_artifact()
    if not artifact.exists():
        print(f"SKIP release artifact tty restore test; missing {artifact}", file=sys.stderr)
        return

    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env, artifact)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "-t", "test-host", "printf 'TERMINAL_EMULATOR_READY\\n'; exit 0"],
        env,
        ((b"TERMINAL_EMULATOR_READY", None),),
        timeout=10.0,
        binary=artifact,
        capture_tty_attrs=True,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if result.tty_attrs_before != result.tty_attrs_after:
        raise AssertionError(
            "terminal-emulator release artifact did not restore local tty modes\n"
            f"before: {tty_attr_summary(result.tty_attrs_before)}\n"
            f"after:  {tty_attr_summary(result.tty_attrs_after)}\n"
            f"output: {result.stdout!r}"
        )


def test_ssh_remote_command_stream_reconnects_after_transport_loss(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    kill_file = tmp / "kill-stream-transport"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_KILL_BATCH_ONCE_FILE"] = str(kill_file)
    seed_remote_artifact_cache(env)

    command = (
        "printf 'STREAM_BEFORE\\n'; "
        f": > {shlex.quote(str(kill_file))}; "
        "sleep 0.2; "
        "printf 'STREAM_AFTER\\n'"
    )
    result = run_sessh(["test-host", command], env, timeout=40.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "STREAM_BEFORE\nSTREAM_AFTER\n":
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting 10sec" not in result.stderr:
        raise AssertionError(result)
    if "sessh: disconnected: Reconnecting..." not in result.stderr:
        raise AssertionError(result)
    if "\x1b[K" in result.stderr:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "kill_batch_triggered=1" not in log_text:
        raise AssertionError(log_text)
    if log_text.count("batch_mode=1") < 2:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_tty_reconnect_title_restores_app_title(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    kill_file = tmp / "kill-no_terminal_emulator-transport"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_KILL_BATCH_ONCE_FILE"] = str(kill_file)
    seed_remote_artifact_cache(env)

    command = (
        "printf '\\033]2;remote-title\\033\\\\NO_TERMINAL_EMULATOR_READY\\r\\n'; "
        f": > {shlex.quote(str(kill_file))}; "
        "sleep 0.2; "
        "printf 'NO_TERMINAL_EMULATOR_AFTER\\r\\n'"
    )
    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", command],
        env,
        (
            (b"NO_TERMINAL_EMULATOR_READY", None),
            (title_sequence("10sec retry CTRL-R").encode(), b"\x12"),
            (b"NO_TERMINAL_EMULATOR_AFTER", None),
        ),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected:" in result.stdout:
        raise AssertionError(result)
    if "CTRL-C detach" in result.stdout:
        raise AssertionError(result)
    retry_index = result.stdout.find(title_sequence("10sec retry CTRL-R"))
    restore_index = result.stdout.find(title_sequence("remote-title"), retry_index + 1)
    if retry_index < 0 or restore_index < 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "kill_batch_triggered=1" not in log_text:
        raise AssertionError(log_text)
    if log_text.count("batch_mode=1") < 2:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_tty_escape_disconnects(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", "printf 'ESCAPE_READY\\r\\n'; while :; do sleep 1; done"],
        env,
        ((b"ESCAPE_READY", b"\r~."),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "~." in result.stdout:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_escape_help(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", "printf 'HELP_READY\\r\\n'; while :; do sleep 1; done"],
        env,
        (
            (b"HELP_READY", b"\r~?"),
            (b"Supported escape sequences", b"\r~."),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "~.  disconnect" not in result.stdout:
        raise AssertionError(result)
    if "~~  send ~" not in result.stdout:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_escape_doubled_tilde(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "--no-terminal-emulator", "-tt", "test-host", "printf 'TILDE_READY\\r\\n'; IFS= read -r line; printf 'LINE:%s\\r\\n' \"$line\""],
        env,
        (
            (b"TILDE_READY", b"~~hello\n"),
            (b"LINE:~hello", None),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "LINE:~~hello" in result.stdout:
        raise AssertionError(result)


def test_ssh_terminal_emulator_tty_escape_doubled_tilde(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "-tt", "test-host", "printf 'TILDE_READY\\n'; IFS= read -r line; printf 'LINE:%s\\n' \"$line\""],
        env,
        (
            (b"TILDE_READY", b"~~hello\n"),
            (b"LINE:~hello", None),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "LINE:~~hello" in result.stdout:
        raise AssertionError(result)


def test_ssh_terminal_emulator_tty_escape_help_modal_repaints(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    argv = [
        str(MUX_BIN),
        ":internal-sessh:",
        "-tt",
        "test-host",
        "printf 'HELP_READY\\n'; while IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done",
    ]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    output = b""
    waited = False
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, output, b"HELP_READY", 10.0)
        os.write(fd, b"\r~?")
        output = read_pty_until(fd, output, b"Any key to dismiss", 10.0)
        output = read_pty_until(fd, output, b"~.  detach", 10.0)
        os.write(fd, b"ignored\n")
        output = read_pty_until_count(fd, output, b"HELP_READY", 2, 10.0)
        os.write(fd, b"after\n")
        output = read_pty_until(fd, output, b"REMOTE:after", 10.0)
        os.write(fd, b"\r~.")

        deadline = time.monotonic() + 10.0
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                returncode = wait_status_to_returncode(status)
                output += read_available_pty(fd)
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timed out waiting for pty command to exit; got {output!r}")
            ready, _, _ = select.select([fd], [], [], min(remaining, 0.05))
            if ready:
                output += read_available_pty(fd)
    finally:
        if not waited:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        os.close(fd)

    result = subprocess.CompletedProcess(argv, returncode, output.decode("utf-8", "replace"), "")
    if result.returncode != 0:
        raise AssertionError(result)
    if "REMOTE:ignored" in result.stdout:
        raise AssertionError(result)


def test_ssh_forced_tty_remote_command_allocates_pty_with_stdin_null(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)

    result = run_sessh(["-tt", "test-host", "tty"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "/dev/" not in result.stdout:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)
    trace_text = fake_trace.read_text()
    runtime_invocation = re.search(r"event=parsed .*config_query=0 .*saw_t=1 request_tty=0", trace_text)
    if runtime_invocation is None:
        raise AssertionError(trace_text)


def test_ssh_requested_tty_remote_command_allocates_pty_with_tty_stdin(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sesshmux_in_pty(
        [":internal-sessh:", "-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "/dev/" not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)

def test_ssh_single_tty_remote_command_with_stdin_null_uses_direct_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["-t", "test-host", "tty"], env, timeout=5.0)

    if result.returncode != 1:
        raise AssertionError(result)
    if "not a tty" not in result.stdout:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "batch_mode=1" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_tty_empty_remote_command_starts_interactive_session(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "INTERACTIVE_EMPTY_COMMAND_READY"
    remote_shell.write_text(
        "#!/bin/sh\n"
        "if [ \"${1-}\" = -c ]; then\n"
        "  printf 'UNEXPECTED_SHELL_COMMAND:%s\\n' \"${2-}\"\n"
        "  exit 9\n"
        "fi\n"
        f"printf '{marker}\\n'\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["-tt", "test-host", ""], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout or "UNEXPECTED_SHELL_COMMAND" in result.stdout:
        raise AssertionError(result)


def test_ssh_tty_quoted_empty_remote_command_uses_shell_eval(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    remote_shell.write_text(
        "#!/bin/sh\n"
        "if [ \"${1-}\" = -c ]; then\n"
        "  printf 'SHELL_COMMAND:%s\\n' \"${2-}\"\n"
        "  exit 7\n"
        "fi\n"
        "printf 'UNEXPECTED_INTERACTIVE\\n'\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["-tt", "test-host", '""'], env, timeout=30.0)

    if result.returncode != 7:
        raise AssertionError(result)
    if 'SHELL_COMMAND:""' not in result.stdout or "UNEXPECTED_INTERACTIVE" in result.stdout:
        raise AssertionError(result)


def test_sesshmux_unknown_command_does_not_fallback_to_plain_ssh(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_ALLOW_PLAIN"] = "1"

    result = run_sesshmux(["example.com", "list"], env, timeout=5.0)

    if result.returncode != 64:
        raise AssertionError(result)
    if "sesshmux: unsupported command" not in result.stderr:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr or "PLAIN_SSH" in result.stdout:
        raise AssertionError(result)
    if fake_log.exists():
        raise AssertionError(fake_log.read_text())


def test_internal_sessh_rejects_dot_host(tmp):
    env = isolated_env(tmp)

    bare = run_sesshmux([":internal-sessh:", "."], env, timeout=5.0)
    if bare.returncode != 64 or '"." is not a valid ssh host' not in bare.stderr:
        raise AssertionError(bare)

    with_command = run_sesshmux([":internal-sessh:", ".", "list"], env, timeout=5.0)
    if with_command.returncode != 64 or '"." is not a valid ssh host' not in with_command.stderr:
        raise AssertionError(with_command)


def test_internal_sessh_host_list_is_remote_command(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    list_command = fake_bin / "list"
    list_command.write_text("#!/bin/sh\nprintf 'REMOTE_LIST_COMMAND\\n'\n")
    list_command.chmod(0o700)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sesshmux([":internal-sessh:", "test-host", "list"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "REMOTE_LIST_COMMAND" not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_unsupported_option_does_not_fallback_for_sessh_action(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_ALLOW_PLAIN"] = "1"

    result = run_sesshmux(["attach", "-N", "test-host", "s1"], env, timeout=5.0)

    if result.returncode != 64:
        raise AssertionError(result)
    if "ssh option is not safe for sessh transport" not in result.stderr:
        raise AssertionError(result.stderr)
    if fake_log.exists():
        raise AssertionError(fake_log.read_text())


def test_ssh_config_only_cli_options_are_rejected(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    for args in (
        ["--leader", "CTRL-B", "test-host"],
        ["--scrollback-limit", "100", "test-host"],
        ["--initial-scrollback", "0", "test-host"],
        ["--bootstrap", "test-host"],
        ["--no-bootstrap", "test-host"],
        ["--ssh-options", "-F cfg", "test-host"],
    ):
        result = run_sessh(args, env, timeout=5.0)
        if result.returncode != 64:
            raise AssertionError((args, result))
        if "unsupported sessh option" not in result.stderr:
            raise AssertionError((args, result.stderr))
    if fake_log.exists():
        raise AssertionError(fake_log.read_text())


def test_ssh_bootstrap_false_config_uses_remote_path_sesshmux(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_NO_BOOTSTRAP_CONFIG_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    config_dir = Path(env["XDG_CONFIG_HOME"]) / "sessh"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "sessh.env").write_text("bootstrap=false\n")
    write_fake_ssh(fake_bin / "ssh")
    (fake_bin / "sesshmux").write_text(
        "#!/bin/sh\n"
        "printf 'direct_broker=1\\n' >>\"$SESSH_FAKE_SSH_LOG\"\n"
        f"exec {shlex.quote(str(MUX_BIN))} \"$@\"\n"
    )
    (fake_bin / "sesshmux").chmod(0o700)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["test-host"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "direct_broker=1" not in log_text:
        raise AssertionError(log_text)
    if "bootstrapper=1" in log_text:
        raise AssertionError(log_text)
    assert_cached_artifact(env, remote_path_artifact(), "bootstrap=false")


def test_ssh_attach_without_id_reattaches_latest_session(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_ATTACH_LATEST_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\nwhile :; do sleep 1; done\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    first = run_sessh_until_stdout(["test-host"], env, marker)
    if first.returncode != 0:
        raise AssertionError(first)

    attached = run_sesshmux_until_stdout(["attach", "--host", "test-host"], env, marker)

    if attached.returncode != 0:
        raise AssertionError(attached)
    if marker not in attached.stdout:
        raise AssertionError(attached)
    if "remote commands are not supported yet" in attached.stderr:
        raise AssertionError(attached.stderr)


def test_mux_new_detached_creates_local_session_without_attach(tmp):
    env = isolated_env(tmp)
    shell = tmp / "detached-shell"
    marker = "LOCAL_DETACHED_READY"
    shell.write_text(
        "#!/bin/sh\n"
        f"printf '{marker}\\r\\n'\n"
        "while IFS= read -r line; do\n"
        "  [ \"$line\" = exit ] && exit 0\n"
        "  printf 'LOCAL_DETACHED_LINE:%s\\r\\n' \"$line\"\n"
        "done\n"
    )
    shell.chmod(0o700)
    env["SHELL"] = str(shell)

    created = run_sesshmux(["new", "--detached", "--alias", "detached-local", "."], env, timeout=10.0)

    if created.returncode != 0:
        raise AssertionError(created)
    if not created.stdout.startswith("CREATED s-"):
        raise AssertionError(created)
    if marker in created.stdout:
        raise AssertionError(f"detached create leaked session output:\n{created.stdout}")

    listed = run_sesshmux(["list", "--jsonl"], env, timeout=10.0)
    if listed.returncode != 0:
        raise AssertionError(listed)
    rows = [json.loads(line) for line in listed.stdout.splitlines() if line.strip()]
    matches = [row for row in rows if row.get("id") == "detached-local"]
    if len(matches) != 1:
        raise AssertionError(process_diagnostics(listed))
    if matches[0].get("attached_count") != 0:
        raise AssertionError(matches[0])

    attached = run_sesshmux_until_stdout(["attach", "detached-local"], env, marker, timeout=10.0)
    if attached.returncode != 0:
        raise AssertionError(attached)
    if marker not in attached.stdout:
        raise AssertionError(attached)


def test_mux_new_detached_creates_remote_route_without_attach(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_runtime = tmp / "remote-runtime"
    remote_state = tmp / "remote-state"
    remote_shell = tmp / "remote-detached-shell"
    marker = "REMOTE_DETACHED_READY"
    remote_runtime.mkdir(mode=0o700)
    remote_state.mkdir(mode=0o700)
    remote_shell.write_text(
        "#!/bin/sh\n"
        f"printf '{marker}\\r\\n'\n"
        "while IFS= read -r line; do\n"
        "  [ \"$line\" = exit ] && exit 0\n"
        "  printf 'REMOTE_DETACHED_LINE:%s\\r\\n' \"$line\"\n"
        "done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR"] = str(remote_runtime)
    env["SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME"] = str(remote_state)
    env["SHELL"] = str(remote_shell)
    seed_remote_artifact_cache(env)

    created = run_sesshmux(["new", "--detached", "--alias", "remote-detached", "test-host"], env, timeout=30.0)

    if created.returncode != 0:
        raise AssertionError(created)
    if not created.stdout.startswith("CREATED s-"):
        raise AssertionError(created)
    if marker in created.stdout:
        raise AssertionError(f"detached create leaked session output:\n{created.stdout}")

    listed = run_sesshmux(["list", "--jsonl"], env, timeout=30.0)
    if listed.returncode != 0:
        raise AssertionError(listed)
    rows = [json.loads(line) for line in listed.stdout.splitlines() if line.strip()]
    matches = [row for row in rows if row.get("id") == "remote-detached"]
    if len(matches) != 1:
        raise AssertionError(process_diagnostics(listed))
    if matches[0].get("host") != "test-host":
        raise AssertionError(matches[0])

    attached = run_sesshmux_until_stdout(["attach", "--host", "test-host", "remote-detached"], env, marker, timeout=30.0)
    if attached.returncode != 0:
        raise AssertionError(attached)
    if marker not in attached.stdout:
        raise AssertionError(attached)


def test_ssh_no_host_attach_uses_local_route(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_ROUTE_ATTACH_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf 'ID=%s GUID=%s {marker}\\n' \"${{SESSH_ID-unset}}\" \"$SESSH_GUID\"\nwhile :; do sleep 1; done\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    first = run_sessh_until_stdout(["--alias", "route-alias", "test-host"], env, marker)
    if first.returncode != 0:
        raise AssertionError(first)
    if "ID=unset GUID=" not in first.stdout:
        raise AssertionError(first)

    changed_runtime_env = dict(env)
    changed_runtime_env["XDG_RUNTIME_DIR"] = str(tmp / "changed-runtime")
    attached = run_sesshmux_until_stdout(["attach", "route-alias"], changed_runtime_env, marker)
    if attached.returncode != 0:
        raise AssertionError(attached)
    if marker not in attached.stdout:
        raise AssertionError(attached)
    killed = run_sesshmux(["kill", "route-alias"], changed_runtime_env, timeout=30.0)
    if killed.returncode != 0:
        raise AssertionError(killed)
    if not killed.stdout.startswith("ENDED "):
        raise AssertionError(killed)
    listed_exited = run_sesshmux(["list", "--exited", "--jsonl"], changed_runtime_env, timeout=30.0)
    if listed_exited.returncode != 0:
        raise AssertionError(listed_exited)
    rows = [json.loads(line) for line in listed_exited.stdout.splitlines() if line.strip()]
    matches = [row for row in rows if row.get("id") == "route-alias"]
    if len(matches) != 1:
        raise AssertionError(process_diagnostics(listed_exited))
    row = matches[0]
    if row.get("host") != "test-host" or row.get("end_reason") != "killed_by_request" or row.get("exit_status") is not None:
        raise AssertionError(row)
    guid = row.get("guid")
    if not guid:
        raise AssertionError(row)
    if (state_sessions_dir(changed_runtime_env) / guid / "route.json").exists():
        raise AssertionError("local cached route was not tombstoned after remote kill")
    if (aliases_dir(changed_runtime_env) / "route-alias").exists() or (aliases_dir(changed_runtime_env) / "route-alias").is_symlink():
        raise AssertionError("local cached route alias was not released after remote kill")
    log_text = fake_log.read_text()
    if log_text.splitlines().count("invoked=1") < 2:
        raise AssertionError(log_text)


def test_ssh_no_host_attach_uses_latest_detached_route(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND"] = "42"
    write_ssh_route(env, "older-detached", guid_for_alias("older-detached"), "older-host", detached_at_unix_ms=1000)
    write_ssh_route(env, "newer-detached", guid_for_alias("newer-detached"), "newer-host", detached_at_unix_ms=2000)

    result = run_sesshmux(["attach"], env, timeout=30.0)

    if result.returncode == 0:
        raise AssertionError(result)
    trace_text = optional_text(fake_trace)
    if "event=parsed host=newer-host" not in trace_text:
        raise AssertionError(
            "bare attach did not choose newest detached route\n"
            f"fake ssh trace:\n{trace_text}\n"
            f"sesshmux result:\n{process_diagnostics(result)}"
        )
    if "event=parsed host=older-host" in trace_text:
        raise AssertionError(trace_text)

    explicit_local = run_sesshmux(["attach", "--host", "."], env, timeout=30.0)
    if explicit_local.returncode == 0:
        raise AssertionError(explicit_local)
    if optional_text(fake_trace).count("event=parsed host=") != trace_text.count("event=parsed host="):
        raise AssertionError("explicit --host . unexpectedly invoked ssh")


def test_ssh_no_host_attach_skips_route_attached_by_this_machine(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND"] = "42"

    older_guid = guid_for_alias("older-detached")
    busy_guid = guid_for_alias("busy-detached")
    write_ssh_route(env, "older-detached", older_guid, "older-host", detached_at_unix_ms=2000)
    write_ssh_route(env, "busy-detached", busy_guid, "busy-host", detached_at_unix_ms=3000)
    write_client_route_hint(env, "c-33333333-3333-4333-8333-333333333333", busy_guid)

    result = run_sesshmux(["attach"], env, timeout=30.0)

    if result.returncode == 0:
        raise AssertionError(result)
    trace_text = optional_text(fake_trace)
    if "event=parsed host=older-host" not in trace_text:
        raise AssertionError(
            "bare attach did not skip route with outgoing-client hint\n"
            f"fake ssh trace:\n{trace_text}\n"
            f"sesshmux result:\n{process_diagnostics(result)}"
        )
    if "event=parsed host=busy-host" in trace_text:
        raise AssertionError(trace_text)


def test_ssh_no_host_list_client_uses_remote_route(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND"] = "42"
    write_ssh_route(env, "remote-clients", guid_for_alias("remote-clients"), "test-host")

    missing_target = run_sesshmux(["list", "--client"], env, timeout=30.0)
    if missing_target.returncode != 64 or "incoming, outgoing, session" not in missing_target.stderr:
        raise AssertionError(missing_target)

    result = run_sesshmux(["list", "--client", "remote-clients"], env, timeout=30.0)

    if result.returncode == 0:
        raise AssertionError(result)
    log_text = optional_text(fake_log)
    if "invoked=1" not in log_text:
        raise AssertionError(
            "list --client did not delegate to ssh for a remote route\n"
            f"fake ssh log:\n{log_text}\n"
            f"sesshmux result:\n{process_diagnostics(result)}"
        )


def test_ssh_no_host_detach_client_uses_client_route_hint(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND"] = "42"
    alias = "remote-client-detach"
    guid = guid_for_alias(alias)
    client_guid = "c-33333333-3333-4333-8333-333333333333"
    write_ssh_route(env, alias, guid, "test-host")
    write_client_route_hint(env, client_guid, guid)

    result = run_sesshmux(["detach", client_guid], env, timeout=30.0)

    if result.returncode == 0:
        raise AssertionError(result)
    log_text = optional_text(fake_log)
    if "invoked=1" not in log_text:
        raise AssertionError(
            "detach did not delegate to ssh for a remote client route hint\n"
            f"fake ssh log:\n{log_text}\n"
            f"sesshmux result:\n{process_diagnostics(result)}"
        )


def test_ssh_list_refresh_tombstones_missing_remote_route(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    alias = "remote-dead"
    guid = guid_for_alias(alias)
    write_ssh_route(env, alias, guid, "test-host")

    result = run_sesshmux(["list", "--refresh", "--exited", "--jsonl"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    matches = [row for row in rows if row.get("guid") == guid]
    if len(matches) != 1:
        raise AssertionError(process_diagnostics(result))
    row = matches[0]
    if row.get("id") != alias or alias not in row.get("aliases", []):
        raise AssertionError(row)
    if row.get("host") != "test-host" or row.get("end_reason") != "unknown":
        raise AssertionError(row)
    if row.get("exit_status") is not None:
        raise AssertionError(row)
    if (state_sessions_dir(env) / guid / "route.json").exists():
        raise AssertionError("remote route was not moved to a tombstone")
    if (aliases_dir(env) / alias).exists() or (aliases_dir(env) / alias).is_symlink():
        raise AssertionError("remote route alias was not released")
    tombstone = tombstones_dir(env) / f"{guid}.json"
    if not tombstone.exists():
        raise AssertionError("tombstone file was not written")

    attached = run_sesshmux(["attach", alias], env, timeout=5.0)
    if attached.returncode == 0 or "session already exited" not in attached.stderr:
        raise AssertionError(attached)


def test_ssh_remote_default_alias_is_remote_generated(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_REMOTE_ALIAS_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\nwhile :; do sleep 1; done\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    first = run_sessh_until_stdout(["test-host"], env, marker)
    if first.returncode != 0:
        raise AssertionError(first)

    listed = run_sesshmux(["list", "test-host"], env, timeout=30.0)
    if listed.returncode != 0:
        raise AssertionError(listed)
    rows = list_rows(listed.stdout)
    aliases = [row[0] for row in rows if len(row) >= 1]
    remote_aliases = [alias for alias in aliases if re.fullmatch(r"s-[0-9a-f]{8}", alias)]
    if len(remote_aliases) != 1:
        raise AssertionError(listed.stdout)

    attached = run_sesshmux_until_stdout(["attach", "--host", "test-host", remote_aliases[0]], env, marker)
    if attached.returncode != 0:
        raise AssertionError(attached)


def test_ssh_host_attach_does_not_follow_remote_route(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    write_ssh_route(env, "remote-hop", guid_for_alias("remote-hop"), "other-host")

    result = run_sesshmux(["attach", "--host", "test-host", "remote-hop"], env, timeout=30.0)

    if result.returncode == 0:
        raise AssertionError(result)
    if "session reference resolves to another host" not in result.stderr:
        raise AssertionError(result)
    if "session not found" in result.stderr:
        raise AssertionError(result)


def test_ssh_leader_sever_reconnects(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_DELAY_ON_BATCH"] = "1"
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    result = run_sessh_reconnect_probe(
        ["test-host"],
        env,
        marker,
        "after-reconnect",
        during="during-reconnect",
        expect_countdown=True,
        expect_reconnecting=True,
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting 10sec" not in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting 9sec" not in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected: Reconnecting... CTRL-C detach" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:after-reconnect" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:during-reconnect" in result.stdout:
        raise AssertionError(result)
    if "ReconnectUnsupported" in result.stderr:
        raise AssertionError(result.stderr)
    if "batch_mode=1" not in fake_log.read_text():
        raise AssertionError("reconnect did not force ssh BatchMode=yes")


def test_ssh_debug_sever_reconnects_twice(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_DEBUG_SEVER_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["--alias", "s1", "test-host"])
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = b""
    stderr = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        for after in ("after-debug-sever-1", "after-debug-sever-2"):
            severed = run_sesshmux(["debug", "sever-connection", "--host", "test-host", "s1"], env, timeout=30.0)
            if severed.returncode != 0:
                raise AssertionError(severed)
            if not severed.stdout.startswith("SEVERED "):
                raise AssertionError(severed)

            stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", 30.0)
            proc.stdin.write(b"\x12")
            proc.stdin.flush()
            stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Reconnecting... CTRL-C detach", 30.0)
            stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
            proc.stdin.write(after.encode("utf-8") + b"\n")
            proc.stdin.flush()
            stdout += read_until_pipe(proc.stdout, f"REMOTE:{after}".encode("utf-8"), 30.0)

        proc.stdin.close()
        returncode = proc.wait(timeout=30.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "REMOTE:after-debug-sever-1" not in result.stdout or "REMOTE:after-debug-sever-2" not in result.stdout:
        raise AssertionError(result)
    if "batch_mode=1" not in fake_log.read_text():
        raise AssertionError("debug sever reconnect did not force ssh BatchMode=yes")


def test_ssh_unresponsive_reconnect_failure_keeps_input_on_old_connection_without_bell(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    batch_fail_file = tmp / "fail-batch-reconnect"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_UNRESPONSIVE_INPUT_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_EXIT_ON_BATCH_FILE"] = str(batch_fail_file)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["--alias", "s1", "test-host"])
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        before_batch_count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0

        unresponsive = run_sesshmux(["debug", "unresponsive-connection", "--seconds", "30", "--host", "test-host", "s1"], env, timeout=30.0)
        if unresponsive.returncode != 0:
            raise AssertionError(unresponsive)
        if not unresponsive.stdout.startswith("UNRESPONSIVE "):
            raise AssertionError(unresponsive)

        batch_fail_file.touch()
        proc.stdin.write(b"trigger-unresponsive\n")
        proc.stdin.flush()
        wait_for_file_count(fake_log, "batch_mode=1", before_batch_count + 1, timeout=15.0)
        time.sleep(0.5)
        stdout += read_available_pipe(proc.stdout, 0.2)
        if b"sessh: unresponsive: Reconnecting" in stdout:
            raise AssertionError(f"unresponsive reconnect showed a reconnecting banner:\n{stdout!r}")
        if b"sessh: disconnected: Reconnecting" in stdout:
            raise AssertionError(f"recoverable unresponsive connection showed a disconnected banner:\n{stdout!r}")

        proc.stdin.write(b"input-after-failed-reconnect\n")
        proc.stdin.flush()
        after_input = read_available_pipe(proc.stdout, 1.0)
        stdout += after_input
        if b"\x07" in after_input:
            raise AssertionError(f"unresponsive input belled instead of forwarding to old connection:\n{after_input!r}")

        proc.stdin.write(b"\x03")
        proc.stdin.flush()
        proc.stdin.close()
        returncode = proc.wait(timeout=10.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "\x07" in result.stdout:
        raise AssertionError(result)
    if "sessh: unresponsive: Reconnecting" in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected: Reconnecting" in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting" in result.stdout:
        raise AssertionError(result)


def test_ssh_unresponsive_tty_sets_title_without_banner(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_UNRESPONSIVE_TITLE_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["--alias", "s1", "test-host"])
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    output = b""
    waited = False
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, output, marker.encode("utf-8"), timeout=30.0)
        before_batch_count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0

        unresponsive = run_sesshmux(["debug", "unresponsive-connection", "--seconds", "30", "--host", "test-host", "s1"], env, timeout=30.0)
        if unresponsive.returncode != 0:
            raise AssertionError(unresponsive)
        if not unresponsive.stdout.startswith("UNRESPONSIVE "):
            raise AssertionError(unresponsive)

        os.write(fd, b"trigger-unresponsive\r")
        wait_for_file_count(fake_log, "batch_mode=1", before_batch_count + 1, timeout=15.0)
        output = read_pty_until(fd, output, title_sequence("reconnecting CTRL-R").encode(), timeout=15.0)
        if b"sessh: unresponsive: Reconnecting" in output:
            raise AssertionError(output)
        if b"sessh: disconnected: Reconnecting" in output:
            raise AssertionError(output)

        os.write(fd, b"\x03")
        deadline = time.monotonic() + 10.0
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                returncode = wait_status_to_returncode(status)
                output += read_available_pty(fd)
                break
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for detach; got {output!r}")
            output += read_available_pty(fd)
            time.sleep(0.05)
    finally:
        if not waited:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        os.close(fd)

    if returncode != 0:
        raise AssertionError(output.decode("utf-8", "replace"))


def test_ssh_unresponsive_reconnect_retries_after_prepare_failure(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    batch_fail_file = tmp / "fail-batch-reconnect"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_UNRESPONSIVE_RETRY_READY"
    after = "after-unresponsive-retry"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_EXIT_ON_BATCH_FILE"] = str(batch_fail_file)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["--alias", "s1", "test-host"])
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = b""
    stderr = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        before_batch_count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0

        unresponsive = run_sesshmux(["debug", "unresponsive-connection", "--seconds", "30", "--host", "test-host", "s1"], env, timeout=30.0)
        if unresponsive.returncode != 0:
            raise AssertionError(unresponsive)
        if not unresponsive.stdout.startswith("UNRESPONSIVE "):
            raise AssertionError(unresponsive)

        batch_fail_file.touch()
        proc.stdin.write(b"trigger-unresponsive\n")
        proc.stdin.flush()
        wait_for_file_count(fake_log, "batch_mode=1", before_batch_count + 1, timeout=15.0)
        batch_fail_file.unlink()
        wait_for_file_count(fake_log, "batch_mode=1", before_batch_count + 2, timeout=25.0)
        stdout += read_until_pipe(proc.stdout, b"sessh: unresponsive: Connection ready", 15.0)
        if b"sessh: unresponsive: Reconnecting" in stdout:
            raise AssertionError(f"unresponsive retry showed reconnecting banner:\n{stdout!r}")
        if b"sessh: disconnected: Reconnecting" in stdout:
            raise AssertionError(f"unresponsive retry showed disconnected banner:\n{stdout!r}")

        proc.stdin.write(b"\x12")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 15.0)
        proc.stdin.write(after.encode("utf-8") + b"\n")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, f"REMOTE:{after}".encode("utf-8"), 15.0)
        proc.stdin.close()
        returncode = proc.wait(timeout=10.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: unresponsive: Reconnecting" in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected: Reconnecting" in result.stdout:
        raise AssertionError(result)
    if "sessh: unresponsive: Connection ready" not in result.stdout:
        raise AssertionError(result)
    if f"REMOTE:{after}" not in result.stdout:
        raise AssertionError(result)


def test_ssh_unresponsive_old_connection_recovers_without_switch_or_bell(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_UNRESPONSIVE_RECOVERY_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["--alias", "s1", "test-host"])
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = b""
    stderr = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        before_batch_count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0

        unresponsive = run_sesshmux(["debug", "unresponsive-connection", "--seconds", "6", "--host", "test-host", "s1"], env, timeout=30.0)
        if unresponsive.returncode != 0:
            raise AssertionError(unresponsive)
        if not unresponsive.stdout.startswith("UNRESPONSIVE "):
            raise AssertionError(unresponsive)

        proc.stdin.write(b"trigger-unresponsive\n")
        proc.stdin.flush()
        wait_for_file_count(fake_log, "batch_mode=1", before_batch_count + 1, timeout=15.0)
        stdout += read_available_pipe(proc.stdout, 0.2)
        if b"sessh: unresponsive: Reconnecting" in stdout:
            raise AssertionError(f"unresponsive reconnect showed a reconnecting banner:\n{stdout!r}")
        if b"sessh: disconnected: Reconnecting" in stdout:
            raise AssertionError(f"recoverable unresponsive connection showed a disconnected banner:\n{stdout!r}")

        proc.stdin.write(b"input-after-banner\n")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, b"REMOTE:trigger-unresponsive", 15.0)
        if b"REMOTE:input-after-banner" not in stdout:
            stdout += read_until_pipe(proc.stdout, b"REMOTE:input-after-banner", 15.0)

        proc.stdin.write(b"~.")
        proc.stdin.flush()
        proc.stdin.close()
        returncode = proc.wait(timeout=10.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "\x07" in result.stdout:
        raise AssertionError(result)
    if "sessh: unresponsive: Reconnecting" in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected: Reconnecting" in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting" in result.stdout:
        raise AssertionError(result)


def test_ssh_unresponsive_transport_close_uses_disconnected_ready_banner(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_UNRESPONSIVE_CLOSE_READY"
    after = "after-unresponsive-close"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["--alias", "s1", "test-host"])
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = b""
    stderr = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        before_batch_count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0

        unresponsive = run_sesshmux(["debug", "unresponsive-connection", "--seconds", "30", "--host", "test-host", "s1"], env, timeout=30.0)
        if unresponsive.returncode != 0:
            raise AssertionError(unresponsive)
        if not unresponsive.stdout.startswith("UNRESPONSIVE "):
            raise AssertionError(unresponsive)

        proc.stdin.write(b"trigger-unresponsive\n")
        proc.stdin.flush()
        wait_for_file_count(fake_log, "batch_mode=1", before_batch_count + 1, timeout=15.0)
        stdout += read_until_pipe(proc.stdout, b"sessh: unresponsive: Connection ready", 15.0)
        if b"sessh: disconnected: Reconnecting" in stdout:
            raise AssertionError(f"unresponsive connection showed disconnected before transport close:\n{stdout!r}")

        severed = run_sesshmux(["debug", "sever-connection", "--host", "test-host", "s1"], env, timeout=30.0)
        if severed.returncode != 0:
            raise AssertionError(severed)
        if not severed.stdout.startswith("SEVERED "):
            raise AssertionError(severed)

        stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Connection ready", 15.0)
        proc.stdin.write(b"\x12")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 15.0)
        proc.stdin.write(after.encode("utf-8") + b"\n")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, f"REMOTE:{after}".encode("utf-8"), 15.0)
        proc.stdin.close()
        returncode = proc.wait(timeout=10.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: unresponsive: Reconnecting" in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected: Reconnecting" in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected: Connection ready" not in result.stdout:
        raise AssertionError(result)
    if f"REMOTE:{after}" not in result.stdout:
        raise AssertionError(result)


def test_ssh_retry_elapsed_with_input_waits_before_switch(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_TIMER_READY"
    after = "after-timer-reconnect"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    argv = sessh_argv(["test-host"])
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 10.0)
        proc.stdin.write(b"\x02s")
        proc.stdin.flush()
        reconnect_output = read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", 10.0)
        proc.stdin.write(b"during-timer\n")
        proc.stdin.flush()
        reconnect_output += read_until_pipe(proc.stdout, b"\x07", 10.0)
        reconnect_output += read_until_pipe(proc.stdout, b"sessh: disconnected: Reconnecting... CTRL-C detach", 12.0)
        reconnect_output += read_until_pipe(
            proc.stdout,
            b"sessh: disconnected: Connection ready. Switch 10sec. CTRL-R now. CTRL-C detach",
            10.0,
        )
        reconnect_output += read_available_pipe(proc.stdout, 0.5)
        if marker.encode("utf-8") in reconnect_output:
            raise AssertionError(f"reconnect repainted before Ctrl-R:\n{reconnect_output!r}")

        proc.stdin.write(b"\x12")
        proc.stdin.flush()
        stdout += reconnect_output
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 10.0)
        proc.stdin.write(after.encode("utf-8") + b"\n")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, f"REMOTE:{after}".encode("utf-8"), 10.0)
        proc.stdin.close()
        returncode = proc.wait(timeout=10.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Connection ready. Switch 10sec. CTRL-R now. CTRL-C detach" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:during-timer" in result.stdout:
        raise AssertionError(result)
    if f"REMOTE:{after}" not in result.stdout:
        raise AssertionError(result)
    if "sessh: reconnected" in result.stdout:
        raise AssertionError(result)
    if "batch_mode=1" not in fake_log.read_text():
        raise AssertionError("timer reconnect did not force ssh BatchMode=yes")


def test_ssh_retry_elapsed_without_input_switches_automatically(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_TIMER_AUTO_READY"
    after = "after-auto-reconnect"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    argv = sessh_argv(["test-host"])
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 10.0)
        proc.stdin.write(b"\x02s")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", 10.0)
        stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Reconnecting... CTRL-C detach", 12.0)
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 10.0)
        proc.stdin.write(after.encode("utf-8") + b"\n")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, f"REMOTE:{after}".encode("utf-8"), 10.0)
        proc.stdin.close()
        returncode = proc.wait(timeout=10.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Connection ready" in result.stdout:
        raise AssertionError(result)
    if f"REMOTE:{after}" not in result.stdout:
        raise AssertionError(result)
    if "batch_mode=1" not in fake_log.read_text():
        raise AssertionError("timer reconnect did not force ssh BatchMode=yes")


def test_ssh_no_echo_input_ack_prevents_false_unresponsive(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_INPUT_ACK_READY"
    remote_shell.write_text(
        f"""#!/bin/sh
stty -echo
printf '{marker}\\n'
while IFS= read -r line; do
  case "$line" in
    slow-no-output)
      sleep 3
      printf 'REMOTE:old-recovered\\n'
      stty echo
      ;;
    after-recovery)
      printf 'REMOTE:after-recovery\\n'
      exit 0
      ;;
    *)
      printf 'REMOTE:%s\\n' "$line"
      ;;
  esac
done
"""
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["test-host"])
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        stdout = read_until_pipe(proc.stdout, marker.encode("utf-8"), 10.0)
        proc.stdin.write(b"slow-no-output\n")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, b"REMOTE:old-recovered", 10.0)
        proc.stdin.write(b"after-recovery\n")
        proc.stdin.flush()
        stdout += read_until_pipe(proc.stdout, b"REMOTE:after-recovery", 10.0)
        proc.stdin.close()
        returncode = proc.wait(timeout=10.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Unresponsive" in result.stdout:
        raise AssertionError(result)
    if "batch_mode=1" in fake_log.read_text():
        raise AssertionError("false unresponsive detection started a parallel reconnect attempt")


def test_ssh_reconnect_displays_live_ssh_stderr_in_banner(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_STDERR_READY"
    raw_ssh_error = (
        "error: looks like you are not connected to the VPN. Please connect to the VPN and try again\n"
        "Connection to test-host closed by remote host.\n"
        "client_loop: send disconnect: Broken pipe\n"
        "control sequence: \x1b[31mred"
    )
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_STDERR_ON_BATCH"] = raw_ssh_error
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    result = run_sessh_reconnect_probe(
        ["test-host"],
        env,
        marker,
        "after-reconnect",
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting 10sec" not in result.stdout:
        raise AssertionError(result)
    if raw_ssh_error in result.stdout:
        raise AssertionError(result)
    expected_messages = [
        "--- sessh: disconnected: Retry connecting 10sec. CTRL-R now. CTRL-C detach ---",
        "--- sessh: disconnected: Reconnecting... CTRL-C detach ---",
        "ssh: Connection to test-host closed by remote host.",
        "ssh: client_loop: send disconnect: Broken pipe",
        "ssh: control sequence: ?[31mred",
    ]
    actual_messages = normalized_ui_messages(result.stdout)
    if actual_messages != expected_messages:
        raise AssertionError(f"expected UI messages {expected_messages!r}, got {actual_messages!r}\n{result}")
    if "\x1b[31mred" in result.stdout:
        raise AssertionError(result)
    if "ssh stderr:" in result.stdout or "sessh: log" in result.stdout or "level=warn" in result.stdout:
        raise AssertionError(result)
    if strip_bootstrap_status(result.stderr):
        raise AssertionError(result)
    if (Path(env["XDG_CACHE_HOME"]) / "sessh" / "clients").exists():
        raise AssertionError("client logs were written to persistent cache")


def test_ssh_log_level_quiet_suppresses_buffered_stderr_display(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_QUIET_READY"
    raw_ssh_error = "client_loop: send disconnect: Broken pipe"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_STDERR_ON_BATCH"] = raw_ssh_error
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    result = run_sessh_reconnect_probe(
        ["--log-level", "quiet", "test-host"],
        env,
        marker,
        "after-reconnect",
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if raw_ssh_error in result.stderr or raw_ssh_error in result.stdout:
        raise AssertionError(result)
    if "sessh: log" in result.stderr:
        raise AssertionError(result)


def test_ssh_session_buffers_and_displays_stderr_after_attach(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    signal_file = tmp / "stderr-signal"
    done_file = tmp / "stderr-done"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_ACTIVE_STDERR_READY"
    raw_ssh_error = "client_loop: send disconnect: Broken pipe"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_STDERR_AFTER_SIGNAL"] = raw_ssh_error
    env["SESSH_FAKE_SSH_STDERR_SIGNAL_FILE"] = str(signal_file)
    env["SESSH_FAKE_SSH_STDERR_DONE_FILE"] = str(done_file)
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    argv = sessh_argv(["test-host"])
    proc = subprocess.Popen(
        argv,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        stdout = read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        signal_file.write_text("")
        wait_for_path(done_file, 10.0)
        proc.stdin.write(b"\x02d")
        proc.stdin.flush()
        proc.stdin.close()
        returncode = proc.wait(timeout=30.0)
    finally:
        if proc.poll() is None:
            proc.kill()
            returncode = proc.wait(timeout=30.0)
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if raw_ssh_error in result.stdout:
        raise AssertionError(result)
    expected = f"ssh ts_ms="
    if expected not in result.stderr or f": {raw_ssh_error}" not in result.stderr:
        raise AssertionError(result)
    if "ssh stderr:" in result.stderr or "sessh: log" in result.stderr or "level=warn" in result.stderr:
        raise AssertionError(result)
    if (Path(env["XDG_CACHE_HOME"]) / "sessh" / "clients").exists():
        raise AssertionError("client logs were written to persistent cache")


def test_ssh_reconnect_does_not_apply_active_screen_cleanup(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    primary_marker = "PRIMARY_SCREEN_SHOULD_NOT_REPLAY_ON_RECONNECT"
    alt_marker = "ALT_SCREEN_RECONNECT_READY"
    remote_shell.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' '{primary_marker}'\n"
        "IFS= read -r _\n"
        f"printf '\\033[?1049h%s\\n' '{alt_marker}'\n"
        "while :; do sleep 1; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_DELAY_ON_BATCH"] = "1"
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    result = run_sessh_enter_alt_then_reconnect_banner(
        ["test-host"],
        env,
        primary_marker,
        alt_marker,
        timeout=30.0,
    )

    if "sessh: disconnected: Retry connecting 10sec" not in result.stdout:
        raise AssertionError(result)
    if primary_marker in result.stdout:
        raise AssertionError(result)


def test_ssh_reconnect_can_detach_while_bootstrapping(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_ABORT_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_DELAY_ON_BATCH"] = "20"
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    result = run_sessh_detach_reconnect_probe(
        ["test-host"],
        env,
        marker,
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting 10sec" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:" in result.stdout:
        raise AssertionError(result)


def test_ssh_reconnect_can_detach_with_ctrl_c(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_CTRL_C_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_DELAY_ON_BATCH"] = "20"
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    result = run_sessh_detach_reconnect_probe(
        ["test-host"],
        env,
        marker,
        detach_bytes=b"\x03",
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting 10sec" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:" in result.stdout:
        raise AssertionError(result)


def test_ssh_leader_detach_exits_while_remote_output_is_flowing(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_DETACH_STREAM_READY"
    remote_shell.write_text(
        "#!/bin/sh\n"
        f"printf '{marker}\\n'\n"
        "i=1\n"
        "while :; do\n"
        "  printf 'SSH_DETACH_STREAM_%06d\\n' \"$i\"\n"
        "  i=$((i + 1))\n"
        "done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    result = run_sessh_detach_probe(
        ["test-host"],
        env,
        marker,
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)


def test_ssh_unsupported_remote_platform_falls_back_to_plain_ssh(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    remote_bin = tmp / "fake-remote-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    remote_bin.mkdir(parents=True, exist_ok=True)
    write_fake_uname(remote_bin / "uname", "Plan9", "sparc")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_ALLOW_PLAIN"] = "1"
    env["SESSH_FAKE_SSH_REMOTE_PATH"] = str(remote_bin)

    result = run_sessh(["test-host"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "PLAIN_SSH host=test-host" not in result.stdout:
        raise AssertionError(result)
    if "using plain-ssh-fallback without persistence" not in result.stderr:
        raise AssertionError(result)
    if "unsupported" not in result.stderr:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if log_text.splitlines().count("invoked=1") != 2:
        raise AssertionError(log_text)
    if "plain_ssh=1" not in log_text or "plain_host=test-host" not in log_text:
        raise AssertionError(log_text)


def test_ssh_unsupported_remote_platform_does_not_plain_ssh_fallback_for_attach(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    remote_bin = tmp / "fake-remote-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    remote_bin.mkdir(parents=True, exist_ok=True)
    write_fake_uname(remote_bin / "uname", "Plan9", "sparc")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_ALLOW_PLAIN"] = "1"
    env["SESSH_FAKE_SSH_REMOTE_PATH"] = str(remote_bin)

    result = run_sesshmux(["attach", "--host", "test-host", guid_for_alias("s1")], env, timeout=30.0)

    if result.returncode == 0:
        raise AssertionError(result)
    if "PLAIN_SSH" in result.stdout:
        raise AssertionError(result)
    if "plain_ssh=1" in fake_log.read_text():
        raise AssertionError(fake_log.read_text())
    if "remote platform is unsupported; cannot attach a sessh session" not in result.stderr:
        raise AssertionError(result)


def test_ssh_remote_session_commands_use_broker(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_REMOTE_COMMAND_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\nwhile :; do sleep 1; done\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    first = run_sessh_until_stdout(["--alias", "s1", "test-host"], env, marker)
    if first.returncode != 0:
        raise AssertionError(first)

    assert_session_compat_points_to_cached_artifact(env, remote_path_artifact(), "s1", "remote session command")

    listed = run_sesshmux(["list", "test-host"], env, timeout=30.0)
    if listed.returncode != 0:
        raise AssertionError(listed)
    if not has_list_header(listed.stdout) or not list_has_session(listed.stdout, "s1"):
        raise AssertionError(listed)

    killed = run_sesshmux(["kill", "test-host", "s1"], env, timeout=30.0)
    if killed.returncode != 0:
        raise AssertionError(killed)
    if not killed.stdout.startswith("ENDED "):
        raise AssertionError(killed)

    listed = run_sesshmux(["list", "test-host"], env, timeout=30.0)
    if listed.returncode != 0:
        raise AssertionError(listed)
    if "s1" in listed.stdout:
        raise AssertionError(listed)

    stopped = run_sesshmux(["kill", "--all", "test-host"], env, timeout=30.0)
    if stopped.returncode != 0:
        raise AssertionError(stopped)
    if "KILLING_ALL" not in stopped.stdout:
        raise AssertionError(stopped)


def test_ssh_remote_kill_all_option_does_not_start_agent(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    stopped = run_sesshmux(["kill", "--all", "test-host"], env, timeout=30.0)

    if stopped.returncode != 0:
        raise AssertionError(stopped)
    if "KILLING_ALL" not in stopped.stdout:
        raise AssertionError(stopped)
    registry = sessions_dir(env)
    if registry.exists() and any(registry.iterdir()):
        raise AssertionError("remote kill --all started a session agent")


def test_ssh_version_mismatch_uses_compat_path(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    marker = "SSH_VERSION_FALLBACK_READY"
    write_fake_ssh(fake_bin / "ssh")
    write_compat_marker(session_compat_path(env, "s1"), marker)
    server, thread, observed = start_version_mismatch_agent(env, "s1")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    configure_ctrl_b_leader(env)

    try:
        result = run_sesshmux(["attach", "--host", "test-host", "s1"], env, timeout=30.0)
    finally:
        server.close()
        thread.join(timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if thread.is_alive():
        raise AssertionError("version mismatch agent did not receive a connection")
    if observed.get("error"):
        raise AssertionError(observed)
    if marker not in result.stdout:
        raise AssertionError(result)
    if "sessh: existing remote sessh is incompatible; falling back to compat-mode" not in result.stderr:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if log_text.splitlines().count("invoked=1") != 2:
        raise AssertionError(log_text)
    if "batch_mode=1" not in log_text:
        raise AssertionError(log_text)
    if "compat_invoked=1" not in log_text:
        raise AssertionError(log_text)
    expected_args = (
        "compat_args=. attach s1 --leader CTRL-B --scrollback-limit 2000 --initial-scrollback -1 --log-level warn"
    )
    if expected_args not in log_text:
        raise AssertionError(log_text)
    if f"compat_env_guid={guid_for_alias('s1')}" not in log_text:
        raise AssertionError(log_text)
    if f"compat_env_client_version={sessh_version()}" not in log_text:
        raise AssertionError(log_text)
    if "compat_env_compat=1" not in log_text:
        raise AssertionError(log_text)


def test_sesshmux_force_compat_invokes_session_compat_path(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    marker = "SESSHMUX_FORCE_COMPAT_READY"
    write_fake_ssh(fake_bin / "ssh")
    write_compat_marker(session_compat_path(env, "s1"), marker)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sesshmux(
        ["force-compat", "--ssh-options", "-F cfg", "--host", "test-host", "s1", "attach", "--leader", "CTRL-B"],
        env,
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if log_text.splitlines().count("invoked=1") != 1:
        raise AssertionError(log_text)
    if "config=cfg" not in log_text:
        raise AssertionError(log_text)
    if "batch_mode=1" in log_text:
        raise AssertionError(log_text)
    if "compat_args=. attach s1 --leader CTRL-B" not in log_text:
        raise AssertionError(log_text)
    if f"compat_env_guid={guid_for_alias('s1')}" not in log_text:
        raise AssertionError(log_text)
    if f"compat_env_client_version={sessh_version()}" not in log_text:
        raise AssertionError(log_text)
    if "compat_env_compat=1" not in log_text:
        raise AssertionError(log_text)


def test_sesshmux_force_compat_uses_cached_route(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    marker = "SESSHMUX_FORCE_COMPAT_ROUTE_READY"
    route_alias = "route-force-compat"
    route_guid = guid_for_alias(route_alias)
    write_fake_ssh(fake_bin / "ssh")
    write_ssh_route(env, route_alias, route_guid, "test-host", ssh_options=("-F", "cached-cfg"))
    write_compat_marker(session_compat_path(env, route_alias), marker)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sesshmux(["force-compat", route_alias, "attach"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if log_text.splitlines().count("invoked=1") != 1:
        raise AssertionError(log_text)
    if "config=cached-cfg" not in log_text:
        raise AssertionError(log_text)
    if f"compat_args=. attach {route_guid}" not in log_text:
        raise AssertionError(log_text)
    if f"compat_env_guid={route_guid}" not in log_text:
        raise AssertionError(log_text)
    if f"compat_env_client_version={sessh_version()}" not in log_text:
        raise AssertionError(log_text)
    if "compat_env_compat=1" not in log_text:
        raise AssertionError(log_text)


def test_sesshmux_force_compat_ctrl_c_reaches_remote_pty(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_FORCE_COMPAT_SIGNAL_READY"
    remote_shell.write_text(
        "#!/bin/sh\n"
        "trap 'printf \"\\nREMOTE_SIGINT\\nREMOTE_PROMPT$ \"' INT\n"
        f"printf '{marker}\\nREMOTE_PROMPT$ '\n"
        "while :; do\n"
        "  if IFS= read -r line; then\n"
        "    printf 'REMOTE:%s\\nREMOTE_PROMPT$ ' \"$line\"\n"
        "  fi\n"
        "done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_SIMULATE_NO_PTY"] = "1"
    env["SHELL"] = str(remote_shell)
    configure_ctrl_b_leader(env)

    first = run_sessh_until_stdout(["--alias", "s1", "test-host"], env, marker, timeout=30.0)
    if first.returncode != 0:
        raise AssertionError(first)
    assert_session_compat_points_to_cached_artifact(env, remote_path_artifact(), "s1", "force compat signal")

    result = run_sesshmux_in_pty(
        ["force-compat", "--host", "test-host", "s1", "attach"],
        env,
        (
            (b"REMOTE_PROMPT$", b"\x03"),
            (b"REMOTE_SIGINT", b"after-ctrl-c\n"),
            (b"REMOTE:after-ctrl-c", b"\x02d"),
            (b"sessh: detached", None),
        ),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "REMOTE_SIGINT" not in result.stdout or "REMOTE:after-ctrl-c" not in result.stdout:
        raise AssertionError(result)


def run_test(name, fn):
    with tempfile.TemporaryDirectory(prefix="sessh-ssh-", dir="/tmp") as tmp:
        root = Path(tmp)
        env = isolated_env(root)
        try:
            fn(root)
        finally:
            cleanup_runtime(env)
    print(f"ok {name}")


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]

    tests = (
        ("fake ssh exports host to remote command", test_fake_ssh_exports_host_to_remote_command),
        (
            "ssh transport uploads artifact and reaches broker",
            test_ssh_transport_uploads_artifact_and_reaches_broker,
        ),
        (
            "ssh clean remote exit tombstones local route",
            test_ssh_clean_remote_exit_tombstones_local_route,
        ),
        (
            "ssh pre-attach stderr forwards immediately",
            test_ssh_pre_attach_stderr_forwards_immediately,
        ),
        (
            "ssh transport pins ipqos to interactive config value",
            test_ssh_transport_pins_ipqos_to_interactive_config_value,
        ),
        (
            "ssh transport respects explicit user ipqos",
            test_ssh_transport_respects_explicit_user_ipqos,
        ),
        (
            "ssh transport pins explicit two-value ipqos to interactive value",
            test_ssh_transport_pins_explicit_two_value_ipqos_to_interactive_value,
        ),
        (
            "ssh transport preserves config when ipqos query fails",
            test_ssh_transport_preserves_config_when_ipqos_query_fails,
        ),
        (
            "ssh session uses remote shell, not local client shell",
            test_ssh_session_uses_remote_shell_not_local_client_shell,
        ),
        (
            "ssh verbose flags are passed to ssh",
            test_ssh_verbose_flags_are_passed_to_ssh,
        ),
        (
            "ssh failure uses ssh exit status and visible args",
            test_ssh_failure_uses_ssh_exit_status_and_visible_args,
        ),
        (
            "ssh unsupported option falls back to plain ssh",
            test_ssh_unsupported_option_falls_back_to_plain_ssh,
        ),
        (
            "ssh x11 uses proxy stream",
            test_ssh_x11_uses_proxy_stream,
        ),
        (
            "ssh forwarding uses proxy stream",
            test_ssh_forwarding_uses_proxy_stream,
        ),
        (
            "ssh force proxy mode uses proxy stream",
            test_ssh_force_proxy_mode_uses_proxy_stream,
        ),
        (
            "ssh force proxy mode config uses proxy stream",
            test_ssh_force_proxy_mode_config_uses_proxy_stream,
        ),
        (
            "ssh no force proxy mode overrides config",
            test_ssh_no_force_proxy_mode_overrides_config,
        ),
        (
            "ssh remote command uses direct stream",
            test_ssh_remote_command_uses_direct_stream,
        ),
        (
            "ssh remote command stream preserves exit status",
            test_ssh_remote_command_stream_preserves_exit_status,
        ),
        (
            "ssh remote command stream waits for exit status after output eof",
            test_ssh_remote_command_stream_waits_for_exit_status_after_output_eof,
        ),
        (
            "ssh remote command stream preserves stderr channel",
            test_ssh_remote_command_stream_preserves_stderr_channel,
        ),
        (
            "ssh tty stdin remote command does not allocate tty without -t",
            test_ssh_tty_stdin_remote_command_does_not_allocate_tty_without_t,
        ),
        (
            "ssh terminal-emulator tty preserves exit status",
            test_ssh_terminal_emulator_tty_preserves_exit_status,
        ),
        (
            "ssh terminal-emulator tty propagates resize",
            test_ssh_terminal_emulator_tty_propagates_resize,
        ),
        (
            "ssh no-terminal-emulator remote command uses direct stream",
            test_ssh_no_terminal_emulator_remote_command_uses_direct_stream,
        ),
        (
            "ssh no-terminal-emulator remote command preserves exit status",
            test_ssh_no_terminal_emulator_remote_command_preserves_exit_status,
        ),
        (
            "ssh no-terminal-emulator tty preserves exit status",
            test_ssh_no_terminal_emulator_tty_preserves_exit_status,
        ),
        (
            "ssh no-terminal-emulator tty propagates resize",
            test_ssh_no_terminal_emulator_tty_propagates_resize,
        ),
        (
            "ssh no-terminal-emulator forced tty marks stream as tty",
            test_ssh_no_terminal_emulator_forced_tty_marks_stream_as_tty,
        ),
        (
            "ssh no-terminal-emulator requested tty uses stream path",
            test_ssh_no_terminal_emulator_requested_tty_uses_stream_path,
        ),
        (
            "ssh interleaved tty and no-terminal-emulator preserves exit status",
            test_ssh_interleaved_tty_and_no_terminal_emulator_preserves_exit_status,
        ),
        (
            "ssh terminal-emulator false config uses stream path",
            test_ssh_terminal_emulator_false_config_uses_stream_path,
        ),
        (
            "ssh terminal-emulator cli overrides disabled config",
            test_ssh_terminal_emulator_cli_overrides_disabled_config,
        ),
        (
            "ssh no-terminal-emulator tty uses single stream guid",
            test_ssh_no_terminal_emulator_tty_uses_single_stream_guid,
        ),
        (
            "ssh no-terminal-emulator command in tty uses single stream guid",
            test_ssh_no_terminal_emulator_command_in_tty_uses_single_stream_guid,
        ),
        (
            "ssh remote command stream reconnects after transport loss",
            test_ssh_remote_command_stream_reconnects_after_transport_loss,
        ),
        (
            "ssh no-terminal-emulator tty reconnect title restores app title",
            test_ssh_no_terminal_emulator_tty_reconnect_title_restores_app_title,
        ),
        (
            "ssh no-terminal-emulator tty escape disconnects",
            test_ssh_no_terminal_emulator_tty_escape_disconnects,
        ),
        (
            "ssh no-terminal-emulator tty escape help",
            test_ssh_no_terminal_emulator_tty_escape_help,
        ),
        (
            "ssh no-terminal-emulator tty escape doubled tilde",
            test_ssh_no_terminal_emulator_tty_escape_doubled_tilde,
        ),
        (
            "ssh terminal-emulator tty escape doubled tilde",
            test_ssh_terminal_emulator_tty_escape_doubled_tilde,
        ),
        (
            "ssh terminal-emulator tty escape help modal repaints",
            test_ssh_terminal_emulator_tty_escape_help_modal_repaints,
        ),
        (
            "ssh tty uses emulated TERM not outer TERM",
            test_ssh_tty_uses_emulated_term_not_outer_term,
        ),
        (
            "ssh no-terminal-emulator tty copies outer TERM",
            test_ssh_no_terminal_emulator_tty_copies_outer_term,
        ),
        (
            "ssh no-terminal-emulator tty copies local tty modes",
            test_ssh_no_terminal_emulator_tty_copies_local_tty_modes,
        ),
        (
            "ssh no-terminal-emulator tty copies local output modes",
            test_ssh_no_terminal_emulator_tty_copies_local_output_modes,
        ),
        (
            "ssh no-terminal-emulator tty sets SSH_TTY",
            test_ssh_no_terminal_emulator_tty_sets_ssh_tty,
        ),
        (
            "ssh no-terminal-emulator interactive shell keeps prompt aligned",
            test_ssh_no_terminal_emulator_interactive_shell_keeps_prompt_aligned,
        ),
        (
            "ssh no-terminal-emulator release artifact restores local tty on exit",
            test_ssh_no_terminal_emulator_release_artifact_restores_local_tty_on_exit,
        ),
        (
            "ssh terminal-emulator release artifact restores local tty on exit",
            test_ssh_terminal_emulator_release_artifact_restores_local_tty_on_exit,
        ),
        (
            "ssh forced tty remote command allocates pty with stdin null",
            test_ssh_forced_tty_remote_command_allocates_pty_with_stdin_null,
        ),
        (
            "ssh requested tty remote command allocates pty with tty stdin",
            test_ssh_requested_tty_remote_command_allocates_pty_with_tty_stdin,
        ),
        (
            "ssh single tty remote command with stdin null uses direct stream",
            test_ssh_single_tty_remote_command_with_stdin_null_uses_direct_stream,
        ),
        (
            "ssh tty empty remote command starts interactive session",
            test_ssh_tty_empty_remote_command_starts_interactive_session,
        ),
        (
            "ssh tty quoted empty remote command uses shell eval",
            test_ssh_tty_quoted_empty_remote_command_uses_shell_eval,
        ),
        (
            "sesshmux unknown command does not fallback to plain ssh",
            test_sesshmux_unknown_command_does_not_fallback_to_plain_ssh,
        ),
        (
            "internal sessh rejects dot host",
            test_internal_sessh_rejects_dot_host,
        ),
        (
            "internal sessh host list is remote command",
            test_internal_sessh_host_list_is_remote_command,
        ),
        (
            "ssh unsupported option does not fallback for sessh action",
            test_ssh_unsupported_option_does_not_fallback_for_sessh_action,
        ),
        (
            "ssh config-only cli options are rejected",
            test_ssh_config_only_cli_options_are_rejected,
        ),
        (
            "ssh bootstrap false config uses remote path sesshmux",
            test_ssh_bootstrap_false_config_uses_remote_path_sesshmux,
        ),
        (
            "ssh attach without id reattaches latest session",
            test_ssh_attach_without_id_reattaches_latest_session,
        ),
        (
            "mux new detached creates local session without attach",
            test_mux_new_detached_creates_local_session_without_attach,
        ),
        (
            "mux new detached creates remote route without attach",
            test_mux_new_detached_creates_remote_route_without_attach,
        ),
        (
            "ssh no-host attach uses local route",
            test_ssh_no_host_attach_uses_local_route,
        ),
        (
            "ssh no-host attach uses latest detached route",
            test_ssh_no_host_attach_uses_latest_detached_route,
        ),
        (
            "ssh no-host attach skips route attached by this machine",
            test_ssh_no_host_attach_skips_route_attached_by_this_machine,
        ),
        (
            "ssh no-host list --client uses remote route",
            test_ssh_no_host_list_client_uses_remote_route,
        ),
        (
            "ssh no-host detach client uses client route hint",
            test_ssh_no_host_detach_client_uses_client_route_hint,
        ),
        (
            "ssh list refresh tombstones missing remote route",
            test_ssh_list_refresh_tombstones_missing_remote_route,
        ),
        (
            "ssh remote default alias is remote generated",
            test_ssh_remote_default_alias_is_remote_generated,
        ),
        (
            "ssh host attach does not follow remote route",
            test_ssh_host_attach_does_not_follow_remote_route,
        ),
        (
            "ssh leader sever reconnects",
            test_ssh_leader_sever_reconnects,
        ),
        (
            "ssh debug sever reconnects twice",
            test_ssh_debug_sever_reconnects_twice,
        ),
        (
            "ssh unresponsive reconnect failure keeps input on old connection without bell",
            test_ssh_unresponsive_reconnect_failure_keeps_input_on_old_connection_without_bell,
        ),
        (
            "ssh unresponsive tty sets title without banner",
            test_ssh_unresponsive_tty_sets_title_without_banner,
        ),
        (
            "ssh unresponsive reconnect retries after prepare failure",
            test_ssh_unresponsive_reconnect_retries_after_prepare_failure,
        ),
        (
            "ssh unresponsive old connection recovers without switch or bell",
            test_ssh_unresponsive_old_connection_recovers_without_switch_or_bell,
        ),
        (
            "ssh unresponsive transport close uses disconnected ready banner",
            test_ssh_unresponsive_transport_close_uses_disconnected_ready_banner,
        ),
        (
            "ssh retry elapsed with input waits before switch",
            test_ssh_retry_elapsed_with_input_waits_before_switch,
        ),
        (
            "ssh retry elapsed without input switches automatically",
            test_ssh_retry_elapsed_without_input_switches_automatically,
        ),
        (
            "ssh no-echo input ack prevents false unresponsive",
            test_ssh_no_echo_input_ack_prevents_false_unresponsive,
        ),
        (
            "ssh reconnect displays live ssh stderr in banner",
            test_ssh_reconnect_displays_live_ssh_stderr_in_banner,
        ),
        (
            "ssh log level quiet suppresses buffered stderr display",
            test_ssh_log_level_quiet_suppresses_buffered_stderr_display,
        ),
        (
            "ssh session buffers and displays stderr after attach",
            test_ssh_session_buffers_and_displays_stderr_after_attach,
        ),
        (
            "ssh reconnect does not apply active screen cleanup",
            test_ssh_reconnect_does_not_apply_active_screen_cleanup,
        ),
        (
            "ssh reconnect can detach while bootstrapping",
            test_ssh_reconnect_can_detach_while_bootstrapping,
        ),
        (
            "ssh reconnect can detach with ctrl-c",
            test_ssh_reconnect_can_detach_with_ctrl_c,
        ),
        (
            "ssh leader detach exits while remote output is flowing",
            test_ssh_leader_detach_exits_while_remote_output_is_flowing,
        ),
        (
            "ssh unsupported remote platform uses plain-ssh-fallback",
            test_ssh_unsupported_remote_platform_falls_back_to_plain_ssh,
        ),
        (
            "ssh unsupported remote platform does not use plain-ssh-fallback for attach",
            test_ssh_unsupported_remote_platform_does_not_plain_ssh_fallback_for_attach,
        ),
        (
            "ssh remote session commands use broker",
            test_ssh_remote_session_commands_use_broker,
        ),
        (
            "ssh remote kill --all does not start agent",
            test_ssh_remote_kill_all_option_does_not_start_agent,
        ),
        (
            "ssh version mismatch uses compat path",
            test_ssh_version_mismatch_uses_compat_path,
        ),
        (
            "sesshmux force-compat invokes session compat path",
            test_sesshmux_force_compat_invokes_session_compat_path,
        ),
        (
            "sesshmux force-compat uses cached route",
            test_sesshmux_force_compat_uses_cached_route,
        ),
        (
            "sesshmux force-compat ctrl-c reaches remote pty",
            test_sesshmux_force_compat_ctrl_c_reaches_remote_pty,
        ),
    )

    selected_name = None
    if argv:
        if len(argv) != 2 or argv[0] != "--case":
            print("usage: tests/ssh_harness.py [--case NAME]", file=sys.stderr)
            return 64
        selected_name = argv[1]

    if selected_name is not None:
        tests = tuple((name, fn) for name, fn in tests if name == selected_name)
        if not tests:
            print(f"unknown ssh harness case: {selected_name}", file=sys.stderr)
            return 64

    for name, fn in tests:
        run_test(name, fn)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
