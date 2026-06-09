import os
from pathlib import Path


TEST_ROOT_SENTINEL = ".sessh-test-root"


def isolated_env(root):
    root = Path(root)
    test_root = root / "sessh-test-root"
    env = os.environ.copy()
    # Terminal rendering tests assert xterm-compatible control sequences. Do not
    # inherit the runner's TERM, which may be missing or "dumb" in CI.
    env["TERM"] = "xterm-256color"
    # Interactive login shells may otherwise write ~/.bash_history or similar
    # files into the isolated HOME, which should stay clean after each test run.
    env["HISTFILE"] = "/dev/null"
    env["HOME"] = str(test_root / "home")
    env["XDG_RUNTIME_DIR"] = str(test_root / "runtime")
    env["XDG_CACHE_HOME"] = str(test_root / "cache")
    env["XDG_CONFIG_HOME"] = str(test_root / "config")
    env["XDG_DATA_HOME"] = str(test_root / "data")
    env["XDG_STATE_HOME"] = str(test_root / "state")
    env["TMPDIR"] = str(test_root / "tmp")
    env["SESSH_TEST_ROOT"] = str(test_root)
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
    test_root.mkdir(parents=True, exist_ok=True)
    test_root.chmod(0o700)
    # cleanup_runtime refuses to rm -rf a test root unless this marker exists.
    # That keeps a miswired env from deleting an ordinary runtime/cache tree.
    (test_root / TEST_ROOT_SENTINEL).write_text("sessh test root\n")
    return env
