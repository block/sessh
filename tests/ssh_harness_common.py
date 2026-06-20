#!/usr/bin/env python3
import array
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
import threading
import time
import uuid
from pathlib import Path

from harness_cleanup import cleanup_runtime
from socket_harness import (
    CLIENT_DAEMON,
    DRAW,
    SESSION_CLIENT_CONTROL_RESPONSE,
    SESSION_CLIENT_DEBUG_SEVER_CONNECTION_REQUEST,
    SESSION_READY,
    TERMINAL_STREAM_OPEN,
    pack_session_create,
    recv_draw_until,
    recv_frame,
    recv_until_message,
    send_frame,
    send_hello,
    sessh_pb,
)
from fake_ssh import write_fake_ssh
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]


def default_sessh_bin():
    dev_bin = ROOT / "zig-out" / "bin" / "sessh-dev"
    if dev_bin.exists():
        return dev_bin
    return ROOT / "zig-out" / "bin" / "sessh"


BIN = Path(os.environ.get("SESSH_TEST_BIN", str(default_sessh_bin())))


def role_binary():
    candidate = BIN if BIN.is_absolute() else ROOT / BIN
    if candidate.name == "sessh" and (candidate.parent / "sessh-dev").exists():
        return candidate.parent / "sessh-dev"
    return candidate


def sessh_argv(args):
    return [str(BIN), *args]


def symlink_role(path):
    path.symlink_to(role_binary())


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


def start_tcp_echo_server():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(("127.0.0.1", 0))
    server.listen()
    server_port = server.getsockname()[1]
    server_stop = threading.Event()

    def echo_connection(conn):
        with conn:
            while True:
                data = conn.recv(4096)
                if not data:
                    return
                conn.sendall(data)

    def echo_server():
        while not server_stop.is_set():
            try:
                server.settimeout(0.1)
                conn, _ = server.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            threading.Thread(target=echo_connection, args=(conn,), daemon=True).start()

    threading.Thread(target=echo_server, daemon=True).start()
    return server, server_stop, server_port


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
    request = sessh_pb().TerminalEmulatorItem.SessionClientDebugSeverConnectionRequest()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(str(daemon_socket_path(fake_remote_runtime_root(env))))
        send_hello(conn)
        send_frame(conn, SESSION_CLIENT_DEBUG_SEVER_CONNECTION_REQUEST, request.SerializeToString())
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


def remote_proxy_socket_dir():
    return Path(f"/tmp/sessh-{os.getuid()}") / daemon_socket_dir_name()


def remote_proxy_sockets():
    return list(remote_proxy_socket_dir().glob("proxy-*.sock"))


def wait_for_remote_proxy_sockets(baseline=(), timeout=10.0):
    baseline = set(baseline)
    remote_daemon_dir = remote_proxy_socket_dir()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        proxy_sockets = [path for path in remote_proxy_sockets() if path not in baseline]
        if proxy_sockets:
            return proxy_sockets
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for remote proxy socket in {remote_daemon_dir}")


def wait_for_no_remote_proxy_sockets(baseline=(), timeout=10.0):
    baseline = set(baseline)
    deadline = time.monotonic() + timeout
    proxy_sockets = []
    while time.monotonic() < deadline:
        proxy_sockets = [path for path in remote_proxy_sockets() if path not in baseline]
        if not proxy_sockets:
            return
        time.sleep(0.05)
    raise AssertionError(f"remote proxy sockets were not cleaned up: {proxy_sockets}")


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


def send_ssh_transport_acquire(conn, host="test-host", bootstrap=True):
    request = sessh_pb().ClientDaemonItem.SshTransportAcquire(host=host, bootstrap=bootstrap)
    request.local_pid = os.getpid()
    request.local_start_time = f"test-harness-{os.getpid()}"
    frame = sessh_pb().Frame()
    frame.client_daemon.ssh_transport_acquire.CopyFrom(request)
    body = frame.SerializeToString()
    conn.sendall(struct.pack(">I", len(body)) + body)


def recv_client_daemon_ssh_stderr(conn, timeout=30.0):
    old_timeout = conn.gettimeout()
    conn.settimeout(timeout)
    end = time.monotonic() + timeout
    try:
        while time.monotonic() < end:
            conn.settimeout(max(0.1, end - time.monotonic()))
            message_type, payload = recv_frame(conn)
            if message_type != CLIENT_DAEMON:
                continue
            item = sessh_pb().ClientDaemonItem()
            item.ParseFromString(payload)
            if item.WhichOneof("payload") != "connection_event":
                continue
            event = item.connection_event
            if event.WhichOneof("event") == "ssh_stderr":
                return event.ssh_stderr.data
        raise AssertionError("timed out waiting for ssh stderr connection event")
    finally:
        conn.settimeout(old_timeout)


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
            # otherwise a fast child could put the pty in termios raw mode
            # before the test has a baseline to compare against. This is about
            # local tty flags, not sessh's `filter-level=unhygienic`.
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
            deadline = time.monotonic() + 1.0
            while True:
                try:
                    done, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    break
                if done:
                    break
                if time.monotonic() >= deadline:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        os.waitpid(pid, 0)
                    except ChildProcessError:
                        pass
                    break
                time.sleep(0.01)
        os.close(fd)


def set_filter_level_hygienic_tty_mode_probe(fd):
    # This runs in the child side of pty.fork before sessh starts. In
    # filter-level hygienic mode, the visible ssh process owns the PTY and should
    # propagate these local modes.
    attrs = termios.tcgetattr(fd)
    attrs[0] &= ~termios.ICRNL
    attrs[3] &= ~(termios.ECHO | termios.ICANON)
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def set_filter_level_hygienic_output_mode_probe(fd):
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


def run_sessh_reconnect_pty_probe(args, env, ready, after, timeout=30.0):
    argv = sessh_argv(args)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    output = b""
    waited = False
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, output, ready.encode("utf-8"), timeout=timeout)
        sever_session_clients(env, timeout)
        output = read_pty_until(fd, output, b"sessh: disconnected: Retry connecting 10sec", timeout=timeout)
        os.write(fd, b"\x12")
        output = read_pty_until(fd, output, ready.encode("utf-8"), timeout=timeout)
        time.sleep(0.2)
        os.write(fd, after.encode("utf-8") + b"\r")
        output = read_pty_until(fd, output, f"REMOTE:{after}".encode("utf-8"), timeout=timeout)
        os.write(fd, b"~.")

        deadline = time.monotonic() + timeout
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                returncode = wait_status_to_returncode(status)
                output += read_available_pty(fd)
                break
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for reconnect client close; got {output!r}")
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

    return subprocess.CompletedProcess(
        argv,
        returncode,
        output.decode("utf-8", "replace"),
        "",
    )


def wait_for_pty_child(pid, fd, output, timeout=10.0, context="pty command"):
    deadline = time.monotonic() + timeout
    while True:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            return wait_status_to_returncode(status), output + read_available_pty(fd)
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {context} to exit; got {output!r}")
        output += read_available_pty(fd)
        time.sleep(0.05)


OSC_RE = re.compile(r"\x1b\][^\x1b]*(?:\x1b\\|\x07)")
CSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
UI_MESSAGE_RE = re.compile(r"(?:---\s*)?(?:ssh|sessh): [^\r\n]+")


def normalized_ui_messages(text):
    stripped = OSC_RE.sub("", text)
    stripped = CSI_RE.sub("", stripped)
    stripped = re.sub(r"ssh ts_ms=\d+: ", "ssh: ", stripped)
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


def run_sessh_enter_alt_then_reconnect_overlay(args, env, primary, alt_ready, timeout=30.0):
    argv = sessh_argv(args)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    output = b""
    reconnect_output = b""
    waited = False
    returncode = None
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, output, primary.encode("utf-8"), timeout=timeout)
        os.write(fd, b"enter-alt\r")
        output = read_pty_until(fd, output, alt_ready.encode("utf-8"), timeout=timeout)
        sever_session_clients(env, timeout)
        reconnect_start = len(output)
        output = read_pty_until(fd, output, b"sessh: disconnected: Retry connecting 10sec", timeout=timeout)
        reconnect_output = output[reconnect_start:]
        os.write(fd, b"\r~.")
        returncode, output = wait_for_pty_child(pid, fd, output, timeout=timeout, context="alt-screen reconnect close")
        waited = True
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
    return subprocess.CompletedProcess(
        argv,
        returncode,
        reconnect_output.decode("utf-8", "replace"),
        "",
    )


def run_sessh_close_reconnect_probe(args, env, ready, close_bytes=b"~.", timeout=10.0, before_sever=None):
    argv = sessh_argv(args)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    stdout = b""
    waited = False
    returncode = None
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        stdout = read_pty_until(fd, stdout, ready.encode("utf-8"), timeout=timeout)
        if before_sever is not None:
            before_sever()
        sever_session_clients(env, timeout)
        stdout = read_pty_until(fd, stdout, b"sessh: disconnected: Retry connecting 10sec", timeout=timeout)
        if close_bytes == b"~.":
            os.write(fd, b"\r~.")
        else:
            os.write(fd, close_bytes)
        returncode, stdout = wait_for_pty_child(pid, fd, stdout, timeout=timeout, context="reconnect close")
        waited = True
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
    return subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        "",
    )


def run_sessh_close_probe(args, env, ready, timeout=10.0):
    argv = sessh_argv(args)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    stdout = b""
    waited = False
    returncode = None
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        stdout = read_pty_until(fd, stdout, ready.encode("utf-8"), timeout=timeout)
        os.write(fd, b"\r~.")
        returncode, stdout = wait_for_pty_child(pid, fd, stdout, timeout=timeout, context="escape close")
        waited = True
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
    return subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        "",
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
    exe = command_argv0(command)
    return exe.resolve(strict=False) if exe is not None else None


def command_argv0(command):
    try:
        parts = shlex.split(command)
    except ValueError:
        parts = command.split()
    if not parts:
        return None
    exe = Path(parts[0])
    if not exe.is_absolute():
        exe = ROOT / exe
    return exe


def local_daemon_executable(env):
    return daemon_socket_path(Path(env["XDG_RUNTIME_DIR"])).parent / "sesshd"


def daemon_pids_for_executable(target):
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
        if command_argv0(command) == target:
            pids.append(pid)
    return pids


def local_daemon_pids(env):
    return daemon_pids_for_executable(local_daemon_executable(env))


def wait_local_daemon_pids(env, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        pids = local_daemon_pids(env)
        if pids:
            return pids
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for local daemon process {local_daemon_executable(env)}")


def remote_daemon_executable(env):
    return daemon_socket_path(fake_remote_runtime_root(env)).parent / "sesshd"


def remote_daemon_pids(env):
    return daemon_pids_for_executable(remote_daemon_executable(env))


def wait_remote_daemon_pids(env, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        pids = remote_daemon_pids(env)
        if pids:
            return pids
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for remote daemon process {remote_daemon_executable(env)}")


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


def fake_remote_runtime_root(env):
    return Path(env.get("SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR", env["XDG_RUNTIME_DIR"] + ".remote"))


def fake_remote_state_root(env):
    return Path(env.get("SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME", env["XDG_STATE_HOME"] + ".remote")) / "sessh"


def runtime_root(env):
    return Path(env["XDG_RUNTIME_DIR"])


def test_session_guid(index):
    return f"s-{index:08x}-0000-4000-8000-{index:012x}"


def test_proxy_guid():
    return f"p-{uuid.uuid4()}"


def assert_cached_artifact(env, artifact, context):
    cached = artifact_cache_path(env, artifact)
    if not cached.exists():
        raise AssertionError(f"{context}: cached artifact was not created at {cached}")
    if cached.read_bytes() != artifact.read_bytes():
        raise AssertionError(f"{context}: cached artifact does not match source binary")
    if not os.access(cached, os.X_OK):
        raise AssertionError(f"{context}: cached artifact is not executable")
