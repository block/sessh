#!/usr/bin/env python3
import hashlib
import os
import select
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from harness_cleanup import cleanup_runtime
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = (
    ("linux", "aarch64", "linux/arm64"),
    ("linux", "x86_64", "linux/amd64"),
)


CONTAINERFILE = """\
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache openssh-server zsh
RUN ssh-keygen -A && mkdir -p /run/sshd /root/.ssh
# ssh executes the remote command through the account's login shell before the
# command reaches sessh's bootstrapper. zsh intentionally exercises that boundary
# because it does not do POSIX-style word splitting for unquoted scalar
# expansion, which is exactly the class of bug `/bin/sh` would hide here.
RUN sed -i 's#^\\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\\).*#\\1/bin/zsh#' /etc/passwd
COPY authorized_keys /root/.ssh/authorized_keys
RUN chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e", "-o", "PermitRootLogin=yes", "-o", "PasswordAuthentication=no"]
"""


def run(cmd, *, env=None, cwd=ROOT, timeout=120.0, check=True):
    result = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        raise AssertionError(f"{cmd} failed\nstdout={result.stdout}\nstderr={result.stderr}")
    return result


def run_until_stdout(cmd, env, needle, timeout=30.0):
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + timeout
    stdout = b""
    needle_bytes = needle.encode("utf-8")
    while needle_bytes not in stdout:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            proc.kill()
            raise AssertionError(f"timed out waiting for {needle!r}; got {stdout!r}")
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if not ready:
            proc.kill()
            raise AssertionError(f"timed out waiting for {needle!r}; got {stdout!r}")
        chunk = os.read(proc.stdout.fileno(), 4096)
        if not chunk:
            stderr = proc.stderr.read().decode("utf-8", "replace")
            raise AssertionError(f"process exited before {needle!r}; stdout={stdout!r} stderr={stderr!r}")
        stdout += chunk
    proc.stdin.close()
    returncode = proc.wait(timeout=timeout)
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        cmd,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def read_until_pipe(proc, pipe, needle, timeout=30.0):
    deadline = time.monotonic() + timeout
    data = b""
    while needle not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            proc.kill()
            raise AssertionError(f"timed out waiting for {needle!r}; got {data!r}")
        ready, _, _ = select.select([pipe], [], [], remaining)
        if not ready:
            proc.kill()
            raise AssertionError(f"timed out waiting for {needle!r}; got {data!r}")
        chunk = os.read(pipe.fileno(), 4096)
        if not chunk:
            stderr = proc.stderr.read() if pipe is not proc.stderr else b""
            raise AssertionError(f"process exited before {needle!r}; got={data!r} stderr={stderr!r}")
        data += chunk
    return data


def run_reconnect_probe(cmd, env, ready, after, timeout=60.0):
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = read_until_pipe(proc, proc.stdout, ready.encode("utf-8"), timeout)
    proc.stdin.write(b"\x02s")
    proc.stdin.flush()
    stdout += read_until_pipe(proc, proc.stdout, b"sessh: disconnected. Retry in 5sec", timeout)
    proc.stdin.write(b" ")
    proc.stdin.flush()
    stdout += read_until_pipe(proc, proc.stdout, ready.encode("utf-8"), timeout)
    proc.stdin.write(after.encode("utf-8") + b"\n")
    proc.stdin.flush()
    stdout += read_until_pipe(proc, proc.stdout, f"REMOTE:{after}".encode("utf-8"), timeout)
    proc.stdin.close()
    returncode = proc.wait(timeout=timeout)
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        cmd,
        returncode,
        stdout.decode("utf-8", "replace"),
        stderr.decode("utf-8", "replace"),
    )


def skip(message):
    if os.environ.get("SESSH_REQUIRE_PODMAN") == "1":
        raise AssertionError(message)
    print(f"skip {message}")
    raise SystemExit(0)


def find_zig():
    if os.environ.get("ZIG"):
        return os.environ["ZIG"]
    for candidate in (
        "/opt/homebrew/opt/zig@0.15/bin/zig",
        "/usr/local/opt/zig@0.15/bin/zig",
    ):
        if Path(candidate).exists():
            return candidate
    found = shutil.which("zig")
    if found:
        return found
    raise AssertionError("missing Zig")


def require_podman():
    if shutil.which("podman") is None:
        skip("podman is not installed")
    result = run(["podman", "info", "--format", "{{.Host.Arch}} {{.Host.OS}}"], check=False, timeout=15.0)
    if result.returncode != 0:
        skip(f"podman is not usable: {result.stderr.strip()}")


def build_install_tree(tmp):
    zig = find_zig()
    prefix = tmp / "install"
    run([zig, "build", "--prefix", str(prefix)], timeout=300.0)
    return prefix


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sessh_version():
    for line in (ROOT / "src" / "config.zig").read_text().splitlines():
        if line.startswith("pub const version = "):
            return line.split('"')[1]
    raise AssertionError("could not find sessh version")


def first_session_id(list_stdout):
    for line in list_stdout.splitlines()[1:]:
        if not line:
            continue
        return line.split("\t", 1)[0]
    raise AssertionError(f"no sessions in list output: {list_stdout!r}")


def compact_session_id(session_id):
    return session_id.replace("-", "")


def generate_key(tmp):
    key = tmp / "ssh_key"
    run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], timeout=10.0)
    return key


def build_image(tmp, platform, tag, public_key):
    context = tmp / f"container-{platform.replace('/', '-')}"
    context.mkdir()
    (context / "Containerfile").write_text(CONTAINERFILE)
    (context / "authorized_keys").write_text(public_key)
    run(
        [
            "podman",
            "build",
            "--platform",
            platform,
            "-t",
            tag,
            str(context),
        ],
        timeout=240.0,
    )


def start_container(platform, tag, name):
    cid = run(
        [
            "podman",
            "run",
            "-d",
            "--rm",
            "--platform",
            platform,
            "--name",
            name,
            "-p",
            "127.0.0.1::22",
            tag,
        ],
        timeout=60.0,
    ).stdout.strip()
    if not cid:
        raise AssertionError("podman did not return a container id")
    return cid


def mapped_ssh_port(container):
    output = run(["podman", "port", container, "22/tcp"], timeout=10.0).stdout.strip()
    host_port = output.rsplit(":", 1)[-1]
    return int(host_port)


def write_ssh_config(tmp, host_alias, port, key):
    config = tmp / f"{host_alias}.sshconfig"
    config.write_text(
        f"""\
Host {host_alias}
  HostName 127.0.0.1
  Port {port}
  User root
  IdentityFile {key}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  BatchMode yes
"""
    )
    config.chmod(0o600)
    return config


def wait_for_ssh(host_alias, config):
    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline:
        result = run(
            ["ssh", "-F", str(config), "-T", host_alias, "true"],
            timeout=5.0,
            check=False,
        )
        if result.returncode == 0:
            return
        time.sleep(0.5)
    raise AssertionError(f"ssh target did not become ready: {result.stderr}")


def test_platform(tmp, prefix, key, os_name, arch, container_platform, expected_uname):
    tag = f"localhost/sessh-e2e-{arch}:{os.getpid()}"
    name = f"sessh-e2e-{arch}-{os.getpid()}"
    host_alias = f"sessh-e2e-{arch}"
    public_key = (Path(str(key) + ".pub")).read_text()

    build_image(tmp, container_platform, tag, public_key)
    container = start_container(container_platform, tag, name)
    env = isolated_env(tmp / f"client-{arch}")

    try:
        port = mapped_ssh_port(container)
        config = write_ssh_config(tmp, host_alias, port, key)
        wait_for_ssh(host_alias, config)

        uname = run(["ssh", "-F", str(config), "-T", host_alias, "uname -m"], timeout=10.0).stdout.strip()
        if uname != expected_uname:
            raise AssertionError(f"{container_platform} reported uname -m={uname!r}")

        env["HOME"] = str(tmp / f"home-{arch}")
        Path(env["HOME"]).mkdir(mode=0o700, exist_ok=True)
        remote_shell = "/tmp/sessh-e2e-shell"
        marker = f"PODMAN_SESSH_READY_{arch}"
        run(
            [
                "podman",
                "exec",
                container,
                "sh",
                "-c",
                f"cat > {remote_shell} <<'EOF'\n#!/bin/sh\nprintf '{marker}\\n'\nEOF\nchmod +x {remote_shell}",
            ],
            timeout=10.0,
        )
        env["SHELL"] = remote_shell

        result = run(
            [str(prefix / "bin" / "sessh"), "-F", str(config), host_alias],
            env=env,
            timeout=60.0,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(result)
        if marker not in result.stdout:
            raise AssertionError(result)
        if "ssh runtime attach is not implemented yet" in result.stderr:
            raise AssertionError(result.stderr)

        remote_shell = "/tmp/sessh-e2e-shell-reconnect"
        reconnect_marker = f"PODMAN_SESSH_RECONNECT_{arch}"
        run(
            [
                "podman",
                "exec",
                container,
                "sh",
                "-c",
                f"cat > {remote_shell} <<'EOF'\n#!/bin/sh\nprintf '{reconnect_marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\nEOF\nchmod +x {remote_shell}",
            ],
            timeout=10.0,
        )
        env["SHELL"] = remote_shell

        reconnected = run_reconnect_probe(
            [str(prefix / "bin" / "sessh"), "-F", str(config), host_alias, "--leader", "CTRL-B"],
            env,
            reconnect_marker,
            f"after-reconnect-{arch}",
            timeout=90.0,
        )
        if reconnected.returncode != 0:
            raise AssertionError(reconnected)
        if "sessh: disconnected. Retry in 5sec" not in reconnected.stdout:
            raise AssertionError(reconnected)
        if f"REMOTE:after-reconnect-{arch}" not in reconnected.stdout:
            raise AssertionError(reconnected)
        if "ReconnectUnsupported" in reconnected.stderr:
            raise AssertionError(reconnected.stderr)

        artifact_path = prefix / "libexec" / "sessh" / f"sesshmux-{os_name}-{arch}"
        if not artifact_path.exists():
            raise AssertionError(f"missing packaged artifact: {artifact_path}")
        remote_artifact = f"/root/.cache/sessh/bin/{sessh_version()}/{sha256(artifact_path)}"
        installed = run(
            ["podman", "exec", container, "test", "-x", remote_artifact],
            timeout=10.0,
            check=False,
        )
        if installed.returncode != 0:
            raise AssertionError(f"remote artifact was not installed at {remote_artifact}")

        remote_shell = "/tmp/sessh-e2e-shell-loop"
        command_marker = f"PODMAN_SESSH_COMMAND_{arch}"
        run(
            [
                "podman",
                "exec",
                container,
                "sh",
                "-c",
                f"cat > {remote_shell} <<'EOF'\n#!/bin/sh\nprintf '{command_marker}\\n'\nwhile :; do sleep 1; done\nEOF\nchmod +x {remote_shell}",
            ],
            timeout=10.0,
        )
        env["SHELL"] = remote_shell

        started = run_until_stdout(
            [str(prefix / "bin" / "sessh"), "-F", str(config), host_alias],
            env,
            command_marker,
            timeout=60.0,
        )
        if started.returncode != 0:
            raise AssertionError(started)

        listed = run(
            [str(prefix / "bin" / "sesshmux"), "list", "-F", str(config), host_alias],
            env=env,
            timeout=60.0,
            check=False,
        )
        if listed.returncode != 0:
            raise AssertionError(listed)
        if "ID\tATTACHED\tAGENT_PID" not in listed.stdout or "\tno\t" not in listed.stdout:
            raise AssertionError(listed)
        session_id = first_session_id(listed.stdout)
        compat_path = f"/tmp/sessh-0/g/{compact_session_id(session_id)}/compat"
        compat = run(
            [
                "podman",
                "exec",
                container,
                "sh",
                "-c",
                f"test -L {compat_path} && test -x \"$(readlink {compat_path})\"",
            ],
            timeout=10.0,
            check=False,
        )
        if compat.returncode != 0:
            raise AssertionError(f"remote session compat symlink was not installed at {compat_path}")

        killed = run(
            [str(prefix / "bin" / "sesshmux"), "kill", "-F", str(config), host_alias, session_id],
            env=env,
            timeout=60.0,
            check=False,
        )
        if killed.returncode != 0:
            raise AssertionError(killed)
        if f"ENDED {session_id}" not in killed.stdout:
            raise AssertionError(killed)

        stopped = run(
            [str(prefix / "bin" / "sesshmux"), "kill", "--all", "-F", str(config), host_alias],
            env=env,
            timeout=60.0,
            check=False,
        )
        if stopped.returncode != 0:
            raise AssertionError(stopped)
        if "KILLING_ALL" not in stopped.stdout:
            raise AssertionError(stopped)

        stopped_again = run(
            [str(prefix / "bin" / "sesshmux"), "kill", "--all", "-F", str(config), host_alias],
            env=env,
            timeout=60.0,
            check=False,
        )
        if stopped_again.returncode != 0:
            raise AssertionError(stopped_again)
        if "KILLING_ALL" not in stopped_again.stdout:
            raise AssertionError(stopped_again)
    finally:
        run(["podman", "stop", "-t", "0", container], timeout=30.0, check=False)
        run(["podman", "rmi", "-f", tag], timeout=30.0, check=False)
        cleanup_runtime(env)


def main():
    require_podman()
    with tempfile.TemporaryDirectory(prefix="sessh-podman-ssh-", dir="/tmp") as tmp_text:
        tmp = Path(tmp_text)
        prefix = build_install_tree(tmp)
        key = generate_key(tmp)
        for os_name, arch, container_platform in PLATFORMS:
            expected_uname = "x86_64" if arch == "x86_64" else "aarch64"
            test_platform(tmp, prefix, key, os_name, arch, container_platform, expected_uname)
            print(f"ok podman ssh {container_platform}")


if __name__ == "__main__":
    main()
