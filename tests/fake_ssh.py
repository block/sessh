#!/usr/bin/env python3

import stat


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
  # OpenSSH does not hand arbitrary client shell internals to the remote command
  # unless configured to do so with SendEnv/AcceptEnv. Keep the fake boundary
  # honest so tests catch sessh forwarding those variables itself.
  unset FPATH
  unset fpath
  unset ZDOTDIR
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
  config_user=${SESSH_FAKE_SSH_G_USER:-${USER:-}}
  if [ -n "$ipqos_option" ]; then
    printf 'user %s\\n' "$config_user"
    printf 'hostname %s\\n' "$config_hostname"
    printf 'port %s\\n' "$config_port"
    case "$ipqos_option" in
      *\\ *) printf 'ipqos %s\\n' "$ipqos_option" ;;
      *) printf 'ipqos %s %s\\n' "$ipqos_option" "$ipqos_option" ;;
    esac
  else
    printf 'user %s\\n' "$config_user"
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
if [ "$batch_mode" -eq 1 ] && [ -n "${SESSH_FAKE_SSH_DELAY_ON_BATCH:-}" ] && { [ -z "${SESSH_FAKE_SSH_DELAY_ON_BATCH_FILE:-}" ] || [ -e "$SESSH_FAKE_SSH_DELAY_ON_BATCH_FILE" ]; }; then
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
