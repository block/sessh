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
import termios
import time
from pathlib import Path

from harness_cleanup import cleanup_runtime, sessions_dir
from socket_harness import (
    SESSION_CLIENT_CONTROL_RESPONSE,
    SESSION_CLIENT_DEBUG_SEVER_CONNECTION_REQUEST,
    SESSION_CLIENT_DEBUG_UNRESPONSIVE_CONNECTION_REQUEST,
    recv_until_message,
    send_frame,
    send_hello,
    sessh_pb,
)
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("SESSH_BIN", str(ROOT / "zig-out" / "bin" / "sessh")))
GUID_RE = re.compile(r"^s-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
COMPACT_GUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")


def sessh_argv(args):
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
port_option=
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

apply_remote_env() {
  if [ -z "${SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}.remote
  fi
  if [ -z "${SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME:-}" ] && [ -n "${XDG_STATE_HOME:-}" ]; then
    SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME=${XDG_STATE_HOME}.remote
  fi
  if [ -n "${SESSH_FAKE_SSH_REMOTE_PATH:-}" ]; then
    PATH=$SESSH_FAKE_SSH_REMOTE_PATH:$PATH
    export PATH
  fi
  if [ -n "${SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR:-}" ]; then
    mkdir -p "$SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR"
    chmod 700 "$SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR"
    XDG_RUNTIME_DIR=$SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR
    export XDG_RUNTIME_DIR
  fi
  if [ -n "${SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME:-}" ]; then
    mkdir -p "$SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME"
    chmod 700 "$SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME"
    XDG_STATE_HOME=$SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME
    export XDG_STATE_HOME
  fi
  if [ -n "${SESSH_FAKE_SSH_REMOTE_SHELL:-}" ]; then
    SHELL=$SESSH_FAKE_SSH_REMOTE_SHELL
    export SHELL
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
    [Pp][Oo][Rr][Tt]=*)
      port_option=${1#*=}
      ;;
    [Pp][Oo][Rr][Tt]\\ *)
      port_option=${1#* }
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
      port_option=$1
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
    -N|-n|-f)
      plain_option=$1
      shift
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
  config_hostname=${SESSH_FAKE_SSH_G_HOSTNAME:-$host}
  config_port=${SESSH_FAKE_SSH_G_PORT:-${port_option:-22}}
  if [ -n "$ipqos_option" ]; then
    printf 'hostname %s\\n' "$config_hostname"
    printf 'port %s\\n' "$config_port"
    case "$ipqos_option" in
      *\\ *) printf 'ipqos %s\\n' "$ipqos_option" ;;
      *) printf 'ipqos %s %s\\n' "$ipqos_option" "$ipqos_option" ;;
    esac
  else
    printf 'hostname %s\\n' "$config_hostname"
    printf 'port %s\\n' "$config_port"
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
  export SESSH_TEST_HOST=$host
  apply_remote_env
  if [ "$#" -gt 0 ]; then
    if [ "$*" = "tty" ]; then
      if [ "$request_tty" -eq 1 ] && { [ "$plain_option" = "-tt" ] || { [ "$plain_option" = "-t" ] && [ -t 0 ]; }; }; then
        printf '/dev/pts/5\\n'
        exit 0
      else
        printf 'not a tty\\n'
        exit 1
      fi
    fi
    exec "${SHELL:-sh}" -c "$*"
  fi
  if [ -n "${SESSH_FAKE_SSH_REMOTE_SHELL:-}" ]; then
    exec "${SHELL:-sh}"
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
apply_remote_env
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


def run_sessh_with_tty_stdin_and_piped_stdout(args, env, timeout=10.0):
    master, slave = pty.openpty()
    try:
        proc = subprocess.Popen(
            sessh_argv(args),
            cwd=ROOT,
            env=env,
            stdin=slave,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    finally:
        os.close(slave)
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    finally:
        os.close(master)
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)
    return subprocess.CompletedProcess(sessh_argv(args), proc.returncode, stdout, stderr)


def write_sessh_config(env, text):
    config_dir = Path(env["XDG_CONFIG_HOME"]) / "sessh"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "sessh.env").write_text(text)


def optional_text(path):
    return path.read_text() if path.exists() else "<missing>"


def ssh_invocation_count(path):
    return optional_text(path).splitlines().count("invoked=1")


def process_diagnostics(result):
    return (
        f"returncode={result.returncode}\n"
        f"args={result.args!r}\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )


def sever_session_clients(env, timeout=30.0):
    request = sessh_pb().TeSessionClientDebugSeverConnectionRequest()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(str(daemon_socket_path(fake_remote_runtime_root(env))))
        send_hello(conn)
        send_frame(conn, SESSION_CLIENT_DEBUG_SEVER_CONNECTION_REQUEST, request.SerializeToString())
        recv_until_message(conn, SESSION_CLIENT_CONTROL_RESPONSE, timeout=timeout)


def make_session_clients_unresponsive(env, seconds, timeout=30.0):
    request = sessh_pb().TeSessionClientDebugUnresponsiveConnectionRequest(seconds=seconds)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(str(daemon_socket_path(fake_remote_runtime_root(env))))
        send_hello(conn)
        send_frame(conn, SESSION_CLIENT_DEBUG_UNRESPONSIVE_CONNECTION_REQUEST, request.SerializeToString())
        recv_until_message(conn, SESSION_CLIENT_CONTROL_RESPONSE, timeout=timeout)


def ssh_failure_diagnostics(message, result, fake_log, fake_trace):
    return (
        f"{message}\n"
        f"\nfake ssh log:\n{optional_text(fake_log)}"
        f"\nfake ssh trace:\n{optional_text(fake_trace)}"
        f"\nsessh result:\n{process_diagnostics(result)}"
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


def read_until_any_pipe(pipe, needles, timeout=10.0):
    deadline = time.monotonic() + timeout
    data = b""
    while not any(needle in data for needle in needles):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError(f"timed out waiting for any of {needles!r}; got {data!r}")
        ready, _, _ = select.select([pipe], [], [], remaining)
        if not ready:
            raise AssertionError(f"timed out waiting for any of {needles!r}; got {data!r}")
        chunk = os.read(pipe.fileno(), 4096)
        if not chunk:
            raise AssertionError(f"process exited before any of {needles!r}; got {data!r}")
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


def terminate_process(proc):
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=2.0)


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


def run_sessh_in_pty(
    args,
    env,
    steps,
    timeout=10.0,
    child_tty_setup=None,
    binary=None,
    capture_tty_attrs=False,
):
    argv = [str(binary or BIN), *args]
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
    # This runs in the child side of pty.fork before sessh starts. In
    # no-terminal-emulator mode, the visible ssh process owns the PTY and should
    # propagate these local modes.
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
    sever_session_clients(env, timeout)
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
        stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Reconnecting...", timeout)
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
        sever_session_clients(env, timeout)
        stdout = read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", timeout)
        proc.stdin.write(b"~.")
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


def run_sessh_close_reconnect_probe(args, env, ready, close_bytes=b"~.", timeout=10.0):
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
    sever_session_clients(env, timeout)
    stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", timeout)
    proc.stdin.write(close_bytes)
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


def run_sessh_close_probe(args, env, ready, timeout=10.0):
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
    proc.stdin.write(b"~.")
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
    return ROOT / "zig-out" / "libexec" / "sessh" / f"{os_name}-{arch}" / "sessh"


def remote_path_artifact():
    if BIN.name == "sessh-dev":
        return BIN if BIN.is_absolute() else ROOT / BIN
    path = BIN if BIN.is_absolute() else ROOT / BIN
    os_name, arch = canonical_local_platform()
    wrapper_artifact = path.parent / ".." / "libexec" / "sessh" / f"{os_name}-{arch}" / "sessh"
    if wrapper_artifact.exists():
        return wrapper_artifact
    return local_artifact()


def command_executable(command):
    try:
        parts = shlex.split(command)
    except ValueError:
        parts = command.split()
    if not parts:
        return None
    exe = Path(parts[0])
    if not exe.is_absolute():
        exe = ROOT / exe
    return exe.resolve(strict=False)


def local_daemon_executable(env):
    return daemon_socket_path(Path(env["XDG_RUNTIME_DIR"])).parent / "sesshd"


def local_daemon_pids(env):
    target = local_daemon_executable(env)
    result = subprocess.run(
        ["ps", "-axo", "pid=,command="],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result)
    pids = []
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        if command_executable(command) == target:
            pids.append(pid)
    return pids


def wait_local_daemon_pids(env, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        pids = local_daemon_pids(env)
        if pids:
            return pids
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for local daemon process {local_daemon_executable(env)}")


def artifact_cache_path(env, artifact):
    return Path(env["XDG_CACHE_HOME"]) / "sessh" / "bin" / sessh_version() / sha256(artifact) / "sessh"


def seed_remote_artifact_cache(env, artifact=None):
    if artifact is None:
        artifact = remote_path_artifact()
    cached = artifact_cache_path(env, artifact)
    cached.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(artifact, cached)
    cached.chmod(0o700)
    return cached


def sessh_version():
    for line in (ROOT / "src" / "core" / "config.zig").read_text().splitlines():
        if line.startswith("pub const version = "):
            return line.split('"')[1]
    raise AssertionError("could not find sessh version")


def sessh_protocol_major():
    for line in (ROOT / "src" / "core" / "config.zig").read_text().splitlines():
        match = re.match(r"pub const protocol_major = ([0-9]+);", line)
        if match:
            return int(match.group(1))
    raise AssertionError("could not find sessh protocol_major")


def daemon_socket_dir_name():
    version = sessh_version()
    base = str(sessh_protocol_major())
    if not version.endswith("-dev"):
        return base
    return f"{base}.dev.{hashlib.sha256(remote_path_artifact().read_bytes()).hexdigest()[:8]}"


def daemon_socket_path(runtime_root):
    return runtime_root / daemon_socket_dir_name() / "sesshd.sock"


def state_root(env):
    return Path(env["XDG_STATE_HOME"]) / "sessh"


def state_sessions_dir(env):
    return state_root(env) / "guid"


def fake_remote_runtime_root(env):
    return Path(env.get("SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR", env["XDG_RUNTIME_DIR"] + ".remote"))


def fake_remote_state_root(env):
    return Path(env.get("SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME", env["XDG_STATE_HOME"] + ".remote")) / "sessh"


def fake_remote_state_sessions_dir(env):
    return fake_remote_state_root(env) / "guid"


def runtime_root(env):
    return Path(env["XDG_RUNTIME_DIR"])


def fake_remote_sessions_dir(env):
    return fake_remote_runtime_root(env) / "guid"


def sessions_dir(env):
    return fake_remote_sessions_dir(env)


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


def test_session_guid(index):
    return f"s-{index:08x}-0000-4000-8000-{index:012x}"


def session_path(env, session_id=None):
    if session_id is None:
        session_id = test_session_guid(1)
    return sessions_dir(env) / canonical_guid(session_id)


def route_file(env, session_id=None):
    if session_id is None:
        session_id = test_session_guid(1)
    return fake_remote_state_sessions_dir(env) / canonical_guid(session_id) / "route.json"


def session_compat_path(env, session_id=None):
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
        "printf 'SESSH_BIN=%s\\n' \"$(command -v sessh || true)\"\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SHELL"] = str(remote_shell)

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        if b"daemon started socket=" in daemon_log_output:
            raise AssertionError(f"daemon log replayed old entries: {daemon_log_output!r}")

        result = run_sessh_in_pty(
            ["-F", str(fake_config), "test-host"],
            env,
            ((marker.encode("utf-8"), None),),
            timeout=30.0,
        )
        daemon_log_output += read_until_any_pipe(
            log_proc.stdout,
            (
                b"ssh transport disconnected from daemon host=test-host",
                b"terminal client disconnected; requesting remote hangup host=test-host",
            ),
            timeout=5.0,
        )
    finally:
        terminate_process(log_proc)

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
    combined_output = result.stdout + result.stderr
    status_start = combined_output.find("sessh: bootstrapping...")
    status_clear = combined_output.find("\x1b[K", status_start + 1)
    if status_start < 0 or status_clear < 0 or status_clear < status_start:
        raise AssertionError(
            ssh_failure_diagnostics("bootstrap status was not displayed and cleared", result, fake_log, fake_trace)
        )
    if "ssh ts_ms=" in combined_output:
        raise AssertionError(ssh_failure_diagnostics("bootstrap status was captured as ssh stderr", result, fake_log, fake_trace))

    artifact = remote_path_artifact()
    installed = artifact_cache_path(env, artifact)
    if installed.read_bytes() != artifact.read_bytes():
        raise AssertionError("uploaded artifact was not installed")
    if not os.access(installed, os.X_OK):
        raise AssertionError("uploaded artifact is not executable")
    if f"SESSH_PATH={installed.parent.resolve()}" not in result.stdout:
        raise AssertionError(result)
    if f"SESSH_BIN={installed.resolve()}" not in result.stdout:
        raise AssertionError(result)
    routes = list(state_sessions_dir(env).glob("*/route.json"))
    if routes:
        raise AssertionError(f"completed uploaded session left route files: {routes}")

    daemon_log_stdout = daemon_log_output.decode("utf-8", "replace")
    for expected in (
        "terminal transport opening host=test-host",
        "ssh transport starting host=test-host bootstrap=true",
        "bootstrap upload required host=test-host",
        "bootstrap completed host=test-host uploaded=true",
        "terminal transport ready host=test-host",
    ):
        if expected not in daemon_log_stdout:
            raise AssertionError(
                ssh_failure_diagnostics(f"daemon log missing {expected!r}", result, fake_log, fake_trace)
            )
    if (
        "ssh transport disconnected from daemon host=test-host" not in daemon_log_stdout
        and "terminal client disconnected; requesting remote hangup host=test-host" not in daemon_log_stdout
    ):
        raise AssertionError(
            ssh_failure_diagnostics("daemon log missing terminal transport cleanup", result, fake_log, fake_trace)
        )


def test_ssh_daemon_log_records_client_hangup_cleanup(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_HANGUP_CLEANUP_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SHELL"] = str(remote_shell)

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    proc = None
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        argv = sessh_argv(["test-host"])
        proc = subprocess.Popen(
            argv,
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout = read_until_pipe(proc.stdout, marker.encode("utf-8"), timeout=30.0)
        proc.stdin.close()
        returncode = proc.wait(timeout=30.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
        result = subprocess.CompletedProcess(
            argv,
            returncode,
            stdout.decode("utf-8", "replace"),
            stderr.decode("utf-8", "replace"),
        )
        daemon_log_output += read_until_pipe(log_proc.stdout, b"remote terminal hangup requested host=test-host", timeout=5.0)
    finally:
        if proc is not None and proc.poll() is None:
            terminate_process(proc)
        terminate_process(log_proc)

    if result.returncode != 0:
        raise AssertionError(ssh_failure_diagnostics("sessh returned non-zero", result, fake_log, fake_trace))
    daemon_log_stdout = daemon_log_output.decode("utf-8", "replace")
    for expected in (
        "terminal client disconnected; requesting remote hangup host=test-host",
        "remote terminal hangup requested host=test-host",
    ):
        if expected not in daemon_log_stdout:
            raise AssertionError(
                ssh_failure_diagnostics(f"daemon log missing {expected!r}", result, fake_log, fake_trace)
            )


def test_ssh_local_daemon_death_exits_with_error(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_DAEMON_DEATH_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
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
    stdout = b""
    stderr = b""
    returncode = None
    daemon_pids = []
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        daemon_pids = wait_local_daemon_pids(env, timeout=5.0)
        for pid in daemon_pids:
            os.kill(pid, signal.SIGTERM)
        returncode = proc.wait(timeout=10.0)
        stdout += proc.stdout.read()
        stderr = proc.stderr.read()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5.0)
        for pid in daemon_pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 255:
        raise AssertionError(result)
    if "sessh: daemon connection lost" not in result.stderr:
        raise AssertionError(result)
    if "Retry connecting" in result.stdout or "Reconnecting" in result.stdout:
        raise AssertionError(result)
    if "Retry connecting" in result.stderr or "Reconnecting" in result.stderr:
        raise AssertionError(result)


def test_ssh_local_daemon_death_tty_error_starts_on_new_line(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_DAEMON_DEATH_TTY_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["test-host"])
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    output = b""
    waited = False
    daemon_pids = []
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, output, marker.encode("utf-8"), timeout=30.0)
        daemon_pids = wait_local_daemon_pids(env, timeout=5.0)
        for daemon_pid in daemon_pids:
            os.kill(daemon_pid, signal.SIGTERM)

        deadline = time.monotonic() + 10.0
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                returncode = wait_status_to_returncode(status)
                output += read_available_pty(fd)
                break
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for client close; got {output!r}")
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
        for daemon_pid in daemon_pids:
            try:
                os.kill(daemon_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.close(fd)

    if returncode != 255:
        raise AssertionError(output.decode("utf-8", "replace"))
    if b"\r\nsessh: daemon connection lost\r\n" not in output:
        raise AssertionError(output)
    if b"Retry connecting" in output or b"Reconnecting" in output:
        raise AssertionError(output)


def test_ssh_transport_cache_hit_suppresses_bootstrap_status(tmp):
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
        "printf 'SESSH_BIN=%s\\n' \"$(command -v sessh || true)\"\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SHELL"] = str(remote_shell)

    installed = seed_remote_artifact_cache(env)
    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        if b"daemon started socket=" in daemon_log_output:
            raise AssertionError(f"daemon log replayed old entries: {daemon_log_output!r}")

        result = run_sessh(["-F", str(fake_config), "test-host"], env, timeout=30.0)
        daemon_log_output += read_until_pipe(
            log_proc.stdout,
            b"bootstrap skipped host=test-host reason=remote_artifact_present",
            timeout=5.0,
        )
    finally:
        terminate_process(log_proc)

    if result.returncode != 0:
        raise AssertionError(ssh_failure_diagnostics("sessh returned non-zero on cache hit", result, fake_log, fake_trace))
    if marker not in result.stdout:
        raise AssertionError(
            ssh_failure_diagnostics("ssh cache-hit attach did not render remote output", result, fake_log, fake_trace)
        )
    if "sessh: bootstrapping..." in result.stderr:
        raise AssertionError(ssh_failure_diagnostics("cache-hit bootstrap displayed upload status", result, fake_log, fake_trace))
    if any(token in result.stdout or token in result.stderr for token in ("MISSING ", "UPLOAD ", "OK\n")):
        raise AssertionError(
            ssh_failure_diagnostics("cache-hit bootstrap protocol leaked to client output", result, fake_log, fake_trace)
        )
    if f"SESSH_PATH={installed.parent.resolve()}" not in result.stdout:
        raise AssertionError(result)
    if f"SESSH_BIN={installed.resolve()}" not in result.stdout:
        raise AssertionError(result)

    expected = "bootstrap skipped host=test-host reason=remote_artifact_present"
    if expected not in daemon_log_output.decode("utf-8", "replace"):
        raise AssertionError(ssh_failure_diagnostics(f"daemon log missing {expected!r}", result, fake_log, fake_trace))


def test_ssh_clean_remote_exit_removes_routes(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_runtime = tmp / "remote-runtime"
    remote_state = tmp / "remote-state"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_REMOTE_EXIT_READY"
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

    result = run_sessh(["test-host"], env, timeout=30.0)

    if result.returncode != 7:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)

    local_routes = list(state_sessions_dir(env).glob("*/route.json"))
    if local_routes:
        raise AssertionError(f"clean remote exit left local route files: {local_routes}")
    remote_routes = list((remote_state / "sessh" / "guid").glob("*/route.json"))
    if remote_routes:
        raise AssertionError(f"clean remote exit left remote route files: {remote_routes}")


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

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        result = run_sessh(["-vvv", "test-host"], env, timeout=5.0)
        daemon_log_output += read_until_pipe(log_proc.stdout, b"terminal transport failed host=test-host", timeout=5.0)
    finally:
        terminate_process(log_proc)

    if result.returncode != 255:
        raise AssertionError(result)
    if "fake ssh failed before remote command" not in result.stderr:
        raise AssertionError(result)
    if "sessh: `ssh -vvv test-host` failed (exitcode=255)" not in result.stderr:
        raise AssertionError(result)
    if "EndOfStream" in result.stderr or "ssh bootstrap failed before response" in result.stderr:
        raise AssertionError(result.stderr)
    daemon_log_stdout = daemon_log_output.decode("utf-8", "replace")
    for expected in (
        "bootstrap failed before response host=test-host error=EndOfStream",
        "terminal transport failed host=test-host error=SshBootstrapFailed",
    ):
        if expected not in daemon_log_stdout:
            raise AssertionError(f"daemon log missing {expected!r}: {daemon_log_stdout!r}")


def test_ssh_stdin_null_option_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["-n", "test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "hello\n":
        raise AssertionError(result)
    if "fallback to plain ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)
    if "proxy_remote_command=echo hello" not in log_text:
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
    if result.stdout != "hello\n":
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "proxy_x11_option=-X" not in log_text:
        raise AssertionError(log_text)
    if "sessh-proxy" not in log_text:
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
    if "sessh-proxy" not in log_text:
        raise AssertionError(log_text)


def test_ssh_filter_level_raw_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["--filter-level", "raw", "test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_filter_level_config_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "filter-level=raw\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_filter_level_cli_overrides_config(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "filter-level=raw\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["--filter-level", "hygienic", "test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_remote_command_uses_proxy_stream(tmp):
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
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_internal_sessh_host_list_is_remote_command(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_bin = tmp / "remote-bin"
    remote_list = remote_bin / "list"
    write_fake_ssh(fake_bin / "ssh")
    remote_bin.mkdir()
    remote_list.write_text("#!/bin/sh\nprintf 'REMOTE_LIST\\n'\n")
    remote_list.chmod(remote_list.stat().st_mode | stat.S_IXUSR)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_PATH"] = str(remote_bin)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "list"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "REMOTE_LIST\n":
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_remote_command=list" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_remote_command_option_after_host_is_remote_arg(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_bin = tmp / "remote-bin"
    remote_rsync = remote_bin / "rsync"
    write_fake_ssh(fake_bin / "ssh")
    remote_bin.mkdir()
    remote_rsync.write_text(
        "#!/bin/sh\n"
        "if [ \"${1:-}\" = \"--version\" ]; then\n"
        "  printf 'REMOTE_RSYNC_VERSION\\n'\n"
        "else\n"
        "  printf 'REMOTE_RSYNC_ARGS:%s\\n' \"$*\"\n"
        "fi\n"
    )
    remote_rsync.chmod(remote_rsync.stat().st_mode | stat.S_IXUSR)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_PATH"] = str(remote_bin)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "rsync", "--version"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "REMOTE_RSYNC_VERSION\n":
        raise AssertionError(result)
    if "sessh " in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
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

    result = run_sessh_in_pty(
        ["test-host", "tty"],
        env,
        ((b"not a tty", None),),
        timeout=10.0,
    )

    if result.returncode != 1:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_tty_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["-t", "test-host", "exit 67"],
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
    result = run_sessh_in_pty(
        ["-t", "test-host", command],
        env,
        (
            (b"READY:24 100", resize_pty_then_send(31, 120, b"\n")),
            (b"RESIZED:31 120", None),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_remote_command_uses_proxy_stream(tmp):
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
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
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

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", "exit 13"],
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
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
        env,
        (
            (b"READY:24 100", resize_pty_then_send(32, 121, b"\n")),
            (b"RESIZED:32 121", None),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_forced_tty_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "/dev/" not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_requested_tty_uses_stream_path(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_interleaved_tty_and_no_terminal_emulator_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["-t", "--no-terminal-emulator", "test-host", "exit 3"],
        env,
        (),
        timeout=10.0,
    )

    if result.returncode != 3:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
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

    result = run_sessh_in_pty(
        ["-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
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

    result = run_sessh_in_pty(
        ["--terminal-emulator", "-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "plain_ssh=1" in log_text or "batch_mode=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_command_in_tty_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "test-host", "echo", "hello"],
        env,
        ((b"hello", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
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

    result = run_sessh_in_pty(
        ["-tt", "test-host", "printf '%s\\n' \"$TERM\""],
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

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", "printf '%s\\n' \"$TERM\""],
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
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
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
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
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
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
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

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "test-host"],
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

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "test-host"],
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

    result = run_sessh_in_pty(
        ["-t", "test-host", "printf 'TERMINAL_EMULATOR_READY\\n'; exit 0"],
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


def test_ssh_requested_tty_with_piped_stdout_does_not_emit_local_cleanup(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = "/bin/sh"

    result = run_sessh_with_tty_stdin_and_piped_stdout(
        ["-t", "test-host", "printf 'remote-sessh\\n'"],
        env,
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "remote-sessh" not in result.stdout:
        raise AssertionError(result)
    for leaked in ("\x1b]2;", str(ROOT)):
        if leaked in result.stdout:
            raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)
    if "--filter-level" not in log_text or "raw" not in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_tty_uses_proxy_with_hygienic_diagnostics(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = "printf 'NO_TERMINAL_EMULATOR_READY\\r\\n'; exit 255"
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
        env,
        (
            (b"NO_TERMINAL_EMULATOR_READY", None),
        ),
        timeout=30.0,
    )

    if result.returncode != 255:
        raise AssertionError(result)
    combined = result.stdout + result.stderr
    if "sessh: disconnected:" in combined:
        raise AssertionError(result)
    if "CTRL-C" in combined:
        raise AssertionError(result)
    if "CTRL-R" in combined:
        raise AssertionError(result)
    if title_sequence("10sec retry CTRL-R") in combined:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)
    if "--filter-level" not in log_text or "hygienic" not in log_text:
        raise AssertionError(log_text)
    if "--client-socket" not in log_text or "/c/" not in log_text:
        raise AssertionError(log_text)
    if "--client-ctrl-r" not in log_text or ("'1'" not in log_text and " 1" not in log_text):
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_tty_escape_doubled_tilde(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["-tt", "test-host", "printf 'TILDE_READY\\n'; IFS= read -r line; printf 'LINE:%s\\n' \"$line\""],
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
        str(BIN),
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
        output = read_pty_until(fd, output, b"~.  disconnect", 10.0)
        output = read_pty_until(fd, output, b"~p  repaint", 10.0)
        os.write(fd, b"ignored\n")
        output = read_pty_until_count(fd, output, b"HELP_READY", 2, 10.0)
        os.write(fd, b"after\n")
        output = read_pty_until(fd, output, b"REMOTE:after", 10.0)
        os.write(fd, b"~.")

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
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)
    trace_text = fake_trace.read_text()
    runtime_invocation = re.search(r"event=parsed .*config_query=0 .*request_tty=1", trace_text)
    if runtime_invocation is None:
        raise AssertionError(trace_text)


def test_ssh_requested_tty_remote_command_allocates_pty_with_tty_stdin(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh_in_pty(
        ["-t", "test-host", "tty"],
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

def test_ssh_single_requested_tty_remote_command_with_stdin_null_uses_proxy_stream(tmp):
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
    if "proxy_ssh=1" not in log_text:
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


def test_ssh_config_only_cli_options_are_rejected(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    for args in (
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


def test_ssh_bootstrap_false_config_uses_remote_path_sessh(tmp):
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
    (fake_bin / "sessh").write_text(
        "#!/bin/sh\n"
        "printf 'direct_broker=1\\n' >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "printf 'direct_broker_argc=%s\\n' \"$#\" >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "i=1\n"
        "for arg in \"$@\"; do\n"
        "  printf 'direct_broker_arg%s=%s\\n' \"$i\" \"$arg\" >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "  i=$((i + 1))\n"
        "done\n"
        f"exec {shlex.quote(str(BIN))} \"$@\"\n"
    )
    (fake_bin / "sessh").chmod(0o700)
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
    if "direct_broker_argc=1" not in log_text or "direct_broker_arg1=:internal-broker:" not in log_text:
        raise AssertionError(log_text)
    if "bootstrapper=1" in log_text:
        raise AssertionError(log_text)
    assert_cached_artifact(env, remote_path_artifact(), "bootstrap=false")


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
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        before_batch_count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0

        make_session_clients_unresponsive(env, 30, 30.0)

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

    argv = sessh_argv(["test-host"])
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

        make_session_clients_unresponsive(env, 30, 30.0)

        os.write(fd, b"trigger-unresponsive\r")
        wait_for_file_count(fake_log, "batch_mode=1", before_batch_count + 1, timeout=15.0)
        output = read_pty_until(fd, output, title_sequence("reconnecting CTRL-R").encode(), timeout=15.0)
        if b"sessh: unresponsive: Reconnecting" in output:
            raise AssertionError(output)
        if b"sessh: disconnected: Reconnecting" in output:
            raise AssertionError(output)

        os.write(fd, b"\r~.")
        deadline = time.monotonic() + 10.0
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                returncode = wait_status_to_returncode(status)
                output += read_available_pty(fd)
                break
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for client close; got {output!r}")
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
    stderr = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        before_batch_count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0

        make_session_clients_unresponsive(env, 30, 30.0)

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
    stderr = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        before_batch_count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0

        make_session_clients_unresponsive(env, 6, 30.0)

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
    stderr = b""
    try:
        stdout += read_until_pipe(proc.stdout, marker.encode("utf-8"), 30.0)
        before_batch_count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0

        make_session_clients_unresponsive(env, 30, 30.0)

        proc.stdin.write(b"trigger-unresponsive\n")
        proc.stdin.flush()
        wait_for_file_count(fake_log, "batch_mode=1", before_batch_count + 1, timeout=15.0)
        stdout += read_until_pipe(proc.stdout, b"sessh: unresponsive: Connection ready", 15.0)
        if b"sessh: disconnected: Reconnecting" in stdout:
            raise AssertionError(f"unresponsive connection showed disconnected before transport close:\n{stdout!r}")

        sever_session_clients(env, 30.0)

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
    if "Connection ready" not in result.stdout:
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
        sever_session_clients(env, 30.0)
        reconnect_output = read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", 10.0)
        proc.stdin.write(b"during-timer\n")
        proc.stdin.flush()
        reconnect_output += read_until_pipe(proc.stdout, b"\x07", 10.0)
        reconnect_output += read_until_pipe(proc.stdout, b"sessh: disconnected: Reconnecting...", 12.0)
        reconnect_output += read_until_pipe(
            proc.stdout,
            b"sessh: disconnected: Connection ready. Switch 10sec. CTRL-R now",
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
    if "sessh: disconnected: Connection ready. Switch 10sec. CTRL-R now" not in result.stdout:
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
        sever_session_clients(env, 30.0)
        stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Retry connecting 10sec", 10.0)
        stdout += read_until_pipe(proc.stdout, b"sessh: disconnected: Reconnecting...", 12.0)
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
        "--- sessh: disconnected: Retry connecting 10sec. CTRL-R now ---",
        "--- sessh: disconnected: Reconnecting... ---",
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
        proc.stdin.write(b"~.")
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


def test_ssh_reconnect_can_close_while_bootstrapping(tmp):
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

    result = run_sessh_close_reconnect_probe(
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


def test_ssh_escape_disconnect_exits_while_remote_output_is_flowing(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_CLOSE_STREAM_READY"
    remote_shell.write_text(
        "#!/bin/sh\n"
        f"printf '{marker}\\n'\n"
        "i=1\n"
        "while :; do\n"
        "  printf 'SSH_CLOSE_STREAM_%06d\\n' \"$i\"\n"
        "  i=$((i + 1))\n"
        "done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh_close_probe(
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
    if "no matching sessh binary is available" not in result.stderr:
        raise AssertionError(result)
    if "falling back to plain ssh without persistence" not in result.stderr:
        raise AssertionError(result)
    if "unsupported" not in result.stderr:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if log_text.splitlines().count("invoked=1") != 2:
        raise AssertionError(log_text)
    if "plain_ssh=1" not in log_text or "plain_host=test-host" not in log_text:
        raise AssertionError(log_text)


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
            "ssh daemon log records client hangup cleanup",
            test_ssh_daemon_log_records_client_hangup_cleanup,
        ),
        (
            "ssh local daemon death exits with error",
            test_ssh_local_daemon_death_exits_with_error,
        ),
        (
            "ssh local daemon death tty error starts on new line",
            test_ssh_local_daemon_death_tty_error_starts_on_new_line,
        ),
        (
            "ssh transport cache hit suppresses bootstrap status",
            test_ssh_transport_cache_hit_suppresses_bootstrap_status,
        ),
        (
            "ssh clean remote exit removes routes",
            test_ssh_clean_remote_exit_removes_routes,
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
            "ssh stdin-null option uses proxy stream",
            test_ssh_stdin_null_option_uses_proxy_stream,
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
            "ssh filter-level raw uses proxy stream",
            test_ssh_filter_level_raw_uses_proxy_stream,
        ),
        (
            "ssh filter-level config uses proxy stream",
            test_ssh_filter_level_config_uses_proxy_stream,
        ),
        (
            "ssh filter-level cli overrides config",
            test_ssh_filter_level_cli_overrides_config,
        ),
        (
            "ssh remote command uses proxy stream",
            test_ssh_remote_command_uses_proxy_stream,
        ),
        (
            "ssh remote command option after host is remote arg",
            test_ssh_remote_command_option_after_host_is_remote_arg,
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
            "ssh no-terminal-emulator remote command uses proxy stream",
            test_ssh_no_terminal_emulator_remote_command_uses_proxy_stream,
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
            "ssh no-terminal-emulator forced tty uses proxy stream",
            test_ssh_no_terminal_emulator_forced_tty_uses_proxy_stream,
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
            "ssh no-terminal-emulator command in tty uses proxy stream",
            test_ssh_no_terminal_emulator_command_in_tty_uses_proxy_stream,
        ),
        (
            "ssh no-terminal-emulator tty uses proxy with hygienic diagnostics",
            test_ssh_no_terminal_emulator_tty_uses_proxy_with_hygienic_diagnostics,
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
            "ssh requested tty with piped stdout does not emit local cleanup",
            test_ssh_requested_tty_with_piped_stdout_does_not_emit_local_cleanup,
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
            "ssh single requested tty remote command with stdin null uses proxy stream",
            test_ssh_single_requested_tty_remote_command_with_stdin_null_uses_proxy_stream,
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
            "ssh host list is remote command",
            test_internal_sessh_host_list_is_remote_command,
        ),
        (
            "ssh config-only cli options are rejected",
            test_ssh_config_only_cli_options_are_rejected,
        ),
        (
            "ssh bootstrap false config uses remote path sessh",
            test_ssh_bootstrap_false_config_uses_remote_path_sessh,
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
            "ssh reconnect can close while bootstrapping",
            test_ssh_reconnect_can_close_while_bootstrapping,
        ),
        (
            "ssh escape disconnect exits while remote output is flowing",
            test_ssh_escape_disconnect_exits_while_remote_output_is_flowing,
        ),
        (
            "ssh unsupported remote platform without matching binary uses plain ssh",
            test_ssh_unsupported_remote_platform_falls_back_to_plain_ssh,
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
