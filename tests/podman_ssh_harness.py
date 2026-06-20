#!/usr/bin/env python3
import hashlib
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

from harness_cleanup import cleanup_runtime
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
TMUX = shutil.which("tmux")
PLATFORMS = (
    ("linux", "aarch64", "linux/arm64"),
    ("linux", "x86_64", "linux/amd64"),
)
_tmux_counter = 0


CONTAINERFILE = """\
FROM docker.io/library/alpine:3.20
RUN apk add --no-cache openssh-server zsh
RUN ssh-keygen -A && mkdir -p /run/sshd /root/.ssh
# ssh executes the remote command through the account's login shell before the
# command reaches sessh's bootstrapper. zsh intentionally exercises that boundary
# because it does not do POSIX-style word splitting for unquoted scalar
# expansion, which is exactly the class of bug `/bin/sh` would hide here.
RUN sed -i 's#^\\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\\).*#\\1/bin/zsh#' /etc/passwd
RUN printf '\\nAcceptEnv SESSH_TEST_SENDENV\\n' >> /etc/ssh/sshd_config
COPY authorized_keys /root/.ssh/authorized_keys
RUN chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
EXPOSE 22
CMD ["sh", "-c", "exec /usr/sbin/sshd -D -e -o PermitRootLogin=yes -o PasswordAuthentication=no -p ${SSHD_PORT:-22}"]
"""


def run(cmd, *, env=None, cwd=ROOT, timeout=120.0, check=True):
    result = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        text=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        raise AssertionError(f"{cmd} failed\nstdout={result.stdout}\nstderr={result.stderr}")
    return result


def run_bytes(cmd, *, env=None, input_bytes=b"", timeout=30.0, check=False):
    return subprocess.run(
        cmd,
        cwd=ROOT,
        env=env,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=check,
    )


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


def read_pty_until(fd, output, needle, timeout=30.0):
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


def resize_pty_then_send(rows, cols, data):
    def action(fd):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.write(fd, data)

    return action


def next_tmux_label():
    global _tmux_counter
    _tmux_counter += 1
    return f"sessh-podman-{os.getpid()}-{_tmux_counter}"


def tmux_run(label, args, *, env=None, check=True):
    result = subprocess.run(
        [TMUX, "-L", label, *args],
        cwd=ROOT,
        env=env,
        text=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and result.returncode != 0:
        raise AssertionError(f"tmux {args} failed\nstdout={result.stdout}\nstderr={result.stderr}")
    return result


def tmux_capture(label, session):
    return tmux_run(label, ["capture-pane", "-p", "-t", session]).stdout


def wait_tmux_capture(label, session, needle, timeout=30.0):
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        last = tmux_capture(label, session)
        if needle in last:
            return last
        time.sleep(0.05)
    raise AssertionError(f"did not see {needle!r}; pane contained:\n{last}")


def tmux_resize_then_send(rows, cols, data):
    def action(label, session):
        # Resizing the tmux window is the local-terminal-size event that ssh
        # observes for SIGWINCH/window-change propagation. Resizing only the
        # pane can leave the child process reporting the previous size.
        tmux_run(label, ["resize-window", "-t", session, "-x", str(cols), "-y", str(rows)])
        pane_size = tmux_run(label, ["display-message", "-p", "-t", session, "#{pane_height} #{pane_width}"]).stdout.strip()
        if pane_size != f"{rows} {cols}":
            raise AssertionError(f"tmux pane size was {pane_size!r}, expected {rows} {cols}")
        time.sleep(0.3)
        tmux_send_bytes(label, session, data)

    return action


def tmux_send_bytes(label, session, data):
    if data == b"\n" or data == "\n":
        tmux_run(label, ["send-keys", "-t", session, "Enter"])
        return
    if isinstance(data, bytes):
        data = data.decode("utf-8", "replace")
    if data:
        tmux_run(label, ["send-keys", "-t", session, "-l", data])


def write_tmux_exit_runner(marker):
    fd, path = tempfile.mkstemp(prefix="sessh-podman-tmux-runner-", dir="/tmp", text=True)
    with os.fdopen(fd, "w") as script:
        script.write(
            "#!/bin/sh\n"
            "\"$@\"\n"
            "status=$?\n"
            f"printf '\\n{marker}%s\\n' \"$status\"\n"
            "while :; do sleep 3600; done\n"
        )
    os.chmod(path, 0o700)
    return path


def normalize_tmux_visible_output(value):
    value = normalize_output(value)
    lines = [line.rstrip() for line in value.splitlines()]
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines) + ("\n" if lines else "")


def run_in_tmux_visible(cmd, env, steps=(), *, rows=24, cols=100, timeout=30.0):
    if TMUX is None:
        skip("missing tmux")
    label = next_tmux_label()
    session = "visible"
    marker = f"__SESSH_TMUX_EXIT_{os.getpid()}_{label}__:"
    runner = write_tmux_exit_runner(marker)
    try:
        tmux_run(
            label,
            ["new-session", "-d", "-x", str(cols), "-y", str(rows), "-s", session, "--", runner, *cmd],
            env=env,
        )
        for needle, action in steps:
            if isinstance(needle, bytes):
                needle = needle.decode("utf-8", "replace")
            wait_tmux_capture(label, session, needle, timeout)
            if callable(action):
                action(label, session)
            elif action:
                tmux_send_bytes(label, session, action)

        captured = wait_tmux_capture(label, session, marker, timeout)
        match = re.search(re.escape(marker) + r"([0-9]+)", captured)
        if not match:
            raise AssertionError(f"exit marker was not parseable; pane contained:\n{captured}")
        return subprocess.CompletedProcess(
            cmd,
            int(match.group(1)),
            normalize_tmux_visible_output(captured[: match.start()]),
            "",
        )
    finally:
        tmux_run(label, ["kill-server"], check=False)
        try:
            os.unlink(runner)
        except FileNotFoundError:
            pass


def run_in_pty(cmd, env, steps=(), *, rows=24, cols=100, timeout=30.0):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(cmd[0], cmd, env)

    output = b""
    waited = False
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
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
                return subprocess.CompletedProcess(
                    cmd,
                    wait_status_to_returncode(status),
                    normalize_output(output + read_available_pty(fd)),
                    "",
                )
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


def wait_status_to_returncode(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return -os.WTERMSIG(status)
    return status


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


def run_reconnect_probe(cmd, env, ready, after, sever_cmd, timeout=60.0):
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout = read_until_pipe(proc, proc.stdout, ready.encode("utf-8"), timeout)
    if callable(sever_cmd):
        sever_cmd = sever_cmd()
    severed = run(sever_cmd, env=env, timeout=30.0, check=False)
    if severed.returncode != 0:
        proc.kill()
        raise AssertionError(f"{sever_cmd} failed\nstdout={severed.stdout}\nstderr={severed.stderr}")
    stdout += read_until_pipe(proc, proc.stdout, b"sessh: disconnected: Retry connecting 10sec", timeout)
    proc.stdin.write(b"\x12")
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


def normalize_output(value):
    if isinstance(value, bytes):
        value = value.decode("utf-8", "replace")
    value = value.replace("\r\n", "\n")
    value = re.sub(r"/dev/(?:pts/)?[0-9]+", "<tty>", value)
    value = re.sub(r"Connection to 127\\.0\\.0\\.1 closed\\.\\n?", "", value)
    return value


def sessh_oracle_cmd(prefix, config, host_alias, ssh_options, remote_args, sessh_options=()):
    return [
        str(prefix / "bin" / "sessh"),
        *sessh_options,
        "-F",
        str(config),
        *ssh_options,
        host_alias,
        *remote_args,
    ]


def openssh_oracle_cmd(config, host_alias, ssh_options, remote_args):
    return ["ssh", "-F", str(config), *ssh_options, host_alias, *remote_args]


def assert_observable_matches(name, ssh_result, sessh_result, *, compare_stderr=True):
    ssh_observed = (
        ssh_result.returncode,
        normalize_output(ssh_result.stdout),
        normalize_output(ssh_result.stderr) if compare_stderr else "",
    )
    sessh_observed = (
        sessh_result.returncode,
        normalize_output(sessh_result.stdout),
        normalize_output(sessh_result.stderr) if compare_stderr else "",
    )
    if ssh_observed != sessh_observed:
        raise AssertionError(
            f"OpenSSH oracle mismatch for {name}\n"
            f"ssh:   rc={ssh_result.returncode} stdout={normalize_output(ssh_result.stdout)!r} stderr={normalize_output(ssh_result.stderr)!r}\n"
            f"sessh: rc={sessh_result.returncode} stdout={normalize_output(sessh_result.stdout)!r} stderr={normalize_output(sessh_result.stderr)!r}"
        )


def assert_tmux_visible_matches(name, ssh_result, sessh_result):
    ssh_observed = (ssh_result.returncode, normalize_tmux_visible_output(ssh_result.stdout))
    sessh_observed = (sessh_result.returncode, normalize_tmux_visible_output(sessh_result.stdout))
    if ssh_observed != sessh_observed:
        raise AssertionError(
            f"OpenSSH tmux-visible oracle mismatch for {name}\n"
            f"ssh:   rc={ssh_result.returncode} visible_stdout={normalize_tmux_visible_output(ssh_result.stdout)!r}\n"
            f"sessh: rc={sessh_result.returncode} visible_stdout={normalize_tmux_visible_output(sessh_result.stdout)!r}"
        )


def compare_openssh_oracle(
    name,
    prefix,
    config,
    host_alias,
    env,
    *,
    ssh_options=(),
    remote_args=(),
    sessh_options=(),
    input_bytes=b"",
    compare_stderr=True,
    timeout=30.0,
):
    ssh_result = run_bytes(
        openssh_oracle_cmd(config, host_alias, ssh_options, remote_args),
        input_bytes=input_bytes,
        timeout=timeout,
    )
    sessh_result = run_bytes(
        sessh_oracle_cmd(prefix, config, host_alias, ssh_options, remote_args, sessh_options),
        env=env,
        input_bytes=input_bytes,
        timeout=timeout,
    )
    assert_observable_matches(name, ssh_result, sessh_result, compare_stderr=compare_stderr)
    return ssh_result, sessh_result


def compare_openssh_pty_oracle(
    name,
    prefix,
    config,
    host_alias,
    env,
    *,
    ssh_options=(),
    remote_args=(),
    sessh_options=(),
    steps=(),
    timeout=30.0,
):
    ssh_result = run_in_pty(
        openssh_oracle_cmd(config, host_alias, ssh_options, remote_args),
        os.environ.copy(),
        steps,
        timeout=timeout,
    )
    sessh_result = run_in_pty(
        sessh_oracle_cmd(prefix, config, host_alias, ssh_options, remote_args, sessh_options),
        env,
        steps,
        timeout=timeout,
    )
    assert_observable_matches(name, ssh_result, sessh_result, compare_stderr=False)
    return ssh_result, sessh_result


def compare_openssh_tmux_visible_oracle(
    name,
    prefix,
    config,
    host_alias,
    env,
    *,
    ssh_options=(),
    remote_args=(),
    sessh_options=(),
    steps=(),
    timeout=30.0,
):
    # Normal sessh TTY mode renders through sessh's terminal model, so its raw
    # outer-terminal byte stream contains sessh-owned probes and cleanup that
    # OpenSSH will not emit. tmux capture gives us the user-visible pane content
    # instead, which is the compatibility surface for that path.
    ssh_result = run_in_tmux_visible(
        openssh_oracle_cmd(config, host_alias, ssh_options, remote_args),
        os.environ.copy(),
        steps,
        timeout=timeout,
    )
    sessh_result = run_in_tmux_visible(
        sessh_oracle_cmd(prefix, config, host_alias, ssh_options, remote_args, sessh_options),
        env,
        steps,
        timeout=timeout,
    )
    assert_tmux_visible_matches(name, ssh_result, sessh_result)
    return ssh_result, sessh_result


def run_signal_after_stdout(cmd, env, needle, sig=signal.SIGINT, timeout=30.0):
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    stdout = read_until_pipe(proc, proc.stdout, needle, timeout)
    os.killpg(proc.pid, sig)
    try:
        returncode = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        raise
    stdout += proc.stdout.read()
    stderr = proc.stderr.read()
    return subprocess.CompletedProcess(
        cmd,
        returncode,
        stdout,
        stderr,
    )


def compare_signal_oracle(name, prefix, config, host_alias, env, *, remote_args, needle, timeout=30.0):
    ssh_result = run_signal_after_stdout(
        openssh_oracle_cmd(config, host_alias, (), remote_args),
        os.environ.copy(),
        needle,
        timeout=timeout,
    )
    sessh_result = run_signal_after_stdout(
        sessh_oracle_cmd(prefix, config, host_alias, (), remote_args),
        env,
        needle,
        timeout=timeout,
    )
    ssh_stdout = normalize_output(ssh_result.stdout)
    sessh_stdout = normalize_output(sessh_result.stdout)
    if ssh_stdout != sessh_stdout:
        raise AssertionError(
            f"OpenSSH signal-output mismatch for {name}\n"
            f"ssh:   rc={ssh_result.returncode} stdout={ssh_stdout!r} stderr={normalize_output(ssh_result.stderr)!r}\n"
            f"sessh: rc={sessh_result.returncode} stdout={sessh_stdout!r} stderr={normalize_output(sessh_result.stderr)!r}"
        )


def assert_sendenv_visible(name, results, expected_value):
    for label, result in (("ssh", results[0]), ("sessh", results[1])):
        stdout = normalize_output(result.stdout)
        if expected_value not in stdout:
            raise AssertionError(
                f"{name} did not expose SendEnv value for {label}\n"
                f"expected={expected_value!r} stdout={stdout!r}"
            )


def test_sendenv_oracle_cases(prefix, config, host_alias, env):
    sendenv_name = "SESSH_TEST_SENDENV"
    sendenv_value = "sendenv-from-client"
    old_process_sendenv = os.environ.get(sendenv_name)
    old_sessh_sendenv = env.get(sendenv_name)
    os.environ[sendenv_name] = sendenv_value
    env[sendenv_name] = sendenv_value
    command = f"printf 'SENDENV:%s\\n' \"${{{sendenv_name}-unset}}\""
    try:
        assert_sendenv_visible(
            "SendEnv non-tty command",
            compare_openssh_oracle(
                "SendEnv non-tty command",
                prefix,
                config,
                host_alias,
                env,
                ssh_options=("-T",),
                remote_args=(command,),
            ),
            sendenv_value,
        )
        assert_sendenv_visible(
            "SendEnv filter-level emulated tty command",
            compare_openssh_tmux_visible_oracle(
                "SendEnv filter-level emulated tty command",
                prefix,
                config,
                host_alias,
                env,
                ssh_options=("-t",),
                remote_args=(command,),
            ),
            sendenv_value,
        )
        assert_sendenv_visible(
            "SendEnv filter-level hygienic tty command",
            compare_openssh_pty_oracle(
                "SendEnv filter-level hygienic tty command",
                prefix,
                config,
                host_alias,
                env,
                ssh_options=("-t",),
                sessh_options=("--filter-level", "hygienic",),
                remote_args=(command,),
            ),
            sendenv_value,
        )
    finally:
        if old_process_sendenv is None:
            os.environ.pop(sendenv_name, None)
        else:
            os.environ[sendenv_name] = old_process_sendenv
        if old_sessh_sendenv is None:
            env.pop(sendenv_name, None)
        else:
            env[sendenv_name] = old_sessh_sendenv


def skip(message):
    if os.environ.get("SESSH_REQUIRE_PODMAN") == "1":
        raise AssertionError(message)
    cleanup_podman_probe_runtime()
    print(f"skip {message}")
    raise SystemExit(0)


def cleanup_podman_probe_runtime():
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime_dir:
        return
    runtime_path = Path(runtime_dir)
    if not runtime_path.parent.name.startswith("sessh-check."):
        return
    for name in ("containers", "libpod", "podman"):
        shutil.rmtree(runtime_path / name, ignore_errors=True)


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
    for line in (ROOT / "src" / "core" / "config.zig").read_text().splitlines():
        if line.startswith("pub const version = "):
            return line.split('"')[1]
    raise AssertionError("could not find sessh version")


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


def unused_local_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start_container(platform, tag, name, ssh_port):
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
            "-e",
            f"SSHD_PORT={ssh_port}",
            "-p",
            f"127.0.0.1:{ssh_port}:{ssh_port}",
            tag,
        ],
        timeout=60.0,
    ).stdout.strip()
    if not cid:
        raise AssertionError("podman did not return a container id")
    return cid


def mapped_ssh_port(container, ssh_port):
    output = run(["podman", "port", container, f"{ssh_port}/tcp"], timeout=10.0).stdout.strip()
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
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  BatchMode yes
  SendEnv SESSH_TEST_SENDENV
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


def set_remote_login_shell(container, shell_path):
    # Interactive ssh sessions use the remote account's login shell. These
    # tests install tiny shells that exit quickly so the harness can assert on
    # session startup without needing to drive an interactive prompt. The shell
    # scripts still delegate `-c ...` back to zsh because ssh also uses the
    # login shell to run sessh's remote bootstrap command.
    run(
        [
            "podman",
            "exec",
            container,
            "sh",
            "-c",
            f"sed -i 's#^\\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\\).*#\\1{shell_path}#' /etc/passwd",
        ],
        timeout=10.0,
    )


def warm_sessh_artifact_cache(prefix, config, host_alias, env):
    result = run(
        [str(prefix / "bin" / "sessh"), "-F", str(config), host_alias, "true"],
        env=env,
        timeout=60.0,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result)


def test_openssh_oracle_matrix(prefix, config, host_alias, env):
    # These cases deliberately use the real OpenSSH client as the oracle. The
    # fake-ssh harness is faster and more surgical, but it can only verify the
    # behavior we remembered to simulate. This matrix locks down common
    # user-visible behavior against an actual ssh client and sshd pair.
    compare_openssh_oracle(
        "remote command stdout/stderr/exit",
        prefix,
        config,
        host_alias,
        env,
        remote_args=("printf 'OUT\\n'; printf 'ERR\\n' >&2; exit 7",),
    )
    compare_openssh_oracle(
        "remote command stdin data and eof",
        prefix,
        config,
        host_alias,
        env,
        remote_args=("IFS= read -r line; printf 'IN:%s\\n' \"$line\"; IFS= read -r rest || printf 'EOF\\n'",),
        input_bytes=b"hello\n",
    )
    compare_openssh_oracle(
        "remote command stdin immediate eof",
        prefix,
        config,
        host_alias,
        env,
        remote_args=("if IFS= read -r line; then printf 'LINE:%s\\n' \"$line\"; else printf 'EOF\\n'; fi",),
    )
    compare_openssh_oracle(
        "filter-level hygienic no command without tty",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-T",),
        sessh_options=("--filter-level", "hygienic",),
    )
    compare_openssh_oracle(
        "explicit no tty command",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-T",),
        remote_args=("tty || true",),
    )
    test_sendenv_oracle_cases(prefix, config, host_alias, env)
    compare_openssh_oracle(
        "requested tty without local tty",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-t",),
        remote_args=("tty || true",),
        compare_stderr=False,
    )
    compare_openssh_oracle(
        "forced tty without local tty",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-tt",),
        remote_args=("tty",),
        compare_stderr=False,
    )
    compare_openssh_oracle(
        "RequestTTY=no command",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-o", "RequestTTY=no"),
        remote_args=("tty || true",),
    )
    compare_openssh_oracle(
        "remote command exit status",
        prefix,
        config,
        host_alias,
        env,
        remote_args=("exit 23",),
    )
    compare_openssh_oracle(
        "remote process signal death",
        prefix,
        config,
        host_alias,
        env,
        remote_args=("kill -TERM $$",),
        compare_stderr=False,
    )
    compare_signal_oracle(
        "local SIGINT during non-tty command",
        prefix,
        config,
        host_alias,
        env,
        remote_args=("printf 'READY\\n'; sleep 20",),
        needle=b"READY\n",
    )
    compare_openssh_tmux_visible_oracle(
        "requested tty with local tty",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-t",),
        remote_args=("tty",),
    )
    compare_openssh_tmux_visible_oracle(
        "rendered tty stdout stderr exit",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-t",),
        remote_args=("printf 'OUT\\n'; printf 'ERR\\n' >&2; exit 7",),
    )
    compare_openssh_tmux_visible_oracle(
        "rendered tty exit status",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-t",),
        remote_args=("exit 67",),
    )
    compare_openssh_tmux_visible_oracle(
        "rendered tty resize propagation",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-tt",),
        remote_args=("printf 'SIZE1:%s\\n' \"$(stty size)\"; IFS= read -r _; printf 'SIZE2:%s\\n' \"$(stty size)\"",),
        steps=(
            ("SIZE1:24 100", tmux_resize_then_send(31, 120, b"\n")),
            ("SIZE2:31 120", None),
        ),
    )
    compare_openssh_pty_oracle(
        "filter-level hygienic requested tty with local tty",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-t",),
        sessh_options=("--filter-level", "hygienic",),
        remote_args=("tty",),
    )
    compare_openssh_pty_oracle(
        "pty resize propagation",
        prefix,
        config,
        host_alias,
        env,
        ssh_options=("-tt",),
        sessh_options=("--filter-level", "hygienic",),
        remote_args=("printf 'SIZE1:%s\\n' \"$(stty size)\"; IFS= read -r _; printf 'SIZE2:%s\\n' \"$(stty size)\"",),
        steps=(
            (b"SIZE1:24 100", resize_pty_then_send(31, 120, b"\n")),
            (b"SIZE2:31 120", None),
        ),
    )


def test_platform(tmp, prefix, key, os_name, arch, container_platform, expected_uname):
    tag = f"localhost/sessh-e2e-{arch}:{os.getpid()}"
    name = f"sessh-e2e-{arch}-{os.getpid()}"
    host_alias = f"sessh-e2e-{arch}"
    public_key = (Path(str(key) + ".pub")).read_text()

    build_image(tmp, container_platform, tag, public_key)
    ssh_port = unused_local_port()
    container = start_container(container_platform, tag, name, ssh_port)
    env = isolated_env(tmp / f"client-{arch}")

    try:
        port = mapped_ssh_port(container, ssh_port)
        config = write_ssh_config(tmp, host_alias, port, key)
        wait_for_ssh(host_alias, config)

        uname = run(["ssh", "-F", str(config), "-T", host_alias, "uname -m"], timeout=10.0).stdout.strip()
        if uname != expected_uname:
            raise AssertionError(f"{container_platform} reported uname -m={uname!r}")

        env["HOME"] = str(Path(env["SESSH_TEST_ROOT"]) / f"home-{arch}")
        Path(env["HOME"]).mkdir(mode=0o700, exist_ok=True)

        warm_sessh_artifact_cache(prefix, config, host_alias, env)
        test_openssh_oracle_matrix(prefix, config, host_alias, env)

        remote_shell = "/tmp/sessh-e2e-shell"
        marker = f"PODMAN_SESSH_READY_{arch}"
        run(
            [
                "podman",
                "exec",
                container,
                "sh",
                "-c",
                f"cat > {remote_shell} <<'EOF'\n#!/bin/sh\nif [ \"$1\" = -c ]; then exec /bin/zsh \"$@\"; fi\nprintf '{marker}\\n'\nEOF\nchmod +x {remote_shell}",
            ],
            timeout=10.0,
        )
        set_remote_login_shell(container, remote_shell)

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

        artifact_path = prefix / "libexec" / "sessh" / f"{os_name}-{arch}" / "sessh"
        if not artifact_path.exists():
            raise AssertionError(f"missing packaged artifact: {artifact_path}")
        remote_artifact = f"/root/.cache/sessh/bin/{sessh_version()}/{sha256(artifact_path)}/sessh"
        installed = run(
            ["podman", "exec", container, "test", "-x", remote_artifact],
            timeout=10.0,
            check=False,
        )
        if installed.returncode != 0:
            raise AssertionError(f"remote artifact was not installed at {remote_artifact}")
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
