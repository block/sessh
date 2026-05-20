import os
from pathlib import Path


def isolated_env(root):
    root = Path(root)
    env = os.environ.copy()
    env["HOME"] = str(root / "home")
    env["XDG_RUNTIME_DIR"] = str(root / "runtime")
    env["XDG_CACHE_HOME"] = str(root / "cache")
    env["XDG_CONFIG_HOME"] = str(root / "config")
    env["XDG_DATA_HOME"] = str(root / "data")
    env["XDG_STATE_HOME"] = str(root / "state")
    env["TMPDIR"] = str(root / "tmp")
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
    return env
