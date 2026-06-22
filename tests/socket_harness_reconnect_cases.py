from socket_harness_common import *
from socket_harness_daemon_cases import *
from socket_harness_protocol_cases import *

def write_reconnect_gap_shell(path, before_count, during_count):
    path.write_text(
        "#!/bin/sh\n"
        "printf 'READY$ '\n"
        "while IFS= read -r line; do\n"
        "  case \"$line\" in\n"
        "    go)\n"
        f"      i=1; while [ \"$i\" -le {before_count} ]; do printf 'before_%02d\\n' \"$i\"; i=$((i + 1)); done\n"
        "      printf 'BEFORE_DONE\\n'\n"
        "      sleep 0.3\n"
        f"      i=1; while [ \"$i\" -le {during_count} ]; do printf 'during_%02d\\n' \"$i\"; i=$((i + 1)); done\n"
        "      printf 'DURING_DONE$ '\n"
        "      ;;\n"
        "    *)\n"
        "      printf 'POST:%s\\n' \"$line\"\n"
        "      ;;\n"
        "  esac\n"
        "done\n"
    )
    path.chmod(0o700)


def start_gap_session(env, shell, scrollback_limit):
    start_daemon(env)
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(5.0)
    conn.connect(str(socket_path(env)))
    send_hello(conn)
    send_resize(conn, 3, 40)
    create_and_open_session(conn, shell, scrollback=scrollback_limit)
    message_type, payload = recv_frame(conn)
    if message_type != SESSION_READY:
        raise AssertionError(f"expected SESSION_READY, got {message_type}")
    assert_session_ready(payload)
    return conn


def open_gap_session(env, reconnect_cursor=None):
    reopened = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    reopened.settimeout(5.0)
    reopened.connect(str(socket_path(env)))
    send_hello(reopened)
    send_resize(reopened, 3, 40)
    send_frame(
        reopened,
        SESSION_OPEN,
        pack_session_open(
            session_guid=test_session_guid(1),
            reconnect_cursor=reconnect_cursor,
        ),
    )
    message_type, _ = recv_frame(reopened)
    if message_type != SESSION_READY:
        raise AssertionError(f"expected SESSION_READY, got {message_type}")
    return reopened


def run_reconnect_scrollback_gap_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-reconnect-gap-complete-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "gap-complete-shell"
        write_reconnect_gap_shell(shell, before_count=3, during_count=4)
        cleanup_runtime(env)
        try:
            conn = start_gap_session(env, shell, scrollback_limit=50)
            try:
                recv_draw_until(conn, b"READY$ ")
                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, before_draws = recv_draw_until(conn, b"BEFORE_DONE")
                cursor = (before_draws[-1]["epoch"], before_draws[-1]["scrollback_cursor"])
            finally:
                conn.close()

            time.sleep(0.6)

            reopened = open_gap_session(env, reconnect_cursor=cursor)
            try:
                _, reconnect_draws = recv_draw_until(reopened, b"DURING_DONE$ ")
                output = b"".join(draw["draw_bytes"] for draw in reconnect_draws)
                if b"sessh scrollback truncated" in output:
                    raise AssertionError(f"unexpected truncation marker without truncation: {output!r}")
                for i in range(1, 5):
                    needle = f"during_{i:02d}".encode()
                    if needle not in output:
                        raise AssertionError(f"missing reconnect output {needle!r}: {output!r}")
            finally:
                reopened.close()
        finally:
            cleanup_runtime(env)

    with tempfile.TemporaryDirectory(prefix="sessh-reconnect-gap-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "gap-shell"
        write_reconnect_gap_shell(shell, before_count=4, during_count=20)
        cleanup_runtime(env)
        try:
            conn = start_gap_session(env, shell, scrollback_limit=5)
            try:
                recv_draw_until(conn, b"READY$ ")
                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, before_draws = recv_draw_until(conn, b"BEFORE_DONE")
                cursor = (before_draws[-1]["epoch"], before_draws[-1]["scrollback_cursor"])
            finally:
                conn.close()

            time.sleep(0.8)

            reopened = open_gap_session(env, reconnect_cursor=cursor)
            try:
                _, reconnect_draws = recv_draw_until(reopened, b"DURING_DONE$ ")
                output = b"".join(draw["draw_bytes"] for draw in reconnect_draws)
                # With a 3-row PTY and this output shape, the client saw three
                # retained rows before disconnect and the retained snapshot now
                # starts fifteen rows after that cursor.
                if b"--- sessh scrollback truncated: 15 lines ---" not in output:
                    raise AssertionError(f"missing reconnect truncation marker: {output!r}")
                if b"during_01" in output:
                    raise AssertionError(f"truncated reconnect replayed missing early output: {output!r}")
                if b"during_14" not in output or b"during_20" not in output:
                    raise AssertionError(f"reconnect did not include retained and visible output: {output!r}")

                send_frame(reopened, INPUT, pack_bytes(b"after\n"))
                _, post_draws = recv_draw_until(reopened, b"POST:after")
                post_output = b"".join(draw["draw_bytes"] for draw in post_draws)
                if b"POST:after" not in post_output:
                    raise AssertionError(f"post-reconnect input was not delivered: {post_output!r}")
            finally:
                reopened.close()
        finally:
            cleanup_runtime(env)


def run_resize_epoch_does_not_clear_reconnect_scrollback_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-resize-epoch-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "resize-epoch-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'READY$ '\n"
            "while IFS= read -r line; do\n"
            "  i=1\n"
            "  while [ \"$i\" -le 10 ]; do\n"
            "    printf 'resize_history_%02d\\n' \"$i\"\n"
            "    i=$((i + 1))\n"
            "  done\n"
            "  printf 'AFTER$ '\n"
            "done\n"
        )
        shell.chmod(0o700)
        cleanup_runtime(env)
        try:
            start_daemon(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, 3, 40)
                create_and_open_session(conn, shell, scrollback=20)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                recv_draw_until(conn, b"READY$ ")
                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, before_draws = recv_draw_until(conn, b"AFTER$ ")
                cursor = (before_draws[-1]["epoch"], before_draws[-1]["scrollback_cursor"])

                send_resize(conn, 3, 20, repaint=(1, cursor[0], cursor[1]), viewport_offset=-1)
                response_id, resize_repaint = recv_repaint_response(conn)
                if response_id != 1:
                    raise AssertionError(f"unexpected resize repaint seq: {response_id}")
                if resize_repaint["viewport_offset"] != 0:
                    raise AssertionError(f"resize repaint did not realign unknown viewport: {resize_repaint!r}")
                if resize_repaint["epoch"] == cursor[0]:
                    raise AssertionError(f"resize repaint did not bump scrollback epoch: {resize_repaint!r}")
                if resize_repaint["scrollback_cursor"] == 0:
                    raise AssertionError(f"resize repaint did not return a usable cursor: {resize_repaint!r}")
            finally:
                conn.close()

            reopened = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            reopened.settimeout(5.0)
            try:
                reopened.connect(str(socket_path(env)))
                send_hello(reopened)
                send_resize(reopened, 3, 20)
                send_frame(
                    reopened,
                    SESSION_OPEN,
                    pack_session_open(
                        session_guid=test_session_guid(1),
                        reconnect_cursor=cursor,
                    ),
                )

                message_type, _ = recv_frame(reopened)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")

                _, reconnect_draws = recv_draw_until(reopened, b"AFTER$ ")
                output = b"".join(draw["draw_bytes"] for draw in reconnect_draws)
                if b"\x1b[3J" in output:
                    raise AssertionError(f"resize epoch bump cleared outer scrollback: {output!r}")
                if any(draw["epoch"] != resize_repaint["epoch"] for draw in reconnect_draws):
                    raise AssertionError(f"reconnect did not use resize epoch: {reconnect_draws!r}")
                if b"resize_history_01" not in output:
                    raise AssertionError(f"reconnect did not include retained scrollback after resize: {output!r}")
            finally:
                reopened.close()
        finally:
            cleanup_runtime(env)


def run_screen_repaint_after_presentation_reset_clears_rows_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-screen-repaint-reset-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "screen-repaint-reset-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'OK\\r\\n'\n"
            "sleep 30\n"
        )
        shell.chmod(0o700)
        cleanup_runtime(env)
        try:
            start_daemon(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, 3, 40)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)
                recv_draw_until(conn, b"OK")

                send_resize_screen_repaint(conn, 3, 40, 77)
                response_id, repaint = recv_repaint_response(conn)
                if response_id != 77:
                    raise AssertionError(f"unexpected screen repaint seq: {response_id}")
                output = repaint["draw_bytes"]
                if b"\x1b[2K\x1b[0mOK" not in output:
                    raise AssertionError(f"screen repaint did not clear row before redrawing short content: {output!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_terminal_remote_crash_client_error_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-terminal-remote-crash-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "crash-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf '\\033[6 qREADY$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033[?1049h\\033[?1000;1004;1006;2004hCRASH_UI_READY'\n"
            "  sleep 60\n"
            "done\n"
        )
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        pid, fd = spawn_client(env, [])
        child_closed = False
        try:
            output = read_until(fd, b"READY$ ")
            os.write(fd, b"go\n")
            output += read_until(fd, b"CRASH_UI_READY")
            pids = terminal_remote_pids(env)
            if len(pids) != 1:
                raise AssertionError(f"expected one terminal process, found {pids}")

            os.kill(pids[0], signal.SIGKILL)
            output += read_until(fd, b"sessh: ssh remote session failed", timeout=5.0)
            if b"ssh remote session failed" not in output:
                raise AssertionError(output)
            alt_leave = output.rfind(b"\x1b[?1049l")
            if alt_leave < 0:
                raise AssertionError(f"terminal remote crash did not leave alternate screen: {output!r}")
            final_cleanup = output[alt_leave:]
            for seq in (b"\x1b[?1000l", b"\x1b[?1006l", b"\x1b[?1004l", b"\x1b[?2004l", b"\x1b[0 q"):
                if seq not in final_cleanup:
                    raise AssertionError(f"missing final cleanup sequence {seq!r} after alternate-screen leave: {final_cleanup!r}")

            status = wait_child_draining_fd(pid, fd)
            if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 1:
                raise AssertionError(f"expected client exit status 1, got wait status {status}")
            os.close(fd)
            child_closed = True
        finally:
            if not child_closed:
                close_client(pid, fd)
            cleanup_runtime(env)


def run_bridge_starts_daemon_session_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-bridge-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "bridge-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'BROKER_READY\\n'\n"
            "while IFS= read -r line; do\n"
            "  if [ \"$line\" = exit ]; then exit 0; fi\n"
            "  printf 'BROKER:%s\\n' \"$line\"\n"
            "done\n"
        )
        shell.chmod(0o700)

        proc = subprocess.Popen(
            [str(BIN), ":bridge:"],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        conn = FdConn(proc.stdout.fileno(), proc.stdin.fileno())
        try:
            send_hello(conn)
            send_resize(conn, rows=4, cols=40)
            create_and_open_session(conn, shell)
            message_type, payload = recv_frame(conn)
            if message_type != SESSION_READY:
                raise AssertionError(f"expected SESSION_READY, got {message_type}")
            assert_session_ready(payload)
            recv_draw_until(conn, b"BROKER_READY")

            assert_runtime_dir_symlink(env, Path(env["XDG_RUNTIME_DIR"]))

            send_frame(conn, INPUT, pack_bytes(b"exit\n"))
            recv_until_message(conn, SESSION_ENDED)
            proc.stdin.close()
            proc.wait(timeout=5.0)
            if proc.returncode != 0:
                raise AssertionError(proc.stderr.read().decode("utf-8", "replace"))
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2.0)


def spawn_bin(env, args):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(env)
        os.execv(str(BIN), [str(BIN), *args])
    return pid, fd


def spawn_client(env, extra_args=None):
    extra_args = extra_args or []
    return spawn_bin(env, ["new", *extra_args, "."])


def close_client(pid, fd):
    try:
        wait_child(pid, timeout=0.25)
        os.close(fd)
        return
    except AssertionError:
        pass

    try:
        os.close(fd)
    except OSError:
        pass
    wait_child(pid)


def run_initial_kitty_keyboard_restore_test(tmp_root):
    global kitty_keyboard_status_response

    env = isolated_env(Path(tmp_root) / "kitty-keyboard-restore")
    env["SHELL"] = "/bin/sh"
    cleanup_runtime(env)

    previous_response = kitty_keyboard_status_response
    kitty_keyboard_status_response = b"\x1b[?7u"
    try:
        pid, fd = spawn_client(env, [])
        try:
            read_until(fd, b"$ ")
            send_escape_close(fd)
            output = read_until(fd, b"\x1b[=7u")
            output += read_available(fd, timeout=0.5)
            if b"\x1b[=7u" not in output:
                raise AssertionError(f"missing kitty keyboard restore sequence: {output!r}")
            if b"\x1b[=0u" in output:
                raise AssertionError(f"restored default kitty keyboard flags instead of initial flags: {output!r}")
        finally:
            close_client(pid, fd)
    finally:
        kitty_keyboard_status_response = previous_response
        cleanup_runtime(env)
