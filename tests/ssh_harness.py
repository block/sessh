#!/usr/bin/env python3
import hashlib
import os
import re
import select
import shlex
import socket
import stat
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from harness_cleanup import cleanup_runtime, sessions_dir
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("SESSH_BIN", str(ROOT / "zig-out" / "bin" / "sessh")))
GUID_RE = re.compile(r"^s-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
COMPACT_GUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")


FAKE_SSH = """#!/bin/sh
set -eu

saw_t=0
config_query=0
host=
config=
batch_mode=0
verbose=
plain_option=
ipqos_option=

record_o_option() {
  case "$1" in
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
    -F)
      shift
      if [ "$#" -eq 0 ]; then
        printf 'fake ssh: missing -F argument\\n' >&2
        exit 97
      fi
      config=$1
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
    -t|-tt|-N)
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
    printf 'PLAIN_SSH host=%s\\n' "$host"
    exit 0
  fi
  printf 'fake ssh: missing -T\\n' >&2
  exit 97
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
if [ -n "${SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND:-}" ]; then
  printf 'fake ssh failed before remote command\\n' >&2
  exit "$SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND"
fi
if [ -n "${SESSH_FAKE_SSH_REMOTE_PATH:-}" ]; then
  PATH=$SESSH_FAKE_SSH_REMOTE_PATH:$PATH
  export PATH
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
        [str(BIN), *args],
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


def wait_for_path(path, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {path}")


def run_sessh_until_stdout(args, env, needle, timeout=10.0):
    proc = subprocess.Popen(
        [str(BIN), *args],
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
        [str(BIN), *args],
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


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
    proc = subprocess.Popen(
        [str(BIN), *args],
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = read_until_pipe(proc.stdout, ready.encode("utf-8"), timeout)
    proc.stdin.write(b"\x02s")
    proc.stdin.flush()
    stdout += read_until_pipe(proc.stdout, b"sessh: disconnected. Retry in 5sec", timeout)
    if expect_countdown:
        stdout += read_until_pipe(proc.stdout, b"sessh: disconnected. Retry in 4sec", timeout)
    if during is not None:
        proc.stdin.write(during.encode("utf-8") + b"\n")
        proc.stdin.flush()
    proc.stdin.write(b" ")
    proc.stdin.flush()
    if expect_reconnecting:
        stdout += read_until_pipe(proc.stdout, b"sessh: reconnecting... CTRL-C aborts", timeout)
    stdout += read_until_pipe(proc.stdout, ready.encode("utf-8"), timeout)
    if during is not None:
        during_needle = f"REMOTE:{during}".encode("utf-8")
        if during_needle not in stdout:
            stdout += read_until_pipe(proc.stdout, during_needle, timeout)
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
        [str(BIN), *args],
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


def run_sessh_enter_alt_then_reconnect_banner(args, env, primary, alt_ready, timeout=30.0):
    proc = subprocess.Popen(
        [str(BIN), *args],
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
        stdout = read_until_pipe(proc.stdout, b"sessh: disconnected. Retry in 5sec", timeout)
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
        [str(BIN), *args],
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def run_sessh_abort_reconnect_probe(args, env, ready, abort_bytes=b"\r~.", timeout=10.0):
    proc = subprocess.Popen(
        [str(BIN), *args],
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = read_until_pipe(proc.stdout, ready.encode("utf-8"), timeout)
    proc.stdin.write(b"\x02s")
    proc.stdin.flush()
    stdout += read_until_pipe(proc.stdout, b"sessh: disconnected. Retry in 5sec", timeout)
    proc.stdin.write(abort_bytes)
    proc.stdin.flush()
    proc.stdin.close()
    returncode = proc.wait(timeout=timeout)
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        [str(BIN), *args],
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def run_sessh_detach_probe(args, env, ready, timeout=10.0):
    proc = subprocess.Popen(
        [str(BIN), *args],
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
        [str(BIN), *args],
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
    return Path(env["XDG_CACHE_HOME"]) / "sessh" / "bin" / sessh_version() / sha256(artifact)


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
    return state_root(env) / "g"


def compact_guid(guid):
    if COMPACT_GUID_RE.match(guid):
        return guid.lower()
    if not GUID_RE.match(guid):
        raise AssertionError(f"invalid guid: {guid}")
    return guid[2:].replace("-", "").lower()


def guid_for_alias(alias):
    match = re.fullmatch(r"s([0-9]+)", alias)
    if match:
        return f"s-00000000-0000-4000-8000-{int(match.group(1)):012x}"
    digest = hashlib.sha256(alias.encode("utf-8")).hexdigest()
    return f"s-{digest[0:8]}-{digest[8:12]}-{digest[12:16]}-{digest[16:20]}-{digest[20:32]}"


def ensure_alias(env, alias, guid=None):
    guid = guid or guid_for_alias(alias)
    alias_path = aliases_dir(env) / alias
    alias_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if alias_path.exists() or alias_path.is_symlink():
        return
    alias_path.symlink_to(Path("../g") / compact_guid(guid))


def write_ssh_route(env, alias, guid, host, ssh_options=()):
    ensure_alias(env, alias, guid)
    session = state_sessions_dir(env) / compact_guid(guid)
    session.mkdir(mode=0o700, parents=True, exist_ok=True)
    lines = [
        f"guid={guid}",
        f"primary_alias={alias}",
        f"host={host.encode('utf-8').hex()}",
    ]
    lines.extend(f"ssh_option={option.encode('utf-8').hex()}" for option in ssh_options)
    (session / "route").write_text("\n".join(lines) + "\n")
    return session


def session_path(env, session_id="s1"):
    if GUID_RE.match(session_id) or COMPACT_GUID_RE.match(session_id):
        return sessions_dir(env) / compact_guid(session_id)
    alias_path = aliases_dir(env) / session_id
    if alias_path.is_symlink():
        return sessions_dir(env) / Path(os.readlink(alias_path)).name
    ensure_alias(env, session_id)
    return sessions_dir(env) / Path(os.readlink(alias_path)).name


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
    session = session_path(env, session_id)
    session.mkdir(mode=0o700, parents=True, exist_ok=True)
    (session / "meta").write_text(f"agent_pid={os.getpid()}\nversion=0.0.0-compat-test\n")
    (session / "detached").write_text("")
    sock_path = session / "s"
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
    fake_config = tmp / "ssh_config"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_ATTACH_READY"
    fake_config.write_text("Host test-host\n")
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["-F", str(fake_config), "test-host", "--alias", "s1"], env, timeout=30.0)

    if not fake_log.exists():
        raise AssertionError(f"fake ssh was not invoked: {result}")
    expected_log = f"invoked=1\nconfig={fake_config}\n"
    if fake_log.read_text() != expected_log:
        raise AssertionError(fake_log.read_text())
    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(f"ssh attach did not render remote output: {result}")
    if "ssh runtime attach is not implemented yet" in result.stderr:
        raise AssertionError(result.stderr)
    if any(token in result.stdout or token in result.stderr for token in ("MISSING ", "UPLOAD ", "OK\n")):
        raise AssertionError(result)

    artifact = remote_path_artifact()
    installed = artifact_cache_path(env, artifact)
    if installed.read_bytes() != artifact.read_bytes():
        raise AssertionError("uploaded artifact was not installed")
    if not os.access(installed, os.X_OK):
        raise AssertionError("uploaded artifact is not executable")
    session_meta = session_path(env, "s1") / "meta"
    if not session_meta.exists():
        raise AssertionError("uploaded broker did not create a session agent")


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

    result = run_sessh(["-tt", "test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "PLAIN_SSH host=test-host" not in result.stdout:
        raise AssertionError(result)
    if "fallback to plain-ssh due to ssh option incompatible with sessh transport" not in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "plain_ssh=1" not in log_text or "plain_option=-tt" not in log_text:
        raise AssertionError(log_text)
    if "bootstrapper=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_remote_command_falls_back_to_plain_ssh(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_ALLOW_PLAIN"] = "1"

    result = run_sessh(["test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "PLAIN_SSH host=test-host" not in result.stdout:
        raise AssertionError(result)
    if "fallback to plain-ssh due to non-interactive invocation" not in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "plain_ssh=1" not in log_text or "plain_remote_command=echo hello" not in log_text:
        raise AssertionError(log_text)
    if "bootstrapper=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_unsupported_option_does_not_fallback_for_sessh_action(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_ALLOW_PLAIN"] = "1"

    result = run_sessh(["attach", "-tt", "test-host", "s1"], env, timeout=5.0)

    if result.returncode != 64:
        raise AssertionError(result)
    if "ssh option is not safe for sessh transport" not in result.stderr:
        raise AssertionError(result.stderr)
    if fake_log.exists():
        raise AssertionError(fake_log.read_text())


def test_ssh_bootstrap_overrides_config_false_and_uploads(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_BOOTSTRAP_FLAG_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    config_dir = Path(env["XDG_CONFIG_HOME"]) / "sessh"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "sessh.env").write_text("bootstrap=false\n")
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["test-host", "--bootstrap"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "direct_broker=1" in log_text:
        raise AssertionError(log_text)
    artifact = remote_path_artifact()
    installed = artifact_cache_path(env, artifact)
    if installed.read_bytes() != artifact.read_bytes():
        raise AssertionError("bootstrap flag did not upload artifact")


def test_ssh_no_bootstrap_uses_remote_path_sesshmux(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_NO_BOOTSTRAP_FLAG_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    config_dir = Path(env["XDG_CONFIG_HOME"]) / "sessh"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "sessh.env").write_text("bootstrap=true\n")
    write_fake_ssh(fake_bin / "ssh")
    (fake_bin / "sesshmux").write_text(
        "#!/bin/sh\n"
        "printf 'direct_broker=1\\n' >>\"$SESSH_FAKE_SSH_LOG\"\n"
        f"exec {shlex.quote(str(BIN))} \"$@\"\n"
    )
    (fake_bin / "sesshmux").chmod(0o700)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["test-host", "--no-bootstrap"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "direct_broker=1" not in log_text:
        raise AssertionError(log_text)
    if "bootstrapper=1" in log_text:
        raise AssertionError(log_text)
    assert_cached_artifact(env, remote_path_artifact(), "--no-bootstrap")


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
        f"exec {shlex.quote(str(BIN))} \"$@\"\n"
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

    attached = run_sessh_until_stdout(["attach", "--host", "test-host"], env, marker)

    if attached.returncode != 0:
        raise AssertionError(attached)
    if marker not in attached.stdout:
        raise AssertionError(attached)
    if "remote commands are not supported yet" in attached.stderr:
        raise AssertionError(attached.stderr)


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

    first = run_sessh_until_stdout(["test-host", "--alias", "route-alias"], env, marker)
    if first.returncode != 0:
        raise AssertionError(first)
    if "ID=unset GUID=" not in first.stdout:
        raise AssertionError(first)

    attached = run_sessh_until_stdout(["attach", "route-alias"], env, marker)
    if attached.returncode != 0:
        raise AssertionError(attached)
    if marker not in attached.stdout:
        raise AssertionError(attached)
    log_text = fake_log.read_text()
    if log_text.splitlines().count("invoked=1") < 2:
        raise AssertionError(log_text)


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

    listed = run_sessh(["list", "test-host"], env, timeout=30.0)
    if listed.returncode != 0:
        raise AssertionError(listed)
    rows = [line.split("\t") for line in listed.stdout.splitlines()[1:] if line]
    aliases = [row[0] for row in rows if len(row) >= 1]
    remote_aliases = [alias for alias in aliases if re.fullmatch(r"r[0-9a-f]{8}", alias)]
    if len(remote_aliases) != 1:
        raise AssertionError(listed.stdout)

    attached = run_sessh_until_stdout(["attach", "test-host", remote_aliases[0]], env, marker)
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

    result = run_sessh(["attach", "test-host", "remote-hop"], env, timeout=30.0)

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

    result = run_sessh_reconnect_probe(
        ["test-host", "--leader", "CTRL-B"],
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
    if "sessh: disconnected. Retry in 5sec" not in result.stdout:
        raise AssertionError(result)
    if "sessh: disconnected. Retry in 4sec" not in result.stdout:
        raise AssertionError(result)
    if "sessh: reconnecting... CTRL-C aborts" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:after-reconnect" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:during-reconnect" not in result.stdout:
        raise AssertionError(result)
    if "ReconnectUnsupported" in result.stderr:
        raise AssertionError(result.stderr)
    if "batch_mode=1" not in fake_log.read_text():
        raise AssertionError("reconnect did not force ssh BatchMode=yes")


def test_ssh_no_echo_ping_prevents_false_unresponsive(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_PING_READY"
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

    proc = subprocess.Popen(
        [str(BIN), "test-host"],
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
        [str(BIN), "test-host"],
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: connection unresponsive" in result.stdout:
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
        "blox: error: looks like you are not connected to the VPN. Please connect to the VPN and try again\n"
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
        ["test-host", "--leader", "CTRL-B"],
        env,
        marker,
        "after-reconnect",
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected. Retry in 5sec" not in result.stdout:
        raise AssertionError(result)
    if raw_ssh_error in result.stdout:
        raise AssertionError(result)
    expected_messages = [
        "--- sessh: disconnected. Retry in 5sec. SPACE retries now. CTRL-C aborts ---",
        "--- sessh: reconnecting... CTRL-C aborts ---",
        "ssh: Connection to test-host closed by remote host.",
        "ssh: client_loop: send disconnect: Broken pipe",
        "ssh: control sequence: ?[31mred",
        "--- sessh: reconnected. SPACE to dismiss or wait 500ms ---",
    ]
    actual_messages = normalized_ui_messages(result.stdout)
    if actual_messages != expected_messages:
        raise AssertionError(f"expected UI messages {expected_messages!r}, got {actual_messages!r}\n{result}")
    if "\x1b[31mred" in result.stdout:
        raise AssertionError(result)
    if "ssh stderr:" in result.stdout or "sessh: log" in result.stdout or "level=warn" in result.stdout:
        raise AssertionError(result)
    if result.stderr:
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
        ["test-host", "--leader", "CTRL-B", "--log-level", "quiet"],
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

    proc = subprocess.Popen(
        [str(BIN), "test-host", "--leader", "CTRL-B"],
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
        [str(BIN), "test-host", "--leader", "CTRL-B"],
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
        ["test-host", "--leader", "CTRL-B"],
        env,
        primary_marker,
        alt_marker,
        timeout=30.0,
    )

    if "sessh: disconnected. Retry in 5sec" not in result.stdout:
        raise AssertionError(result)
    if primary_marker in result.stdout:
        raise AssertionError(result)


def test_ssh_reconnect_can_be_aborted_while_bootstrapping(tmp):
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

    result = run_sessh_abort_reconnect_probe(
        ["test-host", "--leader", "CTRL-B"],
        env,
        marker,
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected. Retry in 5sec" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:" in result.stdout:
        raise AssertionError(result)


def test_ssh_reconnect_can_be_aborted_with_ctrl_c(tmp):
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

    result = run_sessh_abort_reconnect_probe(
        ["test-host", "--leader", "CTRL-B"],
        env,
        marker,
        abort_bytes=b"\x03",
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected. Retry in 5sec" not in result.stdout:
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

    result = run_sessh_detach_probe(
        ["test-host", "--leader", "CTRL-B"],
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

    result = run_sessh(["test-host", "--leader", "CTRL-B"], env, timeout=30.0)

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

    result = run_sessh(["attach", "test-host", guid_for_alias("s1")], env, timeout=30.0)

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

    first = run_sessh_until_stdout(["test-host", "--alias", "s1"], env, marker)
    if first.returncode != 0:
        raise AssertionError(first)

    assert_session_compat_points_to_cached_artifact(env, remote_path_artifact(), "s1", "remote session command")

    listed = run_sessh(["list", "test-host"], env, timeout=30.0)
    if listed.returncode != 0:
        raise AssertionError(listed)
    if "ID\tATTACHED\tAGENT_PID" not in listed.stdout or "s1\tno\t" not in listed.stdout:
        raise AssertionError(listed)

    killed = run_sessh(["kill", "test-host", "s1"], env, timeout=30.0)
    if killed.returncode != 0:
        raise AssertionError(killed)
    if not killed.stdout.startswith("ENDED "):
        raise AssertionError(killed)

    listed = run_sessh(["list", "test-host"], env, timeout=30.0)
    if listed.returncode != 0:
        raise AssertionError(listed)
    if "s1" in listed.stdout:
        raise AssertionError(listed)

    stopped = run_sessh(["kill", "--all", "test-host"], env, timeout=30.0)
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

    stopped = run_sessh(["kill", "--all", "test-host"], env, timeout=30.0)

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

    try:
        result = run_sessh(["attach", "--host", "test-host", "--leader", "CTRL-B"], env, timeout=30.0)
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
        f"compat_args=:local: --compat-version {sessh_version()} "
        "--attach --leader CTRL-B --scrollback-limit 2000 --initial-scrollback -1 --log-level warn"
    )
    if expected_args not in log_text:
        raise AssertionError(log_text)


def test_ssh_force_compat_uses_compat_path(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    marker = "SSH_FORCE_COMPAT_READY"
    config_dir = Path(env["XDG_CONFIG_HOME"]) / "sessh"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "sessh.env").write_text(
        "leader=None\nscrollback-limit=77\ninitial-scrollback=0\n"
    )
    write_fake_ssh(fake_bin / "ssh")
    write_compat_marker(session_compat_path(env, "s1"), marker)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["attach", "--force-compat", "--host", "test-host", "s1", "--leader", "CTRL-B"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    if "using compat-fallback" in result.stderr:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if log_text.splitlines().count("invoked=1") != 1:
        raise AssertionError(log_text)
    if "batch_mode=1" in log_text:
        raise AssertionError(log_text)
    expected_args = (
        f"compat_args=:local: --compat-version {sessh_version()} "
        "--attach s1 --leader CTRL-B --scrollback-limit 77 --initial-scrollback 0 --log-level warn"
    )
    if expected_args not in log_text:
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


def main():
    tests = (
        ("fake ssh exports host to remote command", test_fake_ssh_exports_host_to_remote_command),
        (
            "ssh transport uploads artifact and reaches broker",
            test_ssh_transport_uploads_artifact_and_reaches_broker,
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
            "ssh remote command falls back to plain ssh",
            test_ssh_remote_command_falls_back_to_plain_ssh,
        ),
        (
            "ssh unsupported option does not fallback for sessh action",
            test_ssh_unsupported_option_does_not_fallback_for_sessh_action,
        ),
        (
            "ssh bootstrap overrides config false and uploads",
            test_ssh_bootstrap_overrides_config_false_and_uploads,
        ),
        (
            "ssh no-bootstrap uses remote path sesshmux",
            test_ssh_no_bootstrap_uses_remote_path_sesshmux,
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
            "ssh no-host attach uses local route",
            test_ssh_no_host_attach_uses_local_route,
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
            "ssh no-echo ping prevents false unresponsive",
            test_ssh_no_echo_ping_prevents_false_unresponsive,
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
            "ssh reconnect can be aborted while bootstrapping",
            test_ssh_reconnect_can_be_aborted_while_bootstrapping,
        ),
        (
            "ssh reconnect can be aborted with ctrl-c",
            test_ssh_reconnect_can_be_aborted_with_ctrl_c,
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
            "ssh force compat uses compat path",
            test_ssh_force_compat_uses_compat_path,
        ),
    )
    for name, fn in tests:
        run_test(name, fn)


if __name__ == "__main__":
    main()
