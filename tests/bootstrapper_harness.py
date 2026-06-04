#!/usr/bin/env python3
import base64
import hashlib
import os
import stat
import subprocess
import tempfile
from pathlib import Path

from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAPPER = ROOT / "src" / "bootstrapper.sh"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def run_bootstrapper(input_text, env, extra_env=None):
    env = env.copy()
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["/bin/sh", str(BOOTSTRAPPER)],
        cwd=ROOT,
        env=env,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5.0,
    )


def write_executable(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def artifact_path(env, artifact_hash):
    return Path(env["XDG_CACHE_HOME"]) / "sessh" / "bin" / "test-set" / artifact_hash / "sesshmux"


def write_fake_uname(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "#!/bin/sh\n"
        "case \"$1\" in\n"
        "  -s) printf '%s\\n' \"$SESSH_FAKE_UNAME_S\" ;;\n"
        "  -m) printf '%s\\n' \"$SESSH_FAKE_UNAME_M\" ;;\n"
        "  *) exit 1 ;;\n"
        "esac\n"
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def assert_ok(process):
    if process.returncode != 0:
        raise AssertionError(process)
    if process.stderr:
        raise AssertionError(process)


def test_cache_hit_execs_without_platform_or_tool_probe(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-bin"
    fake_bin.mkdir()
    env["PATH"] = str(fake_bin)
    artifact = b"#!/bin/sh\nprintf 'CACHED %s\\n' \"$*\"\n"
    artifact_hash = sha256(artifact)
    write_executable(artifact_path(env, artifact_hash), artifact)

    result = run_bootstrapper(f"EXEC test-set {artifact_hash} -- :internal-session-broker:\n", env)

    assert_ok(result)
    if result.stdout != "OK\nCACHED :internal-session-broker:\n":
        raise AssertionError(result.stdout)


def test_cache_hit_execs_explicit_internal_command(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-bin"
    fake_bin.mkdir()
    env["PATH"] = str(fake_bin)
    artifact = b"#!/bin/sh\nprintf 'CACHED %s\\n' \"$*\"\n"
    artifact_hash = sha256(artifact)
    write_executable(artifact_path(env, artifact_hash), artifact)

    result = run_bootstrapper(
        f"EXEC test-set {artifact_hash} -- :internal-stream-broker: p-00000000-0000-4000-8000-000000000001 proxy 1 1 bG9jYWxob3N0 22 -\n",
        env,
    )

    assert_ok(result)
    expected = "OK\nCACHED :internal-stream-broker: p-00000000-0000-4000-8000-000000000001 proxy 1 1 bG9jYWxob3N0 22 -\n"
    if result.stdout != expected:
        raise AssertionError(result.stdout)


def test_cache_hit_decodes_encoded_exec_args(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-bin"
    fake_bin.mkdir()
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    artifact = (
        b"#!/bin/sh\n"
        b"printf 'CACHED argc=%s\\n' \"$#\"\n"
        b"for arg in \"$@\"; do printf '<%s>\\n' \"$arg\"; done\n"
    )
    artifact_hash = sha256(artifact)
    write_executable(artifact_path(env, artifact_hash), artifact)
    request = '{"guid":"s-00000000-0000-4000-8000-000000000001","requested_age_ms":1000,"note":"alpha beta \' gamma"}'
    encoded_request = "b64:" + base64.b64encode(request.encode()).decode()

    result = run_bootstrapper(
        f"EXEC test-set {artifact_hash} -- :internal-session-broker: kill --jsonl --request {encoded_request}\n",
        env,
    )

    assert_ok(result)
    expected = (
        "OK\n"
        "CACHED argc=5\n"
        "<:internal-session-broker:>\n"
        "<kill>\n"
        "<--jsonl>\n"
        "<--request>\n"
        f"<{request}>\n"
    )
    if result.stdout != expected:
        raise AssertionError(result.stdout)


def test_upload_installs_and_execs(tmp):
    env = isolated_env(tmp)
    artifact = b"#!/bin/sh\nprintf 'UPLOADED %s\\n' \"$*\"\n"
    artifact_hash = sha256(artifact)
    encoded = base64.b64encode(artifact).decode()

    result = run_bootstrapper(
        f"EXEC test-set {artifact_hash} -- :internal-session-broker:\n"
        f"UPLOAD sessh-test-linux-x86_64 {artifact_hash} {encoded}\n",
        env,
    )

    assert_ok(result)
    lines = result.stdout.splitlines()
    if len(lines) != 3:
        raise AssertionError(result.stdout)
    if not lines[0].startswith("MISSING "):
        raise AssertionError(result.stdout)
    if lines[1] != "OK":
        raise AssertionError(result.stdout)
    if lines[2] != "UPLOADED :internal-session-broker:":
        raise AssertionError(result.stdout)

    installed = artifact_path(env, artifact_hash)
    if installed.read_bytes() != artifact:
        raise AssertionError("uploaded artifact was not installed")
    if not os.access(installed, os.X_OK):
        raise AssertionError("uploaded artifact is not executable")


def test_invalid_artifact_set_is_rejected(tmp):
    env = isolated_env(tmp)
    result = run_bootstrapper("EXEC ../bad 0123\n", env)

    if result.returncode == 0:
        raise AssertionError(result)
    if not result.stdout.startswith("ERR INVALID_EXEC "):
        raise AssertionError(result.stdout)


def test_exec_command_is_required(tmp):
    env = isolated_env(tmp)
    artifact = b"#!/bin/sh\nprintf 'CACHED %s\\n' \"$*\"\n"
    artifact_hash = sha256(artifact)
    write_executable(artifact_path(env, artifact_hash), artifact)

    result = run_bootstrapper(f"EXEC test-set {artifact_hash}\n", env)

    if result.returncode == 0:
        raise AssertionError(result)
    if result.stdout != "ERR INVALID_EXEC missing_exec_command\n":
        raise AssertionError(result.stdout)


def test_cache_hit_trusts_cached_executable(tmp):
    env = isolated_env(tmp)
    expected = b"#!/bin/sh\nprintf 'EXPECTED\\n'\n"
    wrong = b"#!/bin/sh\nprintf 'WRONG\\n'\n"
    expected_hash = sha256(expected)
    write_executable(artifact_path(env, expected_hash), wrong)

    result = run_bootstrapper(f"EXEC test-set {expected_hash} -- :internal-session-broker:\n", env)

    assert_ok(result)
    if result.stdout != "OK\nWRONG\n":
        raise AssertionError(result.stdout)


def test_cache_miss_reports_platform_before_tool_probe(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-bin"
    write_fake_uname(fake_bin / "uname")
    env["PATH"] = str(fake_bin)

    result = run_bootstrapper(
        "EXEC test-set 0000000000000000000000000000000000000000000000000000000000000000 -- :internal-session-broker:\n",
        env,
        extra_env={
            "SESSH_FAKE_UNAME_S": "Linux",
            "SESSH_FAKE_UNAME_M": "x86_64",
        },
    )

    if result.returncode == 0:
        raise AssertionError(result)
    if result.stdout != "MISSING linux x86_64\nERR MISSING_UPLOAD expected_upload\n":
        raise AssertionError(result.stdout)


def test_platform_strings_are_canonicalized(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-bin"
    write_fake_uname(fake_bin / "uname")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"

    cases = (
        ("Linux", "i686", "MISSING linux x86\n"),
        ("Linux", "armv7l", "MISSING linux arm32\n"),
        ("Linux", "riscv64", "MISSING linux riscv64\n"),
        ("Darwin", "arm64", "MISSING macos aarch64\n"),
    )
    for os_name, arch, expected in cases:
        result = run_bootstrapper(
            "EXEC test-set 0000000000000000000000000000000000000000000000000000000000000000 -- :internal-session-broker:\n",
            env,
            extra_env={
                "SESSH_FAKE_UNAME_S": os_name,
                "SESSH_FAKE_UNAME_M": arch,
            },
        )

        if not result.stdout.startswith(expected):
            raise AssertionError((os_name, arch, result.stdout, result.stderr))


def test_unsupported_platform_is_structured_error(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-bin"
    write_fake_uname(fake_bin / "uname")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"

    result = run_bootstrapper(
        "EXEC test-set 0000000000000000000000000000000000000000000000000000000000000000 -- :internal-session-broker:\n",
        env,
        extra_env={
            "SESSH_FAKE_UNAME_S": "Plan9",
            "SESSH_FAKE_UNAME_M": "sparc",
        },
    )

    if result.returncode == 0:
        raise AssertionError(result)
    if not result.stdout.startswith("ERR UNSUPPORTED_PLATFORM unsupported_os_Plan9\n"):
        raise AssertionError(result.stdout)
    if result.stdout.startswith("MISSING ERR "):
        raise AssertionError(result.stdout)


def run_test(name, fn):
    with tempfile.TemporaryDirectory(prefix="sessh-bootstrapper-") as tmp:
        fn(Path(tmp))
    print(f"ok {name}")


def main():
    tests = (
        ("cache hit execs without platform or tool probe", test_cache_hit_execs_without_platform_or_tool_probe),
        ("cache hit execs explicit internal command", test_cache_hit_execs_explicit_internal_command),
        ("cache hit decodes encoded exec args", test_cache_hit_decodes_encoded_exec_args),
        ("upload installs and execs", test_upload_installs_and_execs),
        ("invalid artifact set is rejected", test_invalid_artifact_set_is_rejected),
        ("exec command is required", test_exec_command_is_required),
        ("cache hit trusts cached executable", test_cache_hit_trusts_cached_executable),
        ("cache miss reports platform before tool probe", test_cache_miss_reports_platform_before_tool_probe),
        ("platform strings are canonicalized", test_platform_strings_are_canonicalized),
        ("unsupported platform is structured error", test_unsupported_platform_is_structured_error),
    )
    for name, fn in tests:
        run_test(name, fn)


if __name__ == "__main__":
    main()
