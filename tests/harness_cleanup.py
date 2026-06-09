import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path


# cleanup_runtime removes SESSH_TEST_ROOT wholesale. The sentinel is a cheap
# second lock on that destructive operation: callers must point us at a temp
# tree that was deliberately created by isolated_env, not at a normal runtime
# or cache directory that merely happens to contain sessh files.
TEST_ROOT_SENTINEL = ".sessh-test-root"


def sessions_dir(env):
    runtime_dir = env.get("XDG_RUNTIME_DIR")
    if not runtime_dir:
        raise AssertionError("test cleanup requires XDG_RUNTIME_DIR")
    return Path(runtime_dir) / "guid"


def state_root(env):
    state_home = env.get("XDG_STATE_HOME")
    if state_home:
        return Path(state_home) / "sessh"
    home = env.get("HOME")
    if home:
        return Path(home) / ".local" / "state" / "sessh"
    raise AssertionError("test cleanup requires XDG_STATE_HOME or HOME")


def cleanup_runtime(env, timeout=5.0):
    validate_cleanup_env(env)
    kill_test_daemons(env, timeout=timeout)
    shutil.rmtree(cleanup_test_root(env), ignore_errors=True)
    recreate_test_root(env)


def validate_cleanup_env(env):
    test_root = cleanup_test_root(env)
    require_tmp_test_root(test_root)
    require_test_root_sentinel(test_root)
    for key in (
        "HOME",
        "XDG_RUNTIME_DIR",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "TMPDIR",
    ):
        require_under_test_root(Path(env[key]), test_root)
    if env.get("SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR"):
        require_under_test_root(Path(env["SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR"]), test_root)


def cleanup_test_root(env):
    value = env.get("SESSH_TEST_ROOT")
    if not value:
        raise AssertionError("test cleanup requires SESSH_TEST_ROOT")
    return Path(value)


def require_tmp_test_root(test_root):
    resolved_test_root = test_root.resolve(strict=False)
    tmp_roots = {
        Path(tempfile.gettempdir()).resolve(strict=False),
        Path("/tmp").resolve(strict=False),
    }
    for tmp_root in tmp_roots:
        try:
            resolved_test_root.relative_to(tmp_root)
            return
        except ValueError:
            continue
    roots = ", ".join(str(root) for root in sorted(tmp_roots))
    raise AssertionError(f"refusing to clean non-temp test root {test_root}; temp roots are {roots}")


def require_test_root_sentinel(test_root):
    sentinel = test_root / TEST_ROOT_SENTINEL
    if not sentinel.is_file():
        raise AssertionError(f"refusing to clean unmarked test root {test_root}")


def recreate_test_root(env):
    for key in (
        "HOME",
        "XDG_RUNTIME_DIR",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "TMPDIR",
    ):
        path = Path(env[key])
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(0o700)

    test_root = cleanup_test_root(env)
    (test_root / TEST_ROOT_SENTINEL).write_text("sessh test root\n")


def require_under_test_root(path, test_root, resolve=True):
    raw = Path(path)
    resolved_test_root = test_root.resolve(strict=False)
    resolved = raw.resolve(strict=False) if resolve else raw.parent.resolve(strict=False) / raw.name
    try:
        resolved.relative_to(resolved_test_root)
    except ValueError:
        raise AssertionError(f"refusing to clean non-test path {resolved}; test root is {resolved_test_root}")


def kill_test_daemons(env, timeout=5.0):
    pids = sesshd_socket_owner_pids(env)
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
        raise AssertionError(f"stray test sesshd processes survived cleanup: {remaining}")


def sesshd_socket_owner_pids(env):
    current_pid = os.getpid()
    pids = set()
    for socket_path in cleanup_test_root(env).rglob("sesshd.sock"):
        if not socket_path.exists():
            continue
        owners = socket_owner_pids(socket_path)
        if not owners and socket_accepts_connection(socket_path):
            raise AssertionError(f"live test daemon socket has no discoverable owner: {socket_path}")
        pids.update(owners)
    pids.discard(current_pid)
    return sorted(pids)


def socket_owner_pids(socket_path):
    pids = set()
    pids.update(socket_owner_pids_lsof(socket_path))
    pids.update(socket_owner_pids_fuser(socket_path))
    return pids


def socket_owner_pids_lsof(socket_path):
    if shutil.which("lsof") is None:
        return set()
    result = subprocess.run(
        ["lsof", "-nP", "-t", str(socket_path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode not in (0, 1):
        return set()
    return parse_pid_words(result.stdout)


def socket_owner_pids_fuser(socket_path):
    if shutil.which("fuser") is None:
        return set()
    result = subprocess.run(
        ["fuser", str(socket_path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode not in (0, 1):
        return set()
    return parse_pid_words(result.stdout)


def parse_pid_words(text):
    pids = set()
    for word in text.split():
        try:
            pids.add(int(word))
        except ValueError:
            pass
    return pids


def socket_accepts_connection(socket_path):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(0.1)
        sock.connect(str(socket_path))
        return True
    except OSError:
        return False
    finally:
        sock.close()


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
