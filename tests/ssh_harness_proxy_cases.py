from ssh_harness_common import *
from ssh_harness_transport_cases import *

def test_ssh_terminal_and_proxy_streams_share_tcp_connection(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    terminal_marker = "SSH_MIXED_POOL_TERMINAL"
    proxy_marker = b"SSH_MIXED_POOL_PROXY\n"
    proxy_guid = test_proxy_guid()
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_G_USER"] = "pool-user"
    env["SESSH_FAKE_SSH_G_HOSTNAME"] = "pool-host"
    env["SESSH_FAKE_SSH_G_PORT"] = "2222"

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(("127.0.0.1", 0))
    server.listen()
    server_port = server.getsockname()[1]
    server_stop = threading.Event()

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

    def echo_connection(conn):
        with conn:
            while True:
                data = conn.recv(4096)
                if not data:
                    return
                conn.sendall(data)

    threading.Thread(target=echo_server, daemon=True).start()

    def send_ssh_transport_acquire(conn):
        request = sessh_pb().ClientDaemonItem.SshTransportAcquire(host="test-host", bootstrap=True)
        request.local_pid = os.getpid()
        request.local_start_time = f"test-harness-{os.getpid()}"
        frame = sessh_pb().Frame()
        frame.client_daemon.ssh_transport_acquire.CopyFrom(request)
        body = frame.SerializeToString()
        conn.sendall(struct.pack(">I", len(body)) + body)

    def open_terminal_stream():
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30.0)
        conn.connect(str(daemon_socket_path(Path(env["XDG_RUNTIME_DIR"]))))
        send_hello(conn)
        send_ssh_transport_acquire(conn)
        command = f"printf '{terminal_marker}\\n'; sleep 2"
        send_frame(
            conn,
            TERMINAL_STREAM_OPEN,
            pack_session_create(
                "/bin/sh",
                session_id="s-00000001-0000-4000-8000-000000000001",
                shell_command=command,
            ),
        )
        recv_until_message(conn, SESSION_ATTACHED, timeout=30.0)
        recv_draw_until(conn, terminal_marker.encode("utf-8"), timeout=30.0)
        return conn

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

    def send_mux_frame(conn, mux):
        frame = sessh_pb().Frame()
        frame.daemon_tunnel.mux_stream.CopyFrom(mux)
        body = frame.SerializeToString()
        conn.sendall(struct.pack(">I", len(body)) + body)

    def send_proxy_open(conn):
        mux = sessh_pb().DaemonTunnelItem.MuxStreamFrame(stream_id=1)
        mux.open.recv_next_offset = 0
        send_mux_frame(conn, mux)
        payload = sessh_pb().DaemonTunnelItem.MuxStreamFrame(stream_id=1)
        payload.payload.offset = 0
        payload.payload.proxy.open.proxy_guid = proxy_guid
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

    def open_proxy_stream():
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30.0)
        conn.connect(str(daemon_socket_path(Path(env["XDG_RUNTIME_DIR"]))))
        send_hello(conn)
        send_ssh_transport_acquire(conn)
        send_proxy_open(conn)
        while recv_mux_frame(conn).WhichOneof("message") != "open_ok":
            pass
        send_proxy_data(conn, proxy_marker)
        recv_proxy_data_until(conn, proxy_marker)
        return conn

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    terminal_conn = proxy_conn = None
    daemon_log_output = b""
    try:
        daemon_log_output = read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        try:
            terminal_conn = open_terminal_stream()
            proxy_conn = open_proxy_stream()
            daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
        except Exception as exc:
            daemon_log_output += read_available_pipe(log_proc.stdout, timeout=0.5)
            raise AssertionError(
                f"{exc}\ndaemon log:\n{daemon_log_output.decode('utf-8', 'replace')}"
            ) from exc
    finally:
        if proxy_conn is not None:
            proxy_conn.close()
        if terminal_conn is not None:
            terminal_conn.close()
        terminate_process(log_proc)
        server_stop.set()
        server.close()

    if ssh_invocation_count(fake_log) != 1:
        raise AssertionError(
            "expected terminal and proxy streams to share one pooled ssh transport"
            f"\nlog:\n{optional_text(fake_log)}"
            f"\ndaemon log:\n{daemon_log_output.decode('utf-8', 'replace')}"
            f"\ntrace:\n{optional_text(fake_trace)}"
        )
    daemon_log_text = daemon_log_output.decode("utf-8", "replace")
    if "kind=te" not in daemon_log_text or "kind=proxy" not in daemon_log_text:
        raise AssertionError(f"daemon log missing mixed stream startup kinds: {daemon_log_text}")


def test_ssh_local_daemon_death_tty_error_starts_on_new_line(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_DAEMON_DEATH_TTY_READY"
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
    daemon_pids = []
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, output, marker.encode("utf-8"), timeout=30.0)
        daemon_pids = wait_local_daemon_pids(env, timeout=5.0)
        for daemon_pid in daemon_pids:
            os.kill(daemon_pid, signal.SIGTERM)

        deadline = time.monotonic() + 10.0
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                returncode = wait_status_to_returncode(status)
                output += read_available_pty(fd)
                break
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for client close; got {output!r}")
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
        for daemon_pid in daemon_pids:
            try:
                os.kill(daemon_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.close(fd)

    if returncode != 255:
        raise AssertionError(output.decode("utf-8", "replace"))
    if b"\r\nsessh: local daemon connection lost\r\n" not in output:
        raise AssertionError(output)
    if b"Retry connecting" in output or b"Reconnecting" in output:
        raise AssertionError(output)


def test_ssh_transport_cache_hit_suppresses_bootstrap_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    fake_config = tmp / "ssh_config"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_ATTACH_READY"
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

    installed = seed_remote_artifact_cache(env)
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
        daemon_log_output += read_until_pipe(
            log_proc.stdout,
            b"bootstrap skipped host=test-host reason=remote_artifact_present",
            timeout=5.0,
        )
    finally:
        terminate_process(log_proc)

    if result.returncode != 0:
        raise AssertionError(ssh_failure_diagnostics("sessh returned non-zero on cache hit", result, fake_log, fake_trace))
    if marker not in result.stdout:
        raise AssertionError(
            ssh_failure_diagnostics("ssh cache-hit attach did not render remote output", result, fake_log, fake_trace)
        )
    if "sessh: bootstrapping..." in result.stdout or "sessh: bootstrapping..." in result.stderr:
        raise AssertionError(ssh_failure_diagnostics("cache-hit bootstrap displayed upload status", result, fake_log, fake_trace))
    if any(token in result.stdout or token in result.stderr for token in ("MISSING ", "UPLOAD ", "OK\n")):
        raise AssertionError(
            ssh_failure_diagnostics("cache-hit bootstrap protocol leaked to client output", result, fake_log, fake_trace)
        )
    if f"SESSH_PATH={installed.parent.resolve()}" not in result.stdout:
        raise AssertionError(result)
    if f"SESSH_BIN={installed.resolve()}" not in result.stdout:
        raise AssertionError(result)

    expected = "bootstrap skipped host=test-host reason=remote_artifact_present"
    if expected not in daemon_log_output.decode("utf-8", "replace"):
        raise AssertionError(ssh_failure_diagnostics(f"daemon log missing {expected!r}", result, fake_log, fake_trace))


def test_ssh_clean_remote_exit_preserves_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_runtime = Path(env["SESSH_TEST_ROOT"]) / "remote-runtime"
    remote_state = Path(env["SESSH_TEST_ROOT"]) / "remote-state"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_REMOTE_EXIT_READY"
    remote_runtime.mkdir(mode=0o700)
    remote_state.mkdir(mode=0o700)
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\nexit 7\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_XDG_RUNTIME_DIR"] = str(remote_runtime)
    env["SESSH_FAKE_SSH_REMOTE_XDG_STATE_HOME"] = str(remote_state)
    env["SHELL"] = str(remote_shell)

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        ((marker.encode("utf-8"), None),),
        timeout=30.0,
    )

    if result.returncode != 7:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)


def test_ssh_pre_attach_stderr_forwards_immediately(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_PRE_ATTACH_STDERR_READY"
    raw_ssh_error = "pre-attach ssh warning: \x1b[31mred"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_STDERR_BEFORE_COMMAND"] = raw_ssh_error
    env["SHELL"] = str(remote_shell)

    log_proc = subprocess.Popen(
        sessh_argv(["--daemon-log"]),
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    conn = None
    try:
        read_until_pipe(log_proc.stdout, b"daemon log subscribed", timeout=5.0)
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30.0)
        conn.connect(str(daemon_socket_path(Path(env["XDG_RUNTIME_DIR"]))))
        send_hello(conn)
        send_ssh_transport_acquire(conn)
        stderr_chunk = recv_client_daemon_ssh_stderr(conn)
    finally:
        if conn is not None:
            conn.close()
        terminate_process(log_proc)

    if raw_ssh_error.encode("utf-8") not in stderr_chunk:
        raise AssertionError(stderr_chunk)


def test_ssh_transport_pins_ipqos_to_interactive_config_value(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_IPQOS_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_LOG_IPQOS"] = "1"
    env["SESSH_FAKE_SSH_G_IPQOS"] = "af31 cs1"
    env["SHELL"] = str(remote_shell)

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        ((marker.encode("utf-8"), None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "ipqos=af31" not in log_text or "ipqos=cs1" in log_text:
        raise AssertionError(log_text)


def test_ssh_transport_respects_explicit_user_ipqos(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_USER_IPQOS_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_LOG_IPQOS"] = "1"
    env["SESSH_FAKE_SSH_G_IPQOS"] = "af31 cs1"
    env["SHELL"] = str(remote_shell)

    result = run_sessh_in_pty(
        ["-oIPQoS=none", "test-host"],
        env,
        ((marker.encode("utf-8"), None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "ipqos=none" not in log_text or "ipqos=ef" in log_text:
        raise AssertionError(log_text)


def test_ssh_transport_pins_explicit_two_value_ipqos_to_interactive_value(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_USER_TWO_VALUE_IPQOS_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_LOG_IPQOS"] = "1"
    env["SHELL"] = str(remote_shell)

    result = run_sessh_in_pty(
        ["-oIPQoS=ef cs0", "test-host"],
        env,
        ((marker.encode("utf-8"), None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "ipqos=ef\n" not in log_text or "ipqos=cs0" in log_text:
        raise AssertionError(log_text)


def test_ssh_transport_preserves_config_when_ipqos_query_fails(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_IPQOS_QUERY_FAILED_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_LOG_IPQOS"] = "1"
    env["SESSH_FAKE_SSH_G_FAIL"] = "97"
    env["SHELL"] = str(remote_shell)

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        ((marker.encode("utf-8"), None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "ipqos=" in log_text:
        raise AssertionError(log_text)


def test_ssh_session_uses_remote_shell_not_local_client_shell(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    local_shell = tmp / "local-shell"
    remote_shell = tmp / "remote-shell"
    local_marker = "LOCAL_CLIENT_SHELL_USED"
    remote_marker = "REMOTE_LOGIN_SHELL_USED"
    local_shell.write_text(f"#!/bin/sh\nprintf '{local_marker}\\n'\n")
    remote_shell.write_text(f"#!/bin/sh\nprintf '{remote_marker}\\n'\n")
    local_shell.chmod(0o700)
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_SHELL"] = str(remote_shell)
    env["SHELL"] = str(local_shell)

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        ((remote_marker.encode("utf-8"), None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if remote_marker not in result.stdout:
        raise AssertionError(result)
    if local_marker in result.stdout:
        raise AssertionError(result)


def test_ssh_session_does_not_forward_local_zsh_function_path(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    leaked_marker = "LOCAL_FPATH_LEAKED"
    remote_marker = "REMOTE_LOGIN_ENV_OK"
    remote_shell.write_text(
        "#!/bin/sh\n"
        f"if [ \"${{FPATH-unset}}\" = {shlex.quote(str(tmp / 'local-zsh-functions'))} ]; then\n"
        f"  printf '{leaked_marker}\\n'\n"
        "  exit 42\n"
        "fi\n"
        f"printf '{remote_marker}\\n'\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_SHELL"] = str(remote_shell)
    env["FPATH"] = str(tmp / "local-zsh-functions")

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        ((remote_marker.encode("utf-8"), None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if remote_marker not in result.stdout:
        raise AssertionError(result)
    if leaked_marker in result.stdout:
        raise AssertionError(result)


def test_ssh_verbose_flags_are_passed_to_ssh(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_VERBOSE_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_SHELL"] = str(remote_shell)
    env["SHELL"] = str(remote_shell)

    result = run_sessh_in_pty(
        ["-vvv", "test-host"],
        env,
        ((marker.encode("utf-8"), None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    if "verbose=vvv" not in fake_log.read_text():
        raise AssertionError(fake_log.read_text())


def test_ssh_failure_uses_ssh_exit_status_and_visible_args(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_EXIT_BEFORE_COMMAND"] = "255"

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
        result = run_sessh_in_pty(["-vvv", "test-host"], env, [], timeout=5.0)
        daemon_log_output += read_until_pipe(log_proc.stdout, b"ssh transport failed host=test-host", timeout=5.0)
    finally:
        terminate_process(log_proc)

    if result.returncode != 255:
        raise AssertionError(result)
    if "fake ssh failed before remote command" not in result.stdout:
        raise AssertionError(result)
    if "ERROR `ssh -vvv test-host` failed (exitcode=255)" not in result.stdout:
        raise AssertionError(result)
    if "EndOfStream" in result.stdout or "ssh bootstrap failed before response" in result.stdout:
        raise AssertionError(result.stdout)
    daemon_log_stdout = daemon_log_output.decode("utf-8", "replace")
    for expected in (
        "bootstrap failed before response host=test-host error=EndOfStream",
        "ssh transport failed host=test-host error=SshBootstrapFailed",
    ):
        if expected not in daemon_log_stdout:
            raise AssertionError(f"daemon log missing {expected!r}: {daemon_log_stdout!r}")


def test_ssh_stdin_null_option_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["-n", "test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "hello\n":
        raise AssertionError(result)
    if "fallback to plain ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)
    if "proxy_remote_command=echo hello" not in log_text:
        raise AssertionError(log_text)


def test_ssh_x11_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["-X", "test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    if result.stdout != "hello\n":
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "proxy_x11_option=-X" not in log_text:
        raise AssertionError(log_text)
    if "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "proxy_remote_command=echo hello" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_forwarding_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["-L", "8080:localhost:80", "test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "proxy_forward_option=-L" not in log_text:
        raise AssertionError(log_text)
    if "proxy_forward_value=8080:localhost:80" not in log_text:
        raise AssertionError(log_text)
    if "sessh-proxy" not in log_text:
        raise AssertionError(log_text)


def test_ssh_filter_level_unhygienic_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["--filter-level", "unhygienic", "test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_filter_level_config_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "filter-level=unhygienic\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_filter_level_cli_overrides_config(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "filter-level=unhygienic\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(["--filter-level", "hygienic", "test-host"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_proxy_command_forwards_explicit_diagnostics_file(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    diagnostics_path = tmp / "explicit-proxy-diagnostics.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(
        ["--diagnostics-file", str(diagnostics_path), "test-host", "echo", "hello"],
        env,
        timeout=5.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "--diagnostics-file" not in log_text or str(diagnostics_path) not in log_text:
        raise AssertionError(log_text)
    if not diagnostics_path.exists():
        raise AssertionError("explicit diagnostics file was not validated/created")


def test_ssh_proxy_command_auto_forwards_same_tty_diagnostics_file(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["test-host", "echo", "hello"],
        env,
        ((b"hello", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "--diagnostics-file" not in log_text or "/dev/" not in log_text:
        raise AssertionError(log_text)


def test_ssh_proxy_command_does_not_auto_forward_without_same_tty(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "--diagnostics-file" in log_text:
        raise AssertionError(log_text)


def test_ssh_isolation_mode_full_uses_private_proxy_namespace(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(
        ["--isolation-mode", "full", "--filter-level", "unhygienic", "test-host"],
        env,
        timeout=5.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    result2 = run_sessh(
        ["--isolation-mode", "full", "--filter-level", "unhygienic", "test-host"],
        env,
        timeout=5.0,
    )
    if result2.returncode != 0:
        raise AssertionError(result2)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    namespaces = re.findall(r"--daemon-namespace' '([^']+)'", log_text)
    if len(namespaces) != 2:
        raise AssertionError(log_text)
    if any(not namespace.startswith("3.conn.") for namespace in namespaces):
        raise AssertionError(log_text)
    if namespaces[0] == namespaces[1]:
        raise AssertionError(f"isolation-mode=full reused private namespace: {log_text}")
    if "--use-fd-pass" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_isolation_mode_none_uses_proxy_fd_pass(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(
        ["--isolation-mode", "none", "--filter-level", "unhygienic", "test-host"],
        env,
        timeout=5.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "--use-fd-pass" not in log_text:
        raise AssertionError(log_text)
    if "--daemon-namespace" in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_isolation_mode_process_uses_proxy_process(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh(
        ["--isolation-mode", "process", "--filter-level", "unhygienic", "test-host"],
        env,
        timeout=5.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "--use-fd-pass" in log_text:
        raise AssertionError(log_text)
    if "--daemon-namespace" in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)

