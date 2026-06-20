from ssh_harness_common import *

def cleanup_record_files(env):
    procs = state_root(env) / "procs"
    if not procs.exists():
        return []
    return sorted(procs.glob("*.json"))


def wait_for_no_cleanup_records(env, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        records = cleanup_record_files(env)
        if not records:
            return
        time.sleep(0.05)
    raise AssertionError(f"cleanup records remained after clean completion: {cleanup_record_files(env)}")


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


def test_ssh_clean_completion_deletes_cleanup_records(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    terminal = run_sessh_in_pty(
        ["test-host", "printf 'TERMINAL_DONE\\n'"],
        env,
        ((b"TERMINAL_DONE", None),),
        timeout=30.0,
    )
    if terminal.returncode != 0:
        raise AssertionError(ssh_failure_diagnostics("terminal command failed", terminal, fake_log))
    wait_for_no_cleanup_records(env)

    proxy = run_sessh(["-T", "test-host", "printf 'PROXY_DONE\\n'"], env, timeout=30.0)
    if proxy.returncode != 0 or proxy.stdout != "PROXY_DONE\n":
        raise AssertionError(ssh_failure_diagnostics("proxy command failed", proxy, fake_log))
    wait_for_no_cleanup_records(env)


def test_ssh_transport_uploads_artifact_and_reaches_broker(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    fake_config = tmp / "ssh_config"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_SESSION_READY"
    fake_config.write_text("Host test-host\n")
    remote_shell.write_text(
        f"#!/bin/sh\n"
        f"printf '{marker}\\n'\n"
        "printf 'SESSH_PATH=%s\\n' \"$SESSH_PATH\"\n"
        "printf 'SESSH_BIN=%s\\n' \"$(command -v sessh || true)\"\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SHELL"] = str(remote_shell)

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        if b"daemon started socket=" in daemon_log_output:
            raise AssertionError(f"daemon log replayed old entries: {daemon_log_output!r}")

        result = run_sessh_in_pty(
            ["-F", str(fake_config), "test-host"],
            env,
            ((marker.encode("utf-8"), None),),
            timeout=30.0,
        )
        daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
    finally:
        terminate_process(log_proc)

    if not fake_log.exists():
        raise AssertionError(ssh_failure_diagnostics("fake ssh was not invoked", result, fake_log, fake_trace))
    expected_log = f"invoked=1\nconfig={fake_config}\nbatch_mode=1\n"
    if fake_log.read_text() != expected_log:
        raise AssertionError(
            ssh_failure_diagnostics(
                f"unexpected fake ssh log; expected:\n{expected_log}",
                result,
                fake_log,
                fake_trace,
            )
        )
    if result.returncode != 0:
        raise AssertionError(ssh_failure_diagnostics("sessh returned non-zero", result, fake_log, fake_trace))
    if marker not in result.stdout:
        raise AssertionError(
            ssh_failure_diagnostics("ssh session did not render remote output", result, fake_log, fake_trace)
        )
    if any(token in result.stdout or token in result.stderr for token in ("MISSING ", "UPLOAD ", "OK\n")):
        raise AssertionError(
            ssh_failure_diagnostics("bootstrap protocol leaked to client output", result, fake_log, fake_trace)
        )
    combined_output = result.stdout + result.stderr
    status_start = combined_output.find("sessh: bootstrapping...")
    status_clear = combined_output.find("\x1b[K", status_start + 1)
    if status_start < 0 or status_clear < 0 or status_clear < status_start:
        raise AssertionError(
            ssh_failure_diagnostics("bootstrap status was not displayed and cleared", result, fake_log, fake_trace)
        )
    if "ssh ts_ms=" in combined_output:
        raise AssertionError(ssh_failure_diagnostics("bootstrap status was captured as ssh stderr", result, fake_log, fake_trace))

    artifact = remote_path_artifact()
    installed = artifact_cache_path(env, artifact)
    if installed.read_bytes() != artifact.read_bytes():
        raise AssertionError("uploaded artifact was not installed")
    if not os.access(installed, os.X_OK):
        raise AssertionError("uploaded artifact is not executable")
    if f"SESSH_PATH={installed.parent.resolve()}" not in result.stdout:
        raise AssertionError(result)
    if f"SESSH_BIN={installed.resolve()}" not in result.stdout:
        raise AssertionError(result)
    daemon_log_stdout = daemon_log_output.decode("utf-8", "replace")
    for expected in (
        "ssh transport opening host=test-host",
        "ssh transport starting host=test-host bootstrap=true",
        "remote daemon namespace host=test-host namespace=",
        "env=SESSH_DAEMON_NAMESPACE",
        "bootstrap upload required host=test-host",
        "bootstrap completed host=test-host uploaded=true",
        "ssh transport ready host=test-host remote_namespace=",
    ):
        if expected not in daemon_log_stdout:
            raise AssertionError(
                ssh_failure_diagnostics(f"daemon log missing {expected!r}", result, fake_log, fake_trace)
            )

def test_ssh_daemon_log_records_client_hangup_cleanup(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_HANGUP_CLEANUP_READY"
    remote_shell.write_text(
        f"#!/bin/sh\nprintf '{marker}\\n'\nwhile IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SHELL"] = str(remote_shell)

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        result = run_sessh_in_pty(
            ["test-host"],
            env,
            ((marker.encode("utf-8"), b"~."),),
            timeout=30.0,
        )
        daemon_log_output += read_until_pipe(
            log_proc.stdout,
            b"client disconnected; requesting remote cleanup host=test-host guid=s-",
            timeout=5.0,
        )
        daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
    finally:
        terminate_process(log_proc)

    if result.returncode != 0:
        raise AssertionError(ssh_failure_diagnostics("sessh returned non-zero", result, fake_log, fake_trace))
    daemon_log_stdout = daemon_log_output.decode("utf-8", "replace")
    for expected in (
        "client disconnected; requesting remote cleanup host=test-host guid=s-",
    ):
        if expected not in daemon_log_stdout:
            raise AssertionError(
                ssh_failure_diagnostics(f"daemon log missing {expected!r}", result, fake_log, fake_trace)
            )


def test_ssh_killed_client_cleans_up_terminal_resource(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    remote_shell = tmp / "remote-shell"
    exited_file = tmp / "terminal-exited"
    marker = "SSH_KILLED_CLIENT_CLEANUP_READY"
    remote_shell.write_text(
        "#!/bin/sh\n"
        f"trap 'printf terminal-exited > {exited_file}' EXIT\n"
        f"printf '{marker}\\n'\n"
        "while IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SHELL"] = str(remote_shell)

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    argv = sessh_argv(["test-host"])
    pid = None
    fd = None
    waited = False
    daemon_log_output = b""
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(ROOT)
            os.execvpe(argv[0], argv, env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, b"", marker.encode("utf-8"), timeout=30.0)
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        waited = True
        output += read_available_pty(fd)
        if wait_status_to_returncode(status) != -signal.SIGKILL:
            raise AssertionError(output)
        daemon_log_output += read_until_pipe(
            log_proc.stdout,
            b"client disconnected; requesting remote cleanup host=test-host guid=s-",
            timeout=10.0,
        )
        wait_for_path(exited_file, timeout=10.0)
    finally:
        if fd is not None:
            os.close(fd)
        if pid is not None and not waited:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        terminate_process(log_proc)

    if "terminal-exited" not in exited_file.read_text():
        raise AssertionError(exited_file.read_text())
    if b"client disconnected; requesting remote cleanup host=test-host guid=s-" not in daemon_log_output:
        raise AssertionError(daemon_log_output.decode("utf-8", "replace"))


def test_ssh_killed_proxy_client_cleans_up_proxy_resource(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    proxy_bin = tmp / "sessh-proxy"
    symlink_role(proxy_bin)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_G_USER"] = "killed-proxy-user"
    env["SESSH_FAKE_SSH_G_HOSTNAME"] = "killed-proxy-host"
    env["SESSH_FAKE_SSH_G_PORT"] = "2222"
    seed_remote_artifact_cache(env)

    server, server_stop, server_port = start_tcp_echo_server()
    proxy_socket_baseline = remote_proxy_sockets()
    proxy_proc = None
    try:
        proxy_proc = subprocess.Popen(
            [
                str(proxy_bin),
                "--host",
                "test-host",
                "--port",
                str(server_port),
                "--filter-level",
                "unhygienic",
                "--bootstrap",
                "--isolation-mode",
                "process",
            ],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        marker = b"PROCESS_PROXY_BEFORE_CLIENT_KILL\n"
        proxy_proc.stdin.write(marker)
        proxy_proc.stdin.flush()
        read_until_pipe(proxy_proc.stdout, marker, timeout=30.0)
        wait_for_remote_proxy_sockets(proxy_socket_baseline, timeout=10.0)
        proxy_proc.kill()
        proxy_proc.wait(timeout=10.0)
        wait_for_no_remote_proxy_sockets(proxy_socket_baseline, timeout=10.0)
    except Exception as exc:
        stderr = ""
        if proxy_proc is not None:
            if proxy_proc.poll() is None:
                terminate_process(proxy_proc)
            stderr = proxy_proc.stderr.read().decode("utf-8", "replace")
        raise AssertionError(
            f"{exc}\n"
            f"proxy stderr:\n{stderr}\n"
            f"fake ssh log:\n{optional_text(fake_log)}\n"
            f"fake ssh trace:\n{optional_text(fake_trace)}"
        ) from exc
    finally:
        if proxy_proc is not None and proxy_proc.poll() is None:
            terminate_process(proxy_proc)
        server_stop.set()
        server.close()


def test_ssh_transports_pool_terminal_tcp_connection(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    marker1 = "SSH_POOL_READY_1"
    marker2 = "SSH_POOL_READY_2"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_G_USER"] = "pool-user"
    env["SESSH_FAKE_SSH_G_HOSTNAME"] = "pool-host"
    env["SESSH_FAKE_SSH_G_PORT"] = "2222"

    def send_ssh_transport_acquire(conn):
        request = sessh_pb().ClientDaemonItem.SshTransportAcquire(host="test-host", bootstrap=True)
        request.local_pid = os.getpid()
        request.local_start_time = f"test-harness-{os.getpid()}"
        frame = sessh_pb().Frame()
        frame.client_daemon.ssh_transport_acquire.CopyFrom(request)
        body = frame.SerializeToString()
        conn.sendall(struct.pack(">I", len(body)) + body)

    def open_terminal_stream(marker, session_index):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30.0)
        conn.connect(str(daemon_socket_path(Path(env["XDG_RUNTIME_DIR"]))))
        send_hello(conn)
        send_ssh_transport_acquire(conn)
        command = f"printf '{marker}\\n'; sleep 2"
        send_frame(
            conn,
            TERMINAL_STREAM_OPEN,
            pack_session_create(
                "/bin/sh",
                session_id=f"s-{session_index:08x}-0000-4000-8000-{session_index:012x}",
                shell_command=command,
            ),
        )
        recv_until_message(conn, SESSION_READY, timeout=30.0)
        recv_draw_until(conn, marker.encode("utf-8"), timeout=30.0)
        return conn

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    daemon_log_output = b""
    conn1 = conn2 = None
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        try:
            conn1 = open_terminal_stream(marker1, 1)
            conn2 = open_terminal_stream(marker2, 2)
            daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
        except Exception as exc:
            daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
            raise AssertionError(
                f"{exc}\ndaemon log:\n{daemon_log_output.decode('utf-8', 'replace')}"
            ) from exc
    finally:
        if conn2 is not None:
            conn2.close()
        if conn1 is not None:
            conn1.close()
        terminate_process(log_proc)

    if ssh_invocation_count(fake_log) != 1:
        raise AssertionError(
            "expected pooled ssh transports to use one ssh invocation"
            f"\nlog:\n{optional_text(fake_log)}"
            f"\ndaemon log:\n{daemon_log_output.decode('utf-8', 'replace')}"
        )
    daemon_log_text = daemon_log_output.decode("utf-8", "replace")
    for expected in (
        "ssh transport opening host=test-host",
        "pooled ssh transport creating host=test-host",
        "pooled ssh transport remote hello completed host=test-host",
        "pooled ssh transport reusing host=test-host",
        "pooled ssh transport client startup host=test-host",
        "kind=te",
        "request_to_open_ms=",
        "open_to_open_ok_ms=",
        "open_ok_to_first_payload_ms=",
        "request_to_first_payload_ms=",
    ):
        if expected not in daemon_log_text:
            raise AssertionError(f"daemon log missing {expected!r}: {daemon_log_text}")


def test_ssh_transport_pool_key_ignores_agent_socket_identity(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    agent1_path = tmp / "agent-one.sock"
    agent2_path = tmp / "agent-two.sock"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_G_USER"] = "pool-user"
    env["SESSH_FAKE_SSH_G_HOSTNAME"] = "pool-host"
    env["SESSH_FAKE_SSH_G_PORT"] = "2222"
    seed_remote_artifact_cache(env)
    proxy_bin = tmp / "sessh-proxy"
    symlink_role(proxy_bin)

    def send_ssh_transport_acquire(conn, ssh_auth_sock):
        request = sessh_pb().ClientDaemonItem.SshTransportAcquire(host="test-host", bootstrap=True)
        request.local_pid = os.getpid()
        request.local_start_time = f"test-harness-{os.getpid()}"
        request.ssh_auth_sock = ssh_auth_sock
        frame = sessh_pb().Frame()
        frame.client_daemon.ssh_transport_acquire.CopyFrom(request)
        body = frame.SerializeToString()
        conn.sendall(struct.pack(">I", len(body)) + body)

    def open_terminal_stream(marker, session_index, ssh_auth_sock):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30.0)
        conn.connect(str(daemon_socket_path(Path(env["XDG_RUNTIME_DIR"]))))
        send_hello(conn)
        send_ssh_transport_acquire(conn, ssh_auth_sock)
        command = f"printf '{marker}\\n'; sleep 2"
        send_frame(
            conn,
            TERMINAL_STREAM_OPEN,
            pack_session_create(
                "/bin/sh",
                session_id=f"s-{session_index:08x}-0000-4000-8000-{session_index:012x}",
                shell_command=command,
            ),
        )
        recv_until_message(conn, SESSION_READY, timeout=30.0)
        recv_draw_until(conn, marker.encode("utf-8"), timeout=30.0)
        return conn

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    daemon_log_output = b""
    conn1 = conn2 = None
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        conn1 = open_terminal_stream("SSH_AGENT_POOL_1", 1, str(agent1_path))
        conn2 = open_terminal_stream("SSH_AGENT_POOL_2", 2, str(agent2_path))
        daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
    finally:
        if conn2 is not None:
            conn2.close()
        if conn1 is not None:
            conn1.close()
        terminate_process(log_proc)

    if ssh_invocation_count(fake_log) != 1:
        raise AssertionError(
            "expected agent socket identity change to reuse the pooled ssh transport"
            f"\nlog:\n{optional_text(fake_log)}"
            f"\ndaemon log:\n{daemon_log_output.decode('utf-8', 'replace')}"
            f"\ntrace:\n{optional_text(fake_trace)}"
        )


def test_ssh_transport_pool_key_includes_ipqos(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_LOG_IPQOS"] = "1"
    env["SESSH_FAKE_SSH_G_USER"] = "pool-user"
    env["SESSH_FAKE_SSH_G_HOSTNAME"] = "pool-host"
    env["SESSH_FAKE_SSH_G_PORT"] = "2222"
    seed_remote_artifact_cache(env)

    def send_ssh_transport_acquire(conn, ipqos):
        request = sessh_pb().ClientDaemonItem.SshTransportAcquire(host="test-host", bootstrap=True)
        request.local_pid = os.getpid()
        request.local_start_time = f"test-harness-{os.getpid()}"
        request.ssh_option.append(f"-oIPQoS={ipqos}")
        frame = sessh_pb().Frame()
        frame.client_daemon.ssh_transport_acquire.CopyFrom(request)
        body = frame.SerializeToString()
        conn.sendall(struct.pack(">I", len(body)) + body)

    def open_terminal_stream(marker, session_index, ipqos):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30.0)
        conn.connect(str(daemon_socket_path(Path(env["XDG_RUNTIME_DIR"]))))
        send_hello(conn)
        send_ssh_transport_acquire(conn, ipqos)
        command = f"printf '{marker}\\n'; sleep 2"
        send_frame(
            conn,
            TERMINAL_STREAM_OPEN,
            pack_session_create(
                "/bin/sh",
                session_id=f"s-{session_index:08x}-0000-4000-8000-{session_index:012x}",
                shell_command=command,
            ),
        )
        recv_until_message(conn, SESSION_READY, timeout=30.0)
        recv_draw_until(conn, marker.encode("utf-8"), timeout=30.0)
        return conn

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    daemon_log_output = b""
    conn1 = conn2 = None
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        conn1 = open_terminal_stream("SSH_IPQOS_POOL_1", 1, "none")
        conn2 = open_terminal_stream("SSH_IPQOS_POOL_2", 2, "ef")
        daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
    finally:
        if conn2 is not None:
            conn2.close()
        if conn1 is not None:
            conn1.close()
        terminate_process(log_proc)

    log_text = optional_text(fake_log)
    if ssh_invocation_count(fake_log) != 2:
        raise AssertionError(
            "expected effective IPQoS change to create a second ssh transport"
            f"\nlog:\n{log_text}"
            f"\ndaemon log:\n{daemon_log_output.decode('utf-8', 'replace')}"
            f"\ntrace:\n{optional_text(fake_trace)}"
        )
    if "ipqos=none" not in log_text or "ipqos=ef" not in log_text:
        raise AssertionError(log_text)


def test_ssh_proxy_streams_pool_tcp_connection(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    marker1 = b"SSH_PROXY_POOL_1\n"
    marker2 = b"SSH_PROXY_POOL_2\n"
    proxy_guids = [test_proxy_guid(), test_proxy_guid()]
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_G_USER"] = "pool-user"
    env["SESSH_FAKE_SSH_G_HOSTNAME"] = "pool-host"
    env["SESSH_FAKE_SSH_G_PORT"] = "2222"

    server, server_stop, server_port = start_tcp_echo_server()

    def send_ssh_transport_acquire(conn):
        request = sessh_pb().ClientDaemonItem.SshTransportAcquire(host="test-host", bootstrap=True)
        request.local_pid = os.getpid()
        request.local_start_time = f"test-harness-{os.getpid()}"
        frame = sessh_pb().Frame()
        frame.client_daemon.ssh_transport_acquire.CopyFrom(request)
        body = frame.SerializeToString()
        conn.sendall(struct.pack(">I", len(body)) + body)

    def send_mux_frame(conn, mux):
        frame = sessh_pb().Frame()
        frame.daemon_tunnel.mux_stream.CopyFrom(mux)
        body = frame.SerializeToString()
        conn.sendall(struct.pack(">I", len(body)) + body)

    def recv_mux_frame(conn, timeout=30.0):
        old_timeout = conn.gettimeout()
        conn.settimeout(timeout)
        try:
            while True:
                message_type, payload = recv_frame(conn)
                if message_type != "mux_stream_frame":
                    continue
                mux = sessh_pb().DaemonTunnelItem.MuxStreamFrame()
                mux.ParseFromString(payload)
                return mux
        finally:
            conn.settimeout(old_timeout)

    def send_proxy_open(conn, session_index):
        mux = sessh_pb().DaemonTunnelItem.MuxStreamFrame(stream_id=1)
        mux.open.recv_next_offset = 0
        send_mux_frame(conn, mux)
        payload = sessh_pb().DaemonTunnelItem.MuxStreamFrame(stream_id=1)
        payload.payload.offset = 0
        payload.payload.proxy.open.proxy_guid = proxy_guids[session_index - 1]
        payload.payload.proxy.open.proxy_host = "localhost"
        payload.payload.proxy.open.proxy_port = server_port
        send_mux_frame(conn, payload)

    def send_proxy_data(conn, data):
        mux = sessh_pb().DaemonTunnelItem.MuxStreamFrame(stream_id=1)
        mux.payload.offset = 0
        mux.payload.proxy.data = data
        send_mux_frame(conn, mux)

    def recv_proxy_data_until(conn, needle):
        end = time.monotonic() + 30.0
        chunks = []
        while time.monotonic() < end:
            mux = recv_mux_frame(conn, timeout=max(0.1, end - time.monotonic()))
            if mux.WhichOneof("message") != "payload":
                continue
            if mux.payload.WhichOneof("item") != "proxy":
                continue
            if mux.payload.proxy.WhichOneof("payload") != "data":
                continue
            chunks.append(mux.payload.proxy.data)
            if needle in b"".join(chunks):
                return
        raise AssertionError(f"did not receive proxy data {needle!r}: {chunks!r}")

    def open_proxy_stream(marker, session_index):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30.0)
        conn.connect(str(daemon_socket_path(Path(env["XDG_RUNTIME_DIR"]))))
        send_hello(conn)
        send_ssh_transport_acquire(conn)
        send_proxy_open(conn, session_index)
        while recv_mux_frame(conn).WhichOneof("message") != "open_ok":
            pass
        send_proxy_data(conn, marker)
        recv_proxy_data_until(conn, marker)
        return conn

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    conn1 = conn2 = None
    daemon_log_output = b""
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        try:
            conn1 = open_proxy_stream(marker1, 1)
            conn2 = open_proxy_stream(marker2, 2)
            daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
        except Exception as exc:
            daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
            raise AssertionError(
                f"{exc}\ndaemon log:\n{daemon_log_output.decode('utf-8', 'replace')}"
            ) from exc
    finally:
        if conn2 is not None:
            conn2.close()
        if conn1 is not None:
            conn1.close()
        terminate_process(log_proc)
        server_stop.set()
        server.close()

    if ssh_invocation_count(fake_log) != 1:
        raise AssertionError(
            "expected pooled proxy streams to use one ssh invocation"
            f"\nlog:\n{optional_text(fake_log)}"
            f"\ndaemon log:\n{daemon_log_output.decode('utf-8', 'replace')}"
        )
    daemon_log_text = daemon_log_output.decode("utf-8", "replace")
    for expected in (
        "ssh transport opening host=test-host",
        "pooled ssh transport creating host=test-host",
        "pooled ssh transport remote hello completed host=test-host",
        "pooled ssh transport reusing host=test-host",
        "pooled ssh transport client startup host=test-host",
        "kind=proxy",
        "request_to_open_ms=",
        "open_to_open_ok_ms=",
        "open_ok_to_first_payload_ms=",
        "request_to_first_payload_ms=",
    ):
        if expected not in daemon_log_text:
            raise AssertionError(f"daemon log missing {expected!r}: {daemon_log_text}")


def recv_fd(sock, timeout=10.0):
    sock.settimeout(timeout)
    fds = array.array("i")
    msg, ancdata, flags, _ = sock.recvmsg(1024, socket.CMSG_SPACE(fds.itemsize))
    if flags & getattr(socket, "MSG_CTRUNC", 0):
        raise AssertionError("fd control message was truncated")
    for level, kind, data in ancdata:
        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
            fds.frombytes(data[: fds.itemsize])
            return msg, fds[0]
    raise AssertionError(f"no fd received; msg={msg!r} ancdata={ancdata!r}")


def test_ssh_proxy_fd_pass_process_exits_and_raw_fd_streams(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    marker = b"SSH_PROXY_FD_PASS\n"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_G_USER"] = "fdpass-user"
    env["SESSH_FAKE_SSH_G_HOSTNAME"] = "fdpass-host"
    env["SESSH_FAKE_SSH_G_PORT"] = "2222"
    seed_remote_artifact_cache(env)
    proxy_bin = tmp / "sessh-proxy"
    symlink_role(proxy_bin)

    server, server_stop, server_port = start_tcp_echo_server()

    open_ssh_sock, proxy_stdout_sock = socket.socketpair()
    proxy_proc = None
    raw_sock = None
    try:
        proxy_proc = subprocess.Popen(
            [
                str(proxy_bin),
                "--host",
                "test-host",
                "--port",
                str(server_port),
                "--filter-level",
                "unhygienic",
                "--bootstrap",
                "--use-fd-pass",
            ],
            cwd=ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=proxy_stdout_sock.fileno(),
            stderr=subprocess.PIPE,
            close_fds=True,
        )
        proxy_stdout_sock.close()
        proxy_stdout_sock = None

        msg, raw_fd = recv_fd(open_ssh_sock, timeout=30.0)
        if b"sessh-proxy-fd" not in msg:
            raise AssertionError(f"unexpected fd-pass payload: {msg!r}")
        open_ssh_sock.close()
        open_ssh_sock = None

        returncode = proxy_proc.wait(timeout=10.0)
        stderr = proxy_proc.stderr.read().decode("utf-8", "replace")
        if returncode != 0:
            raise AssertionError(
                f"sessh-proxy fd-pass exited {returncode}\nstderr:\n{stderr}\n"
                f"fake ssh log:\n{optional_text(fake_log)}\n"
                f"fake ssh trace:\n{optional_text(fake_trace)}"
            )

        raw_sock = socket.socket(fileno=raw_fd)
        raw_sock.settimeout(30.0)
        raw_sock.sendall(marker)
        data = raw_sock.recv(4096)
        if marker not in data:
            raise AssertionError(f"raw fd did not echo marker; got {data!r}")
    finally:
        if raw_sock is not None:
            raw_sock.close()
        if proxy_proc is not None and proxy_proc.poll() is None:
            terminate_process(proxy_proc)
        if proxy_stdout_sock is not None:
            proxy_stdout_sock.close()
        if open_ssh_sock is not None:
            open_ssh_sock.close()
        server_stop.set()
        server.close()

    log_text = optional_text(fake_log)
    if ssh_invocation_count(fake_log) != 1:
        raise AssertionError(f"expected one pooled ssh transport invocation, got log:\n{log_text}")
