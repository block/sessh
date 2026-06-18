from socket_harness_common import *

def run_login_shell_profile_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-login-shell-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        cleanup_runtime(env)
        profile = Path(env["HOME"]) / ".profile"
        profile.write_text("printf 'LOGIN_PROFILE_READY\\n'\n")
        try:
            start_daemon(env)
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                create_and_attach_session(conn, Path("/bin/sh"))
                message_type, _payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                recv_draw_until(conn, b"LOGIN_PROFILE_READY")
                send_frame(conn, INPUT, pack_bytes(b"exit\n"))
                recv_until_message(conn, SESSION_ENDED)
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_session_create_command_argv_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-command-argv-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "shell-should-not-run"
        command = Path(tmp) / "command-child"
        shell.write_text("#!/bin/sh\nprintf 'UNEXPECTED_SHELL\\n'\nexit 1\n")
        shell.chmod(0o700)
        command.write_text(
            "#!/bin/sh\n"
            "printf 'COMMAND_ARGV_READY:%s\\n' \"$1\"\n"
            "while IFS= read -r line; do\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "done\n"
        )
        command.chmod(0o700)
        cleanup_runtime(env)
        try:
            start_daemon(env)
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                create_and_attach_session(conn, shell, command_argv=[command, "arg-one"])
                message_type, _payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                _matched, draws = recv_draw_until(conn, b"COMMAND_ARGV_READY:arg-one")
                draw_bytes = b"".join(draw["draw_bytes"] for draw in draws)
                if b"UNEXPECTED_SHELL" in draw_bytes:
                    raise AssertionError(draws)
                send_frame(conn, INPUT, pack_bytes(b"exit\n"))
                recv_until_message(conn, SESSION_ENDED)
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_session_create_shell_command_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-command-shell-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "remote-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" != -c ]; then\n"
            "  printf 'UNEXPECTED_SHELL_ARG:%s\\n' \"$1\"\n"
            "  exit 1\n"
            "fi\n"
            "printf 'SHELL_EVAL_USED\\n'\n"
            "exec /bin/sh -c \"$2\"\n"
        )
        shell.chmod(0o700)
        shell_command = (
            "printf 'COMMAND_SHELL_READY:%s\\n' \"$SESSH_GUID\"; "
            "while IFS= read -r line; do [ \"$line\" = exit ] && exit 0; done"
        )
        cleanup_runtime(env)
        try:
            start_daemon(env)
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                create_and_attach_session(conn, shell, shell_command=shell_command)
                message_type, _payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                _matched, draws = recv_draw_until(conn, b"COMMAND_SHELL_READY:s-")
                draw_bytes = b"".join(draw["draw_bytes"] for draw in draws)
                if b"SHELL_EVAL_USED" not in draw_bytes:
                    raise AssertionError(draws)
                if b"UNEXPECTED_SHELL_ARG" in draw_bytes:
                    raise AssertionError(draws)
                send_frame(conn, INPUT, pack_bytes(b"exit\n"))
                recv_until_message(conn, SESSION_ENDED)
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_session_create_tty_settings_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-tty-settings-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        cleanup_runtime(env)
        try:
            start_daemon(env)
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                create_and_attach_session(
                    conn,
                    "/bin/sh",
                    shell_command="printf 'TERM=%s\\n' \"$TERM\"; stty -a; exit",
                    tty_settings={
                        "term": "ansi",
                        # RFC/OpenSSH opcode 53 is ECHO. Turning it off is a
                        # visible way to verify that SessionCreate settings
                        # reached the child PTY before exec.
                        "modes": ((53, 0),),
                    },
                )
                message_type, _payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                _matched, draws = recv_draw_until(conn, b"-echo")
                draw_bytes = b"".join(draw["draw_bytes"] for draw in draws)
                if b"TERM=ansi" not in draw_bytes or b"-echo" not in draw_bytes:
                    raise AssertionError(draws)
                recv_until_message(conn, SESSION_ENDED)
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def startup_cwd_title_sequence():
    return b"\x1b]2;" + str(ROOT).encode() + b"\x1b\\"


def config_version():
    config = (ROOT / "src" / "core" / "config.zig").read_text()
    version = re.search(r'pub const version = "([^"]+)";', config).group(1)
    major = int(re.search(r"pub const protocol_major = ([0-9]+);", config).group(1))
    minor = int(re.search(r"pub const protocol_minor = ([0-9]+);", config).group(1))
    return version, major, minor


def send_hello(conn, major_delta=0, minor_delta=0, version_override=None, expect_ok=True):
    version, major, minor = config_version()
    peer_version = version_override or version
    peer_major = major + major_delta
    peer_minor = minor + minor_delta
    if peer_major < 0:
        raise AssertionError(f"invalid negative protocol major: {peer_major}")
    if peer_minor < 0:
        raise AssertionError(f"invalid negative protocol minor: {peer_minor}")
    send_frame(
        conn,
        HELLO_REQUEST,
        sessh_hpb().HelloRequest(
            protocol_major=peer_major,
            protocol_minor=peer_minor,
            version=peer_version,
        ).SerializeToString(),
    )
    message_type, payload = recv_frame(conn)
    if expect_ok:
        if message_type != HELLO_OK:
            raise AssertionError(f"expected HELLO_OK, got {message_type}")
        ok = sessh_hpb().HelloOk()
        ok.ParseFromString(payload)
    else:
        if message_type != HELLO_ERROR:
            raise AssertionError(f"expected HELLO_ERROR, got {message_type}")
        error = sessh_hpb().HelloError()
        error.ParseFromString(payload)
        if error.code != "VERSION_MISMATCH":
            raise AssertionError(f"expected VERSION_MISMATCH, got {error!r}")
        return message_type, payload
    message_type, payload = recv_frame(conn)
    if message_type != HELLO_REQUEST:
        raise AssertionError(f"expected peer HELLO_REQUEST, got {message_type}")
    peer = sessh_hpb().HelloRequest()
    peer.ParseFromString(payload)
    if peer.protocol_major != major or peer.protocol_minor != minor or peer.version != version:
        raise AssertionError(f"unexpected peer HELLO_REQUEST: {peer!r}")
    send_frame(conn, HELLO_OK, sessh_hpb().HelloOk().SerializeToString())
    return message_type, payload


def broker_hello(env, **kwargs):
    proc = subprocess.Popen(
        [str(BIN), ":broker:"],
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    conn = FdConn(proc.stdout.fileno(), proc.stdin.fileno())
    try:
        return send_hello(conn, **kwargs)
    finally:
        if kwargs.get("expect_ok", True):
            proc.terminate()
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=2.0)


def run_daemon_ping_test(env):
    proc = subprocess.Popen(
        [str(BIN), ":daemon:"],
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    daemon_socket_path = socket_path(env)
    daemon_exited = False
    try:
        wait_file(daemon_socket_path)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5.0)
            sock.connect(str(daemon_socket_path))
            send_hello(sock)
            send_frame(sock, PING, sessh_pb().DaemonTunnelItem.Ping().SerializeToString())
            message_type, payload = recv_frame(sock)
            if message_type != PONG:
                raise AssertionError(f"expected PONG from sesshd, got {message_type}")
            pong = sessh_pb().DaemonTunnelItem.Pong()
            pong.ParseFromString(payload)

        try:
            returncode = proc.wait(timeout=5.0)
            daemon_exited = True
        except subprocess.TimeoutExpired:
            raise AssertionError("sesshd did not exit after becoming idle")
        if returncode != 0:
            stderr = proc.stderr.read().decode("utf-8", "replace")
            raise AssertionError(f"sesshd exited with {returncode}: {stderr}")
        wait_missing(daemon_socket_path)
    finally:
        if not daemon_exited and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5.0)
        cleanup_runtime(env)


def run_daemon_concurrent_start_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-daemon-race-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        cleanup_runtime(env)
        procs = []
        daemon_socket_path = socket_path(env)
        try:
            for _ in range(6):
                procs.append(
                    subprocess.Popen(
                        [str(BIN), ":daemon:"],
                        cwd=ROOT,
                        env=env,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                )

            wait_file(daemon_socket_path)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(5.0)
                sock.connect(str(daemon_socket_path))
                send_hello(sock)
                send_frame(sock, PING, sessh_pb().DaemonTunnelItem.Ping().SerializeToString())
                message_type, _payload = recv_frame(sock)
                if message_type != PONG:
                    raise AssertionError(f"expected PONG from sesshd, got {message_type}")

            for proc in procs:
                try:
                    proc.wait(timeout=6.0)
                except subprocess.TimeoutExpired:
                    raise AssertionError("concurrent sesshd contender did not exit")

            if not any(proc.returncode == 0 for proc in procs):
                diagnostics = [proc.stderr.read().decode("utf-8", "replace") for proc in procs]
                raise AssertionError(f"no daemon contender exited cleanly: {diagnostics!r}")
            wait_missing(daemon_socket_path)
        finally:
            for proc in procs:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=2.0)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=2.0)
            cleanup_runtime(env)


def run_daemon_exits_after_stale_cleanup_record_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-cleanup-idle-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        procs_dir = state_root(env) / "procs"
        procs_dir.mkdir(parents=True, exist_ok=True)
        state_root(env).chmod(0o700)
        procs_dir.chmod(0o700)
        record_path = procs_dir / f"{test_session_guid(77)}.json"
        record_path.write_text(
            json.dumps(
                {
                    "local_pid": 99999999,
                    "local_start_time": "missing-local-process",
                    "remote_user": "user",
                    "remote_host": "host",
                    "remote_port": "22",
                    "remote_pid": 99999998,
                    "remote_start_time": "missing-remote-process",
                    "remote_socket_path": "/tmp/missing-sesshd.sock",
                }
            )
            + "\n"
        )
        old = time.time() - 9 * 24 * 60 * 60
        os.utime(record_path, (old, old))

        proc = None
        try:
            proc = start_daemon(env)
            proc.wait(timeout=5.0)
            if proc.returncode != 0:
                raise AssertionError(f"sesshd exited with {proc.returncode}")
            wait_missing(socket_path(env))
            if record_path.exists():
                raise AssertionError(f"stale cleanup record was not deleted: {record_path}")
        except subprocess.TimeoutExpired:
            raise AssertionError("sesshd did not exit after stale cleanup record was abandoned")
        finally:
            if proc is not None and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2.0)
            cleanup_runtime(env)


def run_daemon_log_stale_cleanup_record_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-cleanup-log-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        procs_dir = state_root(env) / "procs"
        procs_dir.mkdir(parents=True, exist_ok=True)
        state_root(env).chmod(0o700)
        procs_dir.chmod(0o700)
        guid = test_session_guid(78)
        record_path = procs_dir / f"{guid}.json"
        record_path.write_text(
            json.dumps(
                {
                    "local_pid": 99999999,
                    "local_start_time": "missing-local-process",
                    "remote_user": "user",
                    "remote_host": "host",
                    "remote_port": "22",
                    "remote_pid": 99999998,
                    "remote_start_time": "missing-remote-process",
                    "remote_socket_path": "/tmp/missing-sesshd.sock",
                }
            )
            + "\n"
        )
        old = time.time() - 9 * 24 * 60 * 60
        os.utime(record_path, (old, old))

        log_proc = None
        try:
            log_proc = subprocess.Popen(
                [str(BIN), "--daemon-log"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            output = read_until_pipe(log_proc.stdout, f"cleanup record expired guid={guid}".encode(), timeout=5.0)
            text = output.decode("utf-8", "replace")
            if f"cleanup record expired guid={guid}" not in text:
                raise AssertionError(f"daemon log missing stale cleanup deletion: {text!r}")
            wait_missing(record_path)
        finally:
            if log_proc is not None and log_proc.poll() is None:
                log_proc.terminate()
                try:
                    log_proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    log_proc.kill()
                    log_proc.wait(timeout=2.0)
            cleanup_runtime(env)


def run_daemon_log_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-daemon-log-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        cleanup_runtime(env)
        proc = start_daemon(env)
        log_proc = None
        try:
            log_proc = subprocess.Popen(
                [str(BIN), "--daemon-log"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            output = read_until_pipe(log_proc.stdout, b"daemon log subscribed")
            if b"daemon started socket=" in output:
                raise AssertionError(f"daemon log replayed old entries: {output!r}")

            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(5.0)
                sock.connect(str(socket_path(env)))
                send_hello(sock)
                send_frame(sock, PING, sessh_pb().DaemonTunnelItem.Ping().SerializeToString())
                message_type, _payload = recv_frame(sock)
                if message_type != PONG:
                    raise AssertionError(f"expected PONG from sesshd, got {message_type}")

            output += read_until_pipe(log_proc.stdout, b"client disconnected from daemon")
            output = output.decode("utf-8", "replace")
            lines = output.splitlines()
            if not lines or not lines[0].startswith("daemon socket "):
                raise AssertionError(f"daemon log missing socket preamble: {output!r}")
            if str(socket_path(env)) not in lines[0]:
                raise AssertionError(f"daemon log preamble has wrong socket: {lines[0]!r}")
            for line in lines[1:]:
                if not re.match(r"^\d{2}:\d{2}:\d{2}\.\d{3} ", line):
                    raise AssertionError(f"daemon log line has unreadable timestamp: {line!r}")
            for expected in (
                "daemon log subscribed",
                "client connected",
                "client hello completed",
                "client disconnected from daemon",
            ):
                if expected not in output:
                    raise AssertionError(f"daemon log missing {expected!r}: {output!r}")
            for noisy in ("frame received", "poll tick"):
                if noisy in output:
                    raise AssertionError(f"daemon log contains trace-level noise {noisy!r}: {output!r}")
        finally:
            if log_proc is not None and log_proc.poll() is None:
                log_proc.terminate()
                try:
                    log_proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    log_proc.kill()
                    log_proc.wait(timeout=2.0)
            proc.terminate()
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5.0)
            cleanup_runtime(env)


def run_daemon_log_namespace_env_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-daemon-log-namespace-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        cleanup_runtime(env)
        namespace = "debug.remote.ns"
        expected_socket = socket_path_for_dir(env, namespace)
        log_env = env.copy()
        log_env["SESSH_DAEMON_NAMESPACE"] = namespace
        log_proc = subprocess.Popen(
            [str(BIN), "--daemon-log"],
            cwd=ROOT,
            env=log_env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            output = read_until_pipe(log_proc.stdout, b"daemon log subscribed")
            lines = output.decode("utf-8", "replace").splitlines()
            if not lines or lines[0] != f"daemon socket {expected_socket}":
                raise AssertionError(f"daemon log namespace override used wrong socket: {output!r}")
            wait_file(expected_socket)
        finally:
            if log_proc.poll() is None:
                log_proc.terminate()
                try:
                    log_proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    log_proc.kill()
                    log_proc.wait(timeout=2.0)
            cleanup_runtime(env)


def run_daemon_log_session_lifecycle_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-daemon-log-session-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "log-session-shell"
        shell.write_text("#!/bin/sh\nprintf 'DAEMON_LOG_SESSION_READY\\n'\n")
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        proc = start_daemon(env)
        log_proc = None
        conn = None
        try:
            log_proc = subprocess.Popen(
                [str(BIN), "--daemon-log"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            output = read_until_pipe(log_proc.stdout, b"daemon log subscribed")

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            conn.connect(str(socket_path(env)))
            send_hello(conn)
            send_frame(conn, SESSION_CREATE, pack_session_create(shell))
            recv_until_message(conn, SESSION_ATTACHED)
            recv_until_message(conn, SESSION_ENDED)

            output += read_until_pipe(log_proc.stdout, b"terminal stream remote connected", timeout=5.0)
            text = output.decode("utf-8", "replace")
            for expected in (
                "terminal stream opening session=",
                "action=create",
                "terminal session creating session=",
                "terminal runtime connected session=",
                "isolation_mode=process",
                "terminal stream remote connected session=",
            ):
                if expected not in text:
                    raise AssertionError(f"daemon log missing {expected!r}: {text!r}")
        finally:
            if conn is not None:
                conn.close()
            if log_proc is not None and log_proc.poll() is None:
                log_proc.terminate()
                try:
                    log_proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    log_proc.kill()
                    log_proc.wait(timeout=2.0)
            proc.terminate()
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5.0)
            cleanup_runtime(env)


def run_daemon_log_mux_session_lifecycle_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-daemon-log-mux-session-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "log-mux-session-shell"
        shell.write_text("#!/bin/sh\nprintf 'DAEMON_LOG_MUX_SESSION_READY\\n'\n")
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        session_id = test_session_guid(77)
        cleanup_runtime(env)
        proc = start_daemon(env)
        log_proc = None
        conn = None
        try:
            log_proc = subprocess.Popen(
                [str(BIN), "--daemon-log"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            output = read_until_pipe(log_proc.stdout, b"daemon log subscribed")

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            conn.connect(str(socket_path(env)))
            send_hello(conn)
            send_mux_te_open(conn, shell, stream_id=1, session_id=session_id)
            while recv_mux_frame(conn).WhichOneof("message") != "open_ok":
                pass
            recv_mux_te_payload(conn, "session_attached")
            ended_mux = recv_mux_te_payload_frame(conn, "session_ended")
            recv_mux_eof(conn, stream_id=1, expected_final_offset=ended_mux.payload.offset + 1)

            output += read_until_pipe(log_proc.stdout, b"terminal session ended stream_id=1", timeout=5.0)
            text = output.decode("utf-8", "replace")
            for expected in (
                f"terminal mux stream opening stream_id=1 session={session_id} action=create",
                f"terminal mux remote payload prepared stream_id=1 session={session_id} action=create",
                f"terminal session creating session={session_id}",
                f"terminal runtime connected session={session_id} isolation_mode=process",
                f"terminal mux remote open queued stream_id=1 session={session_id} action=create",
                f"terminal mux stream open ok stream_id=1 session={session_id} action=create",
                f"terminal session attached stream_id=1 session={session_id}",
                f"terminal session ended stream_id=1 session={session_id}",
            ):
                if expected not in text:
                    raise AssertionError(f"daemon log missing {expected!r}: {text!r}")
        finally:
            if conn is not None:
                conn.close()
            if log_proc is not None and log_proc.poll() is None:
                log_proc.terminate()
                try:
                    log_proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    log_proc.kill()
                    log_proc.wait(timeout=2.0)
            proc.terminate()
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5.0)
            cleanup_runtime(env)


def run_daemon_log_mux_session_in_daemon_runtime_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-daemon-log-mux-in-daemon-session-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "log-mux-in-daemon-session-shell"
        shell.write_text("#!/bin/sh\nprintf 'DAEMON_LOG_MUX_IN_DAEMON_SESSION_READY\\n'\n")
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        session_id = test_session_guid(78)
        cleanup_runtime(env)
        proc = start_daemon(env)
        log_proc = None
        conn = None
        try:
            log_proc = subprocess.Popen(
                [str(BIN), "--daemon-log"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            output = read_until_pipe(log_proc.stdout, b"daemon log subscribed")

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            conn.connect(str(socket_path(env)))
            send_hello(conn)
            isolation_mode = sessh_pb().ISOLATION_MODE_NONE
            send_mux_te_open(conn, shell, stream_id=1, session_id=session_id, isolation_mode=isolation_mode)
            while recv_mux_frame(conn).WhichOneof("message") != "open_ok":
                pass
            recv_mux_te_payload(conn, "session_attached")
            ended_mux = recv_mux_te_payload_frame(conn, "session_ended")
            recv_mux_eof(conn, stream_id=1, expected_final_offset=ended_mux.payload.offset + 1)

            output += read_until_pipe(log_proc.stdout, b"terminal session ended stream_id=1", timeout=5.0)
            text = output.decode("utf-8", "replace")
            for expected in (
                f"terminal mux stream opening stream_id=1 session={session_id} action=create",
                f"terminal runtime connected session={session_id} isolation_mode=none",
                f"terminal mux stream open ok stream_id=1 session={session_id} action=create",
                f"terminal session attached stream_id=1 session={session_id}",
                f"terminal session ended stream_id=1 session={session_id}",
            ):
                if expected not in text:
                    raise AssertionError(f"daemon log missing {expected!r}: {text!r}")
            if "isolation_mode=process" in text or "terminal remote process connected" in text:
                raise AssertionError(f"daemon runtime test used child process path: {text!r}")
        finally:
            if conn is not None:
                conn.close()
            if log_proc is not None and log_proc.poll() is None:
                log_proc.terminate()
                try:
                    log_proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    log_proc.kill()
                    log_proc.wait(timeout=2.0)
            proc.terminate()
            try:
                proc.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5.0)
            cleanup_runtime(env)

