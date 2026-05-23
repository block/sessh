import os
import shlex
import signal
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("SESSH_BIN", str(ROOT / "zig-out" / "bin" / "sessh")))


def sessions_dir(env):
    state_dir = env.get("SESSH_STATE_DIR")
    if state_dir:
        return Path(state_dir) / "g"
    runtime_dir = env.get("XDG_RUNTIME_DIR")
    if not runtime_dir:
        raise AssertionError("test cleanup requires SESSH_STATE_DIR or XDG_RUNTIME_DIR")
    return Path(runtime_dir) / "sessh" / "g"


def cleanup_runtime(env, timeout=5.0):
    kill_all(env, timeout=timeout)
    kill_build_sessh_processes(timeout=timeout)


def kill_all(env, timeout=5.0):
    if not BIN.exists():
        return

    # Avoid starting a broker just to kill every session. The harness controls
    # runtime discovery env vars, so the registry path is deterministic.
    if not sessions_dir(env).exists() or not any(sessions_dir(env).iterdir()):
        return

    subprocess.run(
        [str(BIN), ":local:", "--kill-all"],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def kill_build_sessh_processes(timeout=5.0):
    pids = build_sessh_pids()
    if not pids:
        return

    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in pids:
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        if wait_pids_gone(pids, timeout=0.5 if sig == signal.SIGTERM else timeout):
            return

    remaining = [pid for pid in pids if pid_exists(pid)]
    if remaining:
        raise AssertionError(f"stray build sessh processes survived cleanup: {remaining}")


def build_sessh_pids():
    expected = BIN.resolve(strict=False)
    current_pid = os.getpid()
    result = subprocess.run(
        ["ps", "-axo", "pid=,command="],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

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
        if pid == current_pid or not command:
            continue

        exe = command_executable(command)
        if exe is None:
            continue
        try:
            resolved = exe.resolve(strict=False)
        except OSError:
            continue
        if is_build_sessh_executable(resolved, expected) or is_test_cached_sessh_command(resolved, command):
            pids.append(pid)
    return pids


def is_build_sessh_executable(resolved, expected_wrapper):
    if resolved == expected_wrapper:
        return True

    libexec = ROOT / "zig-out" / "libexec" / "sessh"
    try:
        resolved.relative_to(libexec.resolve(strict=False))
    except ValueError:
        return False
    return resolved.name.startswith("sessh-")


def is_test_cached_sessh_command(resolved, command):
    if ":internal-session-agent:" not in command and ":internal-host-broker:" not in command:
        return False
    parts = resolved.parts
    try:
        tmp_index = parts.index("tmp")
    except ValueError:
        return False
    if len(parts) <= tmp_index + 5 or not parts[tmp_index + 1].startswith("sessh-"):
        return False
    for index in range(tmp_index + 2, len(parts) - 3):
        if parts[index : index + 3] == ("cache", "sessh", "bin"):
            return True
    return False


def command_executable(command):
    try:
        parts = shlex.split(command)
    except ValueError:
        parts = command.split()
    if not parts:
        return None
    return Path(parts[0])


def wait_pids_gone(pids, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if not any(pid_exists(pid) for pid in pids):
            return True
        time.sleep(0.05)
    return not any(pid_exists(pid) for pid in pids)


def pid_exists(pid):
    if pid_is_zombie(pid):
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def pid_is_zombie(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        return False
    return result.stdout.strip().startswith("Z")
