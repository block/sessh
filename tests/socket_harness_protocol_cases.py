from socket_harness_common import *
from socket_harness_daemon_cases import *

def run_minor_version_compatibility_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-minor-compat-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        cleanup_runtime(env)
        try:
            proc = start_daemon(env)

            newer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            newer.settimeout(5.0)
            try:
                newer.connect(str(socket_path(env)))
                send_hello(newer, minor_delta=1)
            finally:
                newer.close()

            different_version = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            different_version.settimeout(5.0)
            try:
                different_version.connect(str(socket_path(env)))
                send_hello(different_version, version_override="0.0.0-compatible-test")
            finally:
                different_version.close()

            newer_major = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            newer_major.settimeout(5.0)
            try:
                newer_major.connect(str(socket_path(env)))
                send_hello(newer_major, major_delta=1)
            finally:
                newer_major.close()

            older_major = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            older_major.settimeout(5.0)
            try:
                older_major.connect(str(socket_path(env)))
                send_hello(older_major, major_delta=-1, expect_ok=False)
            finally:
                older_major.close()

            bridge_hello(env, minor_delta=1)
            bridge_hello(env, version_override="0.0.0-compatible-test")
            bridge_hello(env, major_delta=1)
            bridge_hello(env, major_delta=-1, expect_ok=False)
        finally:
            if "proc" in locals() and proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)
            cleanup_runtime(env)


def run_live_draw_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-screen-patch-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "patch-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033[1;31;44mPATCH_MARKER\\033[0m\\n'\n"
            "  printf '\\033]8;;https://example.test/\\033\\\\PATCH_LINK\\033]8;;\\033\\\\\\n'\n"
            "  sleep 1\n"
            "  exit 0\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                draw, draws = recv_draw_until(conn, b"PATCH_LINK")
                output = b"".join(draw["draw_bytes"] for draw in draws)
                if b"PATCH_MARKER" not in output:
                    raise AssertionError(f"live DRAW did not include updated text: {output!r}")
                for seq in (b"\x1b[1m", b"\x1b[31m", b"\x1b[44m"):
                    if seq not in output:
                        raise AssertionError(f"missing style sequence {seq!r}: {output!r}")
                if b"\x1b]8;;https://example.test/\x1b\\" not in output:
                    raise AssertionError(f"missing hyperlink sequence: {output!r}")
                if not draw["draw_bytes"].startswith(SYNCHRONIZED_UPDATE_START):
                    raise AssertionError(f"generated draw was not synchronized: {draw!r}")
                if not draw["draw_bytes"].endswith(SYNCHRONIZED_UPDATE_END):
                    raise AssertionError(f"generated draw did not end synchronized update: {draw!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_synchronized_output_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-sync-output-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "sync-output-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033[?2026hSYNC_PARTIAL'\n"
            "  sleep 1\n"
            "  printf '_READY\\033[?2026l\\n'\n"
            "  sleep 1\n"
            "  exit 0\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                try:
                    early = recv_draw(conn, timeout=0.2)
                except (TimeoutError, socket.timeout):
                    early = None
                if early is not None and b"SYNC_PARTIAL" in early["draw_bytes"]:
                    raise AssertionError(f"synchronized output leaked before end marker: {early!r}")
                draw, _ = recv_draw_until(conn, b"SYNC_PARTIAL_READY")
                output = draw["draw_bytes"]
                if output.count(SYNCHRONIZED_UPDATE_START) != 1 or output.count(SYNCHRONIZED_UPDATE_END) != 1:
                    raise AssertionError(f"expected one synchronized draw wrapper: {output!r}")
                if not output.startswith(SYNCHRONIZED_UPDATE_START) or not output.endswith(SYNCHRONIZED_UPDATE_END):
                    raise AssertionError(f"synchronized wrapper did not cover full draw: {output!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_input_ack_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-input-ack-protocol-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "input-ack-shell"
        shell.write_text("#!/bin/sh\nwhile IFS= read -r line; do printf 'ACK:%s\\n' \"$line\"; done\n")
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        try:
            start_daemon(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                send_frame(conn, INPUT, pack_input(b"go\n", input_seq=7))
                response = recv_until_message(conn, INPUT_ACK)
                if parse_input_ack(response) != 7:
                    raise AssertionError(f"unexpected input ack: {response!r}")
                recv_draw_until(conn, b"ACK:go")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_session_ended_payload_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-session-ended-exit-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "exit-status-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'EXIT_READY\\n'\n"
            "while IFS= read -r line; do\n"
            "  [ \"$line\" = exit ] && exit 7\n"
            "done\n"
        )
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        conn = None
        proc = None
        try:
            proc = start_daemon(env)
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            conn.connect(str(socket_path(env)))
            send_hello(conn)
            send_resize(conn)
            create_and_open_session(conn, shell)
            message_kind, payload = recv_frame(conn)
            if message_kind != SESSION_READY:
                raise AssertionError(f"expected SESSION_READY, got {message_kind}")
            assert_session_ready(payload)
            recv_draw_until(conn, b"EXIT_READY")
            send_frame(conn, INPUT, pack_bytes(b"exit\n"))

            ended = parse_session_ended(recv_until_message(conn, SESSION_ENDED))
            pb = sessh_pb()
            if ended.reason != pb.TerminalEmulatorItem.SessionEnded.REASON_PROCESS_EXITED:
                raise AssertionError(f"unexpected process-exit reason: {ended!r}")
            if not ended.HasField("exit_status"):
                raise AssertionError(f"missing process exit status: {ended!r}")
            if (
                ended.exit_status.kind != pb.TerminalEmulatorItem.SessionEnded.ExitStatus.KIND_EXITED
                or ended.exit_status.status != 7
            ):
                raise AssertionError(f"unexpected process exit status: {ended!r}")
            if not ended.HasField("ended_at_unix_ms"):
                raise AssertionError(f"missing end timestamp: {ended!r}")
        finally:
            if conn is not None:
                conn.close()
            if proc is not None and proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)
            cleanup_runtime(env)


def run_mux_terminal_session_end_uses_eof_not_reset_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-mux-terminal-eof-not-reset-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "mux-terminal-eof-shell"
        shell.write_text("#!/bin/sh\nprintf 'MUX_TERMINAL_EOF_READY\\n'\n")
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        conn = None
        proc = None
        try:
            proc = start_daemon(env)
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            conn.connect(str(socket_path(env)))
            send_hello(conn)
            send_mux_te_open(conn, shell, stream_id=1, session_id=test_session_guid(83))
            while recv_mux_frame(conn).WhichOneof("message") != "open_ok":
                pass
            recv_mux_session_ended_then_eof_without_reset(conn, stream_id=1)
        finally:
            if conn is not None:
                conn.close()
            if proc is not None and proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)
            cleanup_runtime(env)


def run_plain_scroll_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-plain-scroll-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "plain-scroll-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "stty -echo\n"
            "printf 'SCROLL_READY$ '\n"
            "while IFS= read -r line; do\n"
            "  i=1\n"
            "  while [ \"$i\" -le 40 ]; do\n"
            "    printf 'plain_%02d\\r\\n' \"$i\"\n"
            "    i=$((i + 1))\n"
            "  done\n"
            "  printf 'SCROLL_DONE$ '\n"
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
                send_resize(conn, rows=10, cols=80)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                recv_draw_until(conn, b"SCROLL_READY$ ")
                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, draws = recv_draw_until(conn, b"SCROLL_DONE$ ")
                scroll_draws = [draw for draw in draws if draw["scrollback_cursor"] > 0]
                if not scroll_draws:
                    raise AssertionError(f"expected scrollback_cursor in DRAWs: {draws!r}")
                output = b"".join(draw["draw_bytes"] for draw in draws)
                if b"plain_40" not in output or b"SCROLL_DONE$ " not in output:
                    raise AssertionError(f"plain scroll output missing expected text: {draws!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_plain_screen_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-plain-screen-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "plain-screen-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "stty -echo\n"
            "printf 'SCREEN_READY$ '\n"
            "while IFS= read -r line; do\n"
            "  i=1\n"
            "  while [ \"$i\" -le 5 ]; do\n"
            "    printf 'screen plain %02d\\r\\n' \"$i\"\n"
            "    i=$((i + 1))\n"
            "  done\n"
            "  printf 'SCREEN_DONE$ '\n"
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
                send_resize(conn, rows=24, cols=80)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                recv_draw_until(conn, b"SCREEN_READY$ ")
                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, draws = recv_draw_until(conn, b"SCREEN_DONE$ ")
                output = b"".join(draw["draw_bytes"] for draw in draws)
                if b"screen plain 05" not in output:
                    raise AssertionError(f"missing plain output: {draws!r}")
                if any(draw["scrollback_cursor"] != 0 for draw in draws):
                    raise AssertionError(f"screen-only output should not report scrollback: {draws!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_split_escape_tail_is_not_replayed_as_text_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-split-escape-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "split-escape-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "stty -echo\n"
            "printf 'SPLIT_READY$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033['\n"
            "  sleep 0.2\n"
            "  printf '0mSPLIT_TEXT\\r\\nSPLIT_DONE$ '\n"
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
                send_resize(conn, rows=24, cols=80)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                recv_draw_until(conn, b"SPLIT_READY$ ")
                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, draws = recv_draw_until(conn, b"SPLIT_DONE$ ")
                if not any(b"SPLIT_TEXT" in draw["draw_bytes"] for draw in draws):
                    raise AssertionError(f"missing split output: {draws!r}")
                for draw in draws:
                    if draw["draw_bytes"].startswith(b"0mSPLIT_TEXT"):
                        raise AssertionError(f"split escape tail was replayed as text: {draws!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_active_screen_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-active-screen-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "active-screen-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'ALT_READY$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033[?1049hALT_SCREEN'\n"
            "  sleep 1\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                draw, draws = recv_draw_until(conn, b"ALT_SCREEN")
                output = b"".join(item["draw_bytes"] for item in draws)
                if b"\x1b[?1049h" not in output:
                    raise AssertionError(f"DRAW should enter outer alternate screen: {draws!r}")
                if b"\x1b[?1049l" in output:
                    raise AssertionError(f"DRAW should not leave outer alternate screen immediately: {draws!r}")
                restore = draw["visible_client_end_restore_bytes"]
                if restore is None or b"\x1b[?1049l" not in restore:
                    raise AssertionError(f"DRAW should include alternate-screen cleanup: {draw!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_active_screen_barrier_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-active-screen-barrier-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "active-screen-barrier-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'BARRIER_READY$ '\n"
            "while IFS= read -r line; do\n"
            "  printf 'PRIMARY_BEFORE\\033[?1049hALT_BEFORE\\033[?1049lPRIMARY_AFTER'\n"
            "  sleep 1\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                recv_draw_until(conn, b"BARRIER_READY$ ")
                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, draws = recv_draw_until(conn, b"PRIMARY_AFTER")
                output = b"".join(item["draw_bytes"] for item in draws)
                enter = output.index(b"\x1b[?1049h")
                leave = output.index(b"\x1b[?1049l")
                primary_before = output.index(b"PRIMARY_BEFORE")
                alt_before = output.index(b"ALT_BEFORE")
                primary_after = output.rindex(b"PRIMARY_AFTER")
                if not (primary_before < enter < alt_before < leave < primary_after):
                    raise AssertionError(f"alternate-screen barriers were not ordered: {output!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_terminal_modes_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-terminal-remote-modes-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "terminal-modes-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033[?1;1000;1004;1006;2004h\\033[>7uMODES_READY'\n"
            "  sleep 1\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                draw, draws = recv_draw_until(conn, b"MODES_READY")
                output = b"".join(item["draw_bytes"] for item in draws)
                for seq in (b"\x1b[?1h", b"\x1b[?1000h", b"\x1b[?1006h", b"\x1b[?1004h", b"\x1b[?2004h", b"\x1b[=7u"):
                    if seq not in output:
                        raise AssertionError(f"missing terminal mode sequence {seq!r}: {output!r}, last={draw!r}")
                if b"\x1b[6n" in output:
                    raise AssertionError(f"mouse mode should not require a cursor-position query: {output!r}")
                ready_index = output.index(b"MODES_READY")
                for seq in (b"\x1b[?1000h", b"\x1b[?1006h"):
                    if output.index(seq) < ready_index:
                        raise AssertionError(f"mouse reporting was enabled before viewport redraw: {output!r}")
                for enabled, disabled in (
                    (b"\x1b[?1000h", b"\x1b[?1000l"),
                    (b"\x1b[?1006h", b"\x1b[?1006l"),
                    (b"\x1b[?1h", b"\x1b[?1l"),
                    (b"\x1b[?1004h", b"\x1b[?1004l"),
                    (b"\x1b[?2004h", b"\x1b[?2004l"),
                    (b"\x1b[=7u", b"\x1b[=0u"),
                ):
                    if output.rfind(disabled) > output.rfind(enabled):
                        raise AssertionError(f"terminal mode was disabled by DRAW cleanup: {output!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_cursor_shape_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-cursor-shape-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "cursor-shape-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "stty -echo\n"
            "printf '\\033]2;cursor-shape-ready\\033\\\\'\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033[6 q'\n"
            "  sleep 1\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                recv_draw_until(conn, b"\x1b]2;cursor-shape-ready\x1b\\")
                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                draw, draws = recv_draw_until(conn, b"\x1b[6 q")
                if b"\x1b[6 q" not in b"".join(item["draw_bytes"] for item in draws):
                    raise AssertionError(f"missing cursor shape DRAW: {draw!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_state_only_client_render_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-state-only-client-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "state-only-client-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "stty -echo\n"
            "printf '\\033]2;state-only-client-ready\\033\\\\'\n"
            "while IFS= read -r line; do\n"
            "  case \"$line\" in\n"
            "    insert) printf '\\033[6 q' ;;\n"
            "    normal) printf '\\033[2 q' ;;\n"
            "    hide) printf '\\033[?25l' ;;\n"
            "    show) printf '\\033[?25h' ;;\n"
            "    appcursor) printf '\\033[?1h' ;;\n"
            "    normalcursor) printf '\\033[?1l' ;;\n"
            "    bracketed) printf '\\033[?2004h' ;;\n"
            "    plainpaste) printf '\\033[?2004l' ;;\n"
            "    exit) exit 0 ;;\n"
            "  esac\n"
            "done\n"
        )
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        pid, fd = spawn_client(env, [])
        try:
            read_until(fd, b"\x1b]2;state-only-client-ready\x1b\\", timeout=5.0)
            os.write(fd, b"insert\n")
            read_until(fd, b"\x1b[6 q", timeout=5.0)
            os.write(fd, b"normal\n")
            read_until(fd, b"\x1b[2 q", timeout=5.0)
            os.write(fd, b"hide\n")
            read_until(fd, b"\x1b[?25l", timeout=5.0)
            os.write(fd, b"show\n")
            read_until(fd, b"\x1b[?25h", timeout=5.0)
            os.write(fd, b"appcursor\n")
            read_until(fd, b"\x1b[?1h", timeout=5.0)
            os.write(fd, b"normalcursor\n")
            read_until(fd, b"\x1b[?1l", timeout=5.0)
            os.write(fd, b"bracketed\n")
            read_until(fd, b"\x1b[?2004h", timeout=5.0)
            os.write(fd, b"plainpaste\n")
            read_until(fd, b"\x1b[?2004l", timeout=5.0)
            os.write(fd, b"exit\n")
        finally:
            close_client(pid, fd)
            cleanup_runtime(env)


def run_display_clear_not_forwarded_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-display-clear-client-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "display-clear-client-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "stty -echo\n"
            "printf '\\033]2;display-clear-client-ready\\033\\\\'\n"
            "printf 'CLEAR_TOP\\nCLEAR$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '\\r\\r\\033[A\\033[J'\n"
            "  printf 'CLEAR_TOP\\nCLEAR$ '\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "done\n"
        )
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        pid, fd = spawn_client(env, [])
        try:
            read_until(fd, b"CLEAR$ ", timeout=5.0)
            read_available(fd)

            os.write(fd, b"go\n")
            output = read_until(fd, b"CLEAR$ ", timeout=5.0)
            output += read_available(fd)
            forbidden = [b"\x1b[J", b"\x1b[0J", b"\x1b[1J", b"\x1b[2J"]
            for seq in forbidden:
                if seq in output:
                    raise AssertionError(f"display clear leaked to outer terminal: {output!r}")

            os.write(fd, b"exit\n")
        finally:
            close_client(pid, fd)
            cleanup_runtime(env)


def run_complete_display_clear_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-complete-display-clear-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "complete-display-clear-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'READY$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033[2J\\033[HAFTER_FULL_CLEAR$ '\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)
                recv_draw_until(conn, b"READY$ ")

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                draw, _ = recv_draw_until(conn, b"AFTER_FULL_CLEAR$")
                output = draw["draw_bytes"]
                if not synchronized_draw_body(output).startswith(b"\x1b[2J\x1b[1;1H"):
                    raise AssertionError(f"complete display clear did not clear physical screen first: {output!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_title_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-title-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "title-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033]2;sessh-title-live\\033\\\\TITLE_READY'\n"
            "  sleep 1\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                recv_draw_until(conn, b"\x1b]2;sessh-title-live\x1b\\")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_default_colors_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-default-colors-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "default-colors-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "count=0\n"
            "while IFS= read -r line; do\n"
            "  count=$((count + 1))\n"
            "  if [ \"$count\" -eq 1 ]; then\n"
            "    printf '\\033]10;rgb:01/02/03\\033\\\\\\033]11;rgb:04/05/06\\033\\\\COLOR_READY'\n"
            "  else\n"
            "    printf '\\033]110\\033\\\\\\033]111\\033\\\\RESET_READY'\n"
            "    sleep 1\n"
            "    exit 0\n"
            "  fi\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                send_frame(conn, INPUT, pack_bytes(b"set\n"))
                draw, _ = recv_draw_until(conn, b"COLOR_READY")
                if b"\x1b]10;rgb:01/02/03\x1b\\" not in draw["draw_bytes"] or b"\x1b]11;rgb:04/05/06\x1b\\" not in draw["draw_bytes"]:
                    raise AssertionError(f"missing default-color set DRAW: {draw!r}")

                send_frame(conn, INPUT, pack_bytes(b"reset\n"))
                draw, _ = recv_draw_until(conn, b"RESET_READY")
                if b"\x1b]110\x1b\\" not in draw["draw_bytes"] or b"\x1b]111\x1b\\" not in draw["draw_bytes"]:
                    raise AssertionError(f"missing default-color reset DRAW: {draw!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_seeded_default_color_query_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-default-color-query-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "default-color-query-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "stty raw -echo\n"
            "expected_fg=$(printf '\\033]10;rgb:0a/0b/0c\\033\\\\')\n"
            "expected_bg=$(printf '\\033]11;rgb:0d/0e/0f\\033\\\\')\n"
            "printf '\\033]10;?\\033\\\\'\n"
            "fg=$(dd bs=1 count=19 2>/dev/null)\n"
            "printf '\\033]11;?\\033\\\\'\n"
            "bg=$(dd bs=1 count=19 2>/dev/null)\n"
            "stty sane\n"
            "if [ \"$fg\" = \"$expected_fg\" ] && [ \"$bg\" = \"$expected_bg\" ]; then\n"
            "  printf 'SEEDED_DEFAULT_QUERY_OK\\n'\n"
            "else\n"
            "  printf 'SEEDED_DEFAULT_QUERY_BAD\\n'\n"
            "fi\n"
            "sleep 1\n"
            "exit 0\n"
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
                send_resize(conn)
                create_and_open_session(conn, shell, fg=0x010A0B0C, bg=0x010D0E0F)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                draw, _ = recv_draw_until(conn, b"SEEDED_DEFAULT_QUERY_", timeout=5.0)
                if b"SEEDED_DEFAULT_QUERY_BAD" in draw["draw_bytes"]:
                    raise AssertionError(f"seeded default color query failed: {draw!r}")
                if b"SEEDED_DEFAULT_QUERY_OK" not in draw["draw_bytes"]:
                    raise AssertionError(f"missing seeded query result: {draw!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_complex_ui_query_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-complex-ui-query-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "complex-ui-query-shell"
        shell.write_text(
            "#!/usr/bin/env python3\n"
            "import os, select, termios, tty, time\n"
            "tty.setraw(0)\n"
            "queries = [\n"
            "    b'\\x1b]12;?\\x1b\\\\',\n"
            "    b'\\x1b]4;0;?\\x1b\\\\',\n"
            "    b'\\x1bP+q4d73\\x1b\\\\',\n"
            "    b'\\x1bP$qm\\x1b\\\\',\n"
            "]\n"
            "expected = [\n"
            "    b'\\x1b]12;rgb:',\n"
            "    b'\\x1b]4;0;rgb:',\n"
            "    b'\\x1bP0+r4D73\\x1b\\\\',\n"
            "    b'\\x1bP1$r0m\\x1b\\\\',\n"
            "]\n"
            "for query in queries:\n"
            "    os.write(1, query)\n"
            "data = b''\n"
            "deadline = time.monotonic() + 3\n"
            "while time.monotonic() < deadline and not all(item in data for item in expected):\n"
            "    ready, _, _ = select.select([0], [], [], 0.05)\n"
            "    if ready:\n"
            "        chunk = os.read(0, 4096)\n"
            "        if not chunk:\n"
            "            break\n"
            "        data += chunk\n"
            "if all(item in data for item in expected):\n"
            "    os.write(1, b'COMPLEX_UI_QUERY_OK\\r\\n')\n"
            "else:\n"
            "    os.write(1, b'COMPLEX_UI_QUERY_BAD ' + repr(data).encode() + b'\\r\\n')\n"
            "time.sleep(0.2)\n"
        )
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        try:
            start_daemon(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                create_and_open_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")
                assert_session_ready(payload)

                draw, _ = recv_draw_until(conn, b"COMPLEX_UI_QUERY_", timeout=5.0)
                if b"COMPLEX_UI_QUERY_BAD" in draw["draw_bytes"]:
                    raise AssertionError(f"complex UI query response failed: {draw!r}")
                if b"COMPLEX_UI_QUERY_OK" not in draw["draw_bytes"]:
                    raise AssertionError(f"missing complex UI query result: {draw!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_scrollback_open_draw_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-scrollback-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "scrollback-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'READY$ '\n"
            "while IFS= read -r line; do\n"
            "  i=1\n"
            "  while [ \"$i\" -le 12 ]; do\n"
            "    printf 'history_%02d\\n' \"$i\"\n"
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

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, draws = recv_draw_until(conn, b"AFTER$")
                output = b"".join(draw["draw_bytes"] for draw in draws)
                scrollback_cursor = max(draw["scrollback_cursor"] for draw in draws)
                if scrollback_cursor == 0 or b"history_01" not in output:
                    raise AssertionError(f"missing live scrollback DRAW: scrollback_cursor={scrollback_cursor}, output={output!r}")

                send_frame(conn, REPAINT_REQUEST, pack_repaint(1))
                response_id, screen_only = recv_repaint_response(conn)
                if response_id != 1:
                    raise AssertionError(f"unexpected screen-only repaint seq: {response_id}")
                if screen_only["scrollback_cursor"] != scrollback_cursor:
                    raise AssertionError(f"screen-only repaint should not advance scrollback cursor: {screen_only!r}")
                if b"history_01" in screen_only["draw_bytes"] or b"\x1b[3J" in screen_only["draw_bytes"]:
                    raise AssertionError(f"screen-only repaint included retained scrollback: {screen_only!r}")
                if b"AFTER$" not in screen_only["draw_bytes"]:
                    raise AssertionError(f"screen-only repaint did not redraw visible screen: {screen_only!r}")

                send_frame(conn, REPAINT_REQUEST, pack_repaint(2, 0))
                response_id, full_repaint = recv_repaint_response(conn)
                if response_id != 2:
                    raise AssertionError(f"unexpected full repaint seq: {response_id}")
                if full_repaint["scrollback_cursor"] == 0 or b"history_01" not in full_repaint["draw_bytes"]:
                    raise AssertionError(f"full repaint did not include retained scrollback: {full_repaint!r}")

                send_frame(conn, REPAINT_REQUEST, pack_repaint(3))
                send_frame(conn, REPAINT_REQUEST, pack_repaint(4, 0))
                first_response_id, _first_draw = recv_repaint_response(conn)
                second_response_id, second_draw = recv_repaint_response(conn)
                if (first_response_id, second_response_id) != (3, 4):
                    raise AssertionError(f"repaint responses arrived out of order: {(first_response_id, second_response_id)}")
                if second_draw["scrollback_cursor"] == 0 or b"history_01" not in second_draw["draw_bytes"]:
                    raise AssertionError(f"latest repaint did not include requested retained scrollback: {second_draw!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_scrollback_clear_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-scrollback-clear-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "scrollback-clear-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'READY$ '\n"
            "while IFS= read -r line; do\n"
            "  i=1\n"
            "  while [ \"$i\" -le 12 ]; do\n"
            "    printf 'clear_history_%02d\\n' \"$i\"\n"
            "    i=$((i + 1))\n"
            "  done\n"
            "  printf '\\033[3JAFTER_CLEAR$ '\n"
            "  sleep 1\n"
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

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, draws = recv_draw_until(conn, b"AFTER_CLEAR$")
                output = b"".join(draw["draw_bytes"] for draw in draws)
                if b"\x1b[3J" not in output:
                    raise AssertionError(f"missing retained scrollback clear DRAW: {output!r}")
            finally:
                conn.close()

            reopened = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            reopened.settimeout(5.0)
            try:
                reopened.connect(str(socket_path(env)))
                send_hello(reopened)
                send_resize(reopened, 3, 40)
                send_frame(
                    reopened,
                    SESSION_OPEN,
                    pack_session_open(
                        session_guid=test_session_guid(1),
                    ),
                )

                message_type, _ = recv_frame(reopened)
                if message_type != SESSION_READY:
                    raise AssertionError(f"expected SESSION_READY, got {message_type}")

                draw = recv_draw(reopened)
                if draw["scrollback_cursor"] != 0:
                    raise AssertionError(f"cleared retained history returned in open DRAW: {draw!r}")
                if b"AFTER_CLEAR$" not in draw["draw_bytes"]:
                    raise AssertionError(f"open DRAW did not include current screen after clear: {draw!r}")
            finally:
                reopened.close()
        finally:
            cleanup_runtime(env)


