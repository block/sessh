from ssh_harness_common import *
from ssh_harness_transport_cases import *
from ssh_harness_proxy_cases import *
from ssh_harness_terminal_cases import *

def test_ssh_retry_elapsed_with_input_waits_before_switch(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_TIMER_READY"
    after = "after-timer-reconnect"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["test-host"])
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    stdout = b""
    returncode = None
    waited = False
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        stdout = read_pty_until(fd, stdout, marker.encode("utf-8"), timeout=10.0)
        sever_session_clients(env, 30.0)
        reconnect_start = len(stdout)
        stdout = read_pty_until(fd, stdout, b"sessh: disconnected: Retry connecting 10sec", timeout=10.0)
        reconnect_output = stdout[reconnect_start:]
        os.write(fd, b"during-timer\r")
        reconnect_start = len(stdout)
        stdout = read_pty_until(fd, stdout, b"\x07", timeout=10.0)
        reconnect_output += stdout[reconnect_start:]
        reconnect_start = len(stdout)
        stdout = read_pty_until(fd, stdout, b"sessh: disconnected: Reconnecting...", timeout=12.0)
        reconnect_output += stdout[reconnect_start:]
        reconnect_start = len(stdout)
        stdout = read_pty_until(
            fd,
            stdout,
            b"sessh: disconnected: Connection ready. Switch 10sec. CTRL-R now",
            timeout=10.0,
        )
        reconnect_output += stdout[reconnect_start:]
        time.sleep(0.5)
        extra = read_available_pty(fd)
        stdout += extra
        reconnect_output += extra
        if marker.encode("utf-8") in reconnect_output:
            raise AssertionError(f"reconnect repainted before Ctrl-R:\n{reconnect_output!r}")

        os.write(fd, b"\x12")
        stdout = read_pty_until(fd, stdout, marker.encode("utf-8"), timeout=10.0)
        time.sleep(0.2)
        os.write(fd, after.encode("utf-8") + b"\r")
        stdout = read_pty_until(fd, stdout, f"REMOTE:{after}".encode("utf-8"), timeout=10.0)
        os.write(fd, b"\r~.")
        returncode, stdout = wait_for_pty_child(pid, fd, stdout, timeout=10.0, context="retry elapsed client")
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

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        "",
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Connection ready. Switch 10sec. CTRL-R now" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:during-timer" in result.stdout:
        raise AssertionError(result)
    if f"REMOTE:{after}" not in result.stdout:
        raise AssertionError(result)
    if "sessh: reconnected" in result.stdout:
        raise AssertionError(result)
    if "batch_mode=1" not in fake_log.read_text():
        raise AssertionError("timer reconnect did not force ssh BatchMode=yes")


def test_ssh_retry_elapsed_without_input_switches_automatically(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_TIMER_AUTO_READY"
    after = "after-auto-reconnect"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["test-host"])
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    stdout = b""
    returncode = None
    waited = False
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        stdout = read_pty_until(fd, stdout, marker.encode("utf-8"), timeout=10.0)
        sever_session_clients(env, 30.0)
        stdout = read_pty_until(fd, stdout, b"sessh: disconnected: Retry connecting 10sec", timeout=10.0)
        stdout = read_pty_until(fd, stdout, b"sessh: disconnected: Reconnecting...", timeout=12.0)
        stdout = read_pty_until_count(fd, stdout, marker.encode("utf-8"), 2, timeout=10.0)
        time.sleep(0.2)
        os.write(fd, after.encode("utf-8") + b"\r")
        stdout = read_pty_until(fd, stdout, f"REMOTE:{after}".encode("utf-8"), timeout=10.0)
        os.write(fd, b"\r~.")
        returncode, stdout = wait_for_pty_child(pid, fd, stdout, timeout=10.0, context="auto retry client")
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

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        stdout.decode("utf-8", "replace"),
        "",
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Connection ready" in result.stdout:
        raise AssertionError(result)
    if f"REMOTE:{after}" not in result.stdout:
        raise AssertionError(result)
    if "batch_mode=1" not in fake_log.read_text():
        raise AssertionError("timer reconnect did not force ssh BatchMode=yes")


def test_ssh_no_echo_input_ack_prevents_false_unresponsive(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_INPUT_ACK_READY"
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

    before_batch_count = [None]

    def send_slow_no_output(fd):
        count = fake_log.read_text().count("batch_mode=1") if fake_log.exists() else 0
        before_batch_count[0] = count
        os.write(fd, b"slow-no-output\r")

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        (
            (marker.encode("utf-8"), send_slow_no_output),
            (b"REMOTE:old-recovered", b"after-recovery\r"),
            (b"REMOTE:after-recovery", None),
        ),
        timeout=15.0,
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Unresponsive" in result.stdout:
        raise AssertionError(result)
    if before_batch_count[0] is None:
        raise AssertionError(result)
    if fake_log.read_text().count("batch_mode=1") != before_batch_count[0]:
        raise AssertionError("false unresponsive detection started a parallel reconnect attempt")


def test_ssh_reconnect_displays_live_ssh_stderr_in_overlay(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_RECONNECT_STDERR_READY"
    raw_ssh_error = (
        "error: looks like you are not connected to the VPN. Please connect to the VPN and try again\n"
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

    result = run_sessh_reconnect_pty_probe(
        ["test-host"],
        env,
        marker,
        "after-reconnect",
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting 10sec" not in result.stdout:
        raise AssertionError(result)
    if raw_ssh_error in result.stdout:
        raise AssertionError(result)
    expected_messages = [
        "--- sessh: disconnected: Retry connecting 10sec. CTRL-R now ---",
        "ssh: Connection to test-host closed by remote host.",
        "ssh: client_loop: send disconnect: Broken pipe",
        "ssh: control sequence: ?[31mred",
        "--- sessh: disconnected: Reconnecting... ---",
    ]
    actual_messages = " ".join(normalized_ui_messages(result.stdout))
    search_from = 0
    for expected in expected_messages:
        found_at = actual_messages.find(expected, search_from)
        if found_at < 0:
            raise AssertionError(f"expected UI message {expected!r} after offset {search_from}, got {actual_messages!r}\n{result}")
        search_from = found_at + len(expected)
    if "\x1b[31mred" in result.stdout:
        raise AssertionError(result)
    if "ssh stderr:" in result.stdout or "sessh: log" in result.stdout or "level=warn" in result.stdout:
        raise AssertionError(result)
    if (Path(env["XDG_CACHE_HOME"]) / "sessh" / "clients").exists():
        raise AssertionError("client logs were written to persistent cache")


def test_ssh_remote_transport_close_reconnects_in_tty(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_REMOTE_TRANSPORT_RECONNECT_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh_reconnect_pty_probe(
        ["test-host"],
        env,
        marker,
        "after-remote-transport-reconnect",
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting 10sec" not in result.stdout:
        raise AssertionError(result)
    if "sessh: local daemon connection lost" in result.stdout:
        raise AssertionError(result)
    if "sessh: remote daemon died" in result.stdout:
        raise AssertionError(result)
    if "REMOTE:after-remote-transport-reconnect" not in result.stdout:
        raise AssertionError(result)


def test_ssh_child_ssh_death_reconnects_in_tty(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    kill_file = tmp / "kill-child-ssh-once"
    marker = "SSH_CHILD_SSH_DEATH_READY"
    after = "after-child-ssh-death"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_KILL_BATCH_ONCE_FILE"] = str(kill_file)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["test-host"])
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    output = b""
    waited = False
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, output, marker.encode("utf-8"), timeout=30.0)
        kill_file.write_text("")
        output = read_pty_until(fd, output, b"sessh: disconnected: Retry connecting 10sec", timeout=30.0)
        os.write(fd, b"\x12")
        output = read_pty_until_count(fd, output, marker.encode("utf-8"), 2, timeout=30.0)
        time.sleep(0.2)
        os.write(fd, after.encode("utf-8") + b"\r")
        output = read_pty_until(fd, output, f"REMOTE:{after}".encode("utf-8"), timeout=30.0)
        os.write(fd, b"\r~.")
        returncode, output = wait_for_pty_child(pid, fd, output, timeout=30.0, context="child ssh death client")
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

    result = subprocess.CompletedProcess(
        argv,
        returncode,
        output.decode("utf-8", "replace"),
        "",
    )
    if result.returncode != 0:
        raise AssertionError(result)
    if "REMOTE:after-child-ssh-death" not in result.stdout:
        raise AssertionError(result)
    log_text = optional_text(fake_log)
    if "kill_batch_triggered=1" not in log_text:
        raise AssertionError(log_text)
    if ssh_invocation_count(fake_log) < 2:
        raise AssertionError(log_text)


def test_ssh_remote_daemon_death_reports_remote_error(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_REMOTE_DAEMON_DEATH_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    argv = sessh_argv(["test-host"])
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    output = b""
    waited = False
    remote_pids = []
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, output, marker.encode("utf-8"), timeout=30.0)
        remote_pids = wait_remote_daemon_pids(env, timeout=5.0)
        for remote_pid in remote_pids:
            os.kill(remote_pid, signal.SIGTERM)
        output = read_pty_until(fd, output, b"sessh: disconnected: Retry connecting 10sec", timeout=30.0)
        os.write(fd, b"\x12")
        output = read_pty_until(fd, output, b"sessh: remote daemon died", timeout=30.0)

        deadline = time.monotonic() + 10.0
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                returncode = wait_status_to_returncode(status)
                output += read_available_pty(fd)
                break
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for remote daemon death exit; got {output!r}")
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
        for remote_pid in remote_pids:
            try:
                os.kill(remote_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.close(fd)

    if returncode != 255:
        raise AssertionError(output.decode("utf-8", "replace"))
    if b"\r\nsessh: remote daemon died\r\n" not in output:
        raise AssertionError(output)
    if b"sessh: local daemon connection lost" in output:
        raise AssertionError(output)


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

    result = run_sessh_reconnect_pty_probe(
        ["--log-level", "quiet", "test-host"],
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

    def trigger_stderr_and_close(fd):
        signal_file.write_text("")
        wait_for_path(done_file, 10.0)
        os.write(fd, b"~.")

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        [(marker.encode("utf-8"), trigger_stderr_and_close)],
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    expected = f"ssh ts_ms="
    if expected not in result.stdout or f": {raw_ssh_error}" not in result.stdout:
        raise AssertionError(result)
    if "ssh stderr:" in result.stdout or "sessh: log" in result.stdout or "level=warn" in result.stdout:
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

    result = run_sessh_enter_alt_then_reconnect_overlay(
        ["test-host"],
        env,
        primary_marker,
        alt_marker,
        timeout=30.0,
    )

    if "sessh: disconnected: Retry connecting 10sec" not in result.stdout:
        raise AssertionError(result)
    if primary_marker in result.stdout:
        raise AssertionError(result)


def test_ssh_reconnect_can_close_while_bootstrapping(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    delay_file = tmp / "delay-batch-reconnect"
    marker = "SSH_RECONNECT_ABORT_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_DELAY_ON_BATCH"] = "20"
    env["SESSH_FAKE_SSH_DELAY_ON_BATCH_FILE"] = str(delay_file)
    env["SHELL"] = str(remote_shell)

    result = run_sessh_close_reconnect_probe(
        ["test-host"],
        env,
        marker,
        timeout=10.0,
        before_sever=lambda: delay_file.write_text(""),
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "sessh: disconnected: Retry connecting 10sec" not in result.stdout:
        raise AssertionError(result)
    if "REMOTE:" in result.stdout:
        raise AssertionError(result)


def test_ssh_escape_disconnect_exits_while_remote_output_is_flowing(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_CLOSE_STREAM_READY"
    remote_shell.write_text(
        "#!/bin/sh\n"
        f"printf '{marker}\\n'\n"
        "i=1\n"
        "while :; do\n"
        "  printf 'SSH_CLOSE_STREAM_%06d\\n' \"$i\"\n"
        "  i=$((i + 1))\n"
        "done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh_close_probe(
        ["test-host"],
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

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        ((b"PLAIN_SSH host=test-host", None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "PLAIN_SSH host=test-host" not in result.stdout:
        raise AssertionError(result)
    combined_output = result.stdout + result.stderr
    if "no matching sessh binary is available" not in combined_output:
        raise AssertionError(result)
    if "falling back to plain ssh without persistence" not in combined_output:
        raise AssertionError(result)
    if "unsupported" not in combined_output:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if log_text.splitlines().count("invoked=1") != 2:
        raise AssertionError(log_text)
    if "plain_ssh=1" not in log_text or "plain_host=test-host" not in log_text:
        raise AssertionError(log_text)

