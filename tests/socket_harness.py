#!/usr/bin/env python3
import os
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import importlib.util
from pathlib import Path

from harness_cleanup import cleanup_runtime
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("SESSH_BIN", str(ROOT / "zig-out" / "bin" / "sessh")))
_PROTO_TMP = None
_PROTO_MODULE = None
_PROTO_HANDSHAKE_MODULE = None
_FRAME_HEADER_LEN = 16
_NEXT_FRAME_SEQ = 1
_LAST_RESIZE = (24, 80)
_NEXT_REPAINT_ID = 1
_SCROLLBACK_CURSOR_LEN = 16


def encode_scrollback_cursor(epoch, cursor):
    return struct.pack(">QQ", epoch, cursor)


def encode_request_scrollback_cursor(epoch, cursor):
    if epoch == 0 and cursor == 0:
        return b""
    return encode_scrollback_cursor(epoch, cursor)


def decode_scrollback_cursor(cursor_bytes):
    if len(cursor_bytes) != _SCROLLBACK_CURSOR_LEN:
        raise AssertionError(f"invalid scrollback cursor bytes: {cursor_bytes!r}")
    return struct.unpack(">QQ", cursor_bytes)


class FdConn:
    def __init__(self, read_fd, write_fd):
        self.read_fd = read_fd
        self.write_fd = write_fd
        self.timeout = 5.0

    def settimeout(self, timeout):
        self.timeout = timeout

    def gettimeout(self):
        return self.timeout

    def sendall(self, data):
        view = memoryview(data)
        while view:
            written = os.write(self.write_fd, view)
            view = view[written:]

    def recv(self, length):
        ready, _, _ = select.select([self.read_fd], [], [], self.timeout)
        if not ready:
            raise TimeoutError(f"timed out reading {length} bytes")
        return os.read(self.read_fd, length)


def run(args, env, **kwargs):
    return subprocess.run(
        [str(BIN), *args],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        **kwargs,
    )


def sessh_version():
    for line in (ROOT / "src" / "config.zig").read_text().splitlines():
        if line.startswith("pub const version = "):
            return line.split('"')[1]
    raise AssertionError("could not find sessh version")


def read_until(fd, needle, timeout=5.0):
    end = time.monotonic() + timeout
    data = b""
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        data += chunk
        if needle in data:
            return data
    raise AssertionError(f"did not see {needle!r}; saw {data!r}")


def read_until_count(fd, needle, count, timeout=5.0):
    end = time.monotonic() + timeout
    data = b""
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        data += chunk
        if data.count(needle) >= count:
            return data
    raise AssertionError(f"did not see {count} copies of {needle!r}; saw {data!r}")


def read_available(fd, timeout=0.2):
    end = time.monotonic() + timeout
    data = b""
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.02)
        if not ready:
            continue
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        data += chunk
    return data


def wait_child(pid, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            return status
        time.sleep(0.05)
    raise AssertionError(f"child {pid} did not exit")


def wait_child_draining_fd(pid, fd, timeout=5.0):
    end = time.monotonic() + timeout
    fd_open = True
    while time.monotonic() < end:
        if fd_open:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                try:
                    if not os.read(fd, 4096):
                        fd_open = False
                except OSError:
                    fd_open = False
        else:
            time.sleep(0.05)
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            return status
    raise AssertionError(f"child {pid} did not exit")


def wait_file(path, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if path.exists():
            return
        time.sleep(0.05)
    raise AssertionError(f"file was not created: {path}")


def wait_missing(path, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if not path.exists():
            return
        time.sleep(0.05)
    raise AssertionError(f"file still exists: {path}")


def wait_log_contains(path, needle, timeout=5.0):
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        if path.exists():
            last = path.read_text()
            if needle in last:
                return last
        time.sleep(0.05)
    raise AssertionError(f"did not see {needle!r} in {path}; saw {last!r}")


def sessh_pb():
    global _PROTO_TMP, _PROTO_MODULE, _PROTO_HANDSHAKE_MODULE
    if _PROTO_MODULE is not None:
        return _PROTO_MODULE
    _PROTO_TMP = tempfile.TemporaryDirectory(prefix="sessh-proto-", dir="/tmp")
    output_dir = Path(_PROTO_TMP.name)
    protoc = os.environ.get("SESSH_PROTOC")
    if protoc is None:
        raise AssertionError("SESSH_PROTOC is not set; run this test through scripts/check")
    subprocess.run(
        [
            protoc,
            f"--python_out={output_dir}",
            "-I",
            str(ROOT / "proto"),
            str(ROOT / "proto" / "sessh.proto"),
            str(ROOT / "proto" / "sessh_handshake.proto"),
        ],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    generated = output_dir / "sessh_pb2.py"
    spec = importlib.util.spec_from_file_location("sessh_pb2", generated)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    _PROTO_MODULE = module

    handshake_generated = output_dir / "sessh_handshake_pb2.py"
    handshake_spec = importlib.util.spec_from_file_location("sessh_handshake_pb2", handshake_generated)
    handshake_module = importlib.util.module_from_spec(handshake_spec)
    handshake_spec.loader.exec_module(handshake_module)
    _PROTO_HANDSHAKE_MODULE = handshake_module
    return module


def sessh_hpb():
    if _PROTO_HANDSHAKE_MODULE is None:
        sessh_pb()
    return _PROTO_HANDSHAKE_MODULE


def pack_bytes(value):
    return sessh_pb().Input(data=value).SerializeToString()


def pack_session_new(shell, scrollback=2000, fg=0xFFFFFFFF, bg=0xFFFFFFFF):
    pb = sessh_pb()
    message = pb.SessionNew(scrollback_row_limit=scrollback)
    rows, cols = _LAST_RESIZE
    message.resize.terminal_rows = rows
    message.resize.terminal_cols = cols
    entry = message.environment.add()
    entry.name = "SHELL"
    entry.value = str(shell)
    message.query_default_colors.foreground_color = fg
    message.query_default_colors.background_color = bg
    return message.SerializeToString()


def pack_command(*argv):
    payload = bytearray([len(argv)])
    for arg in argv:
        data = str(arg).encode()
        payload += struct.pack(">I", len(data))
        payload += data
    return bytes(payload)


def unpack_command_response(payload):
    if len(payload) < 9:
        raise AssertionError(f"short command response: {payload!r}")
    exit_status = payload[0]
    stdout_len, stderr_len = struct.unpack(">II", payload[1:9])
    if len(payload) != 9 + stdout_len + stderr_len:
        raise AssertionError(f"invalid command response length: {payload!r}")
    stdout = payload[9:9 + stdout_len]
    stderr = payload[9 + stdout_len:]
    return exit_status, stdout, stderr


def pack_session_attach(session_id, initial_scrollback=None, reconnect_cursor=None):
    global _NEXT_REPAINT_ID
    pb = sessh_pb()
    message = pb.SessionAttach()
    rows, cols = _LAST_RESIZE
    message.resize.terminal_rows = rows
    message.resize.terminal_cols = cols
    repaint = message.resize.repaint_request
    repaint.id = _NEXT_REPAINT_ID
    _NEXT_REPAINT_ID += 1
    if reconnect_cursor is not None:
        epoch, cursor = reconnect_cursor
        repaint.scrollback_cursor = encode_scrollback_cursor(epoch, cursor)
    else:
        if initial_scrollback != 0:
            repaint.scrollback_cursor = b""
        if initial_scrollback is not None:
            repaint.initial_scrollback_rows = initial_scrollback
    return message.SerializeToString()


def send_resize(conn, rows=24, cols=80, repaint=None, viewport_offset=None):
    global _LAST_RESIZE
    _LAST_RESIZE = (rows, cols)
    message = sessh_pb().Resize(terminal_rows=rows, terminal_cols=cols)
    if viewport_offset is not None:
        message.viewport_offset = viewport_offset
    if repaint is not None:
        if len(repaint) == 2:
            repaint_id, scrollback_cursor = repaint
            scrollback_epoch = 0
        else:
            repaint_id, scrollback_epoch, scrollback_cursor = repaint
        message.repaint_request.id = repaint_id
        message.repaint_request.scrollback_cursor = encode_request_scrollback_cursor(scrollback_epoch, scrollback_cursor)
    send_frame(conn, 0x0016, message.SerializeToString())


def pack_repaint(repaint_id, scrollback_cursor=None, scrollback_epoch=0):
    message = sessh_pb().RepaintRequest(id=repaint_id)
    if scrollback_cursor is not None:
        message.scrollback_cursor = encode_request_scrollback_cursor(scrollback_epoch, scrollback_cursor)
    return message.SerializeToString()


def pack_ping_request():
    return sessh_pb().PingRequest().SerializeToString()


def parse_ping_response(payload):
    message = sessh_pb().PingResponse()
    message.ParseFromString(payload)
    return message.request_seq_number


def parse_unrecognized_frame(payload):
    message = sessh_hpb().UnrecognizedFrame()
    message.ParseFromString(payload)
    return message.seq, message.frame_type


def unpack_session_attached(payload):
    message = sessh_pb().SessionAttached()
    message.ParseFromString(payload)
    return "s1"


def parse_draw(payload):
    message = sessh_pb().Draw()
    message.ParseFromString(payload)
    if not message.scrollback_cursor:
        raise AssertionError(f"missing scrollback cursor: {payload!r}")
    epoch, scrollback_cursor = decode_scrollback_cursor(message.scrollback_cursor)
    return {
        "epoch": epoch,
        "scrollback_cursor": scrollback_cursor,
        "scrollback_cursor_bytes": message.scrollback_cursor,
        "viewport_offset": message.viewport_offset if message.HasField("viewport_offset") else 0,
        "draw_bytes": message.draw_bytes,
    }


def parse_repaint_response(payload):
    message = sessh_pb().RepaintResponse()
    message.ParseFromString(payload)
    if not message.HasField("draw"):
        raise AssertionError(f"missing repaint response draw: {payload!r}")
    return message.id, parse_draw(message.draw.SerializeToString())


def recv_draw(conn, timeout=5.0):
    old_timeout = conn.gettimeout()
    conn.settimeout(timeout)
    try:
        while True:
            message_type, seq, payload = recv_frame_full(conn)
            if message_type == 0x0027:
                draw = parse_draw(payload)
                draw["frame_seq"] = seq
                return draw
            if message_type == 0x0029:
                response_id, draw = parse_repaint_response(payload)
                draw["frame_seq"] = seq
                draw["repaint_id"] = response_id
                return draw
            if message_type == 0x0022:
                raise AssertionError("session ended before DRAW arrived")
    finally:
        conn.settimeout(old_timeout)


def recv_repaint_response(conn, timeout=5.0):
    old_timeout = conn.gettimeout()
    conn.settimeout(timeout)
    try:
        while True:
            message_type, seq, payload = recv_frame_full(conn)
            if message_type == 0x0029:
                response_id, draw = parse_repaint_response(payload)
                draw["frame_seq"] = seq
                return response_id, draw
            if message_type == 0x0022:
                raise AssertionError("session ended before REPAINT_RESPONSE arrived")
    finally:
        conn.settimeout(old_timeout)


def recv_draw_until(conn, needle, timeout=5.0):
    end = time.monotonic() + timeout
    draws = []
    while time.monotonic() < end:
        draw = recv_draw(conn, timeout=max(0.1, end - time.monotonic()))
        draws.append(draw)
        if needle in draw["draw_bytes"]:
            return draw, draws
    raise AssertionError(f"did not see {needle!r} in DRAW bytes: {draws!r}")


def recv_until_frame_type(conn, expected_type, timeout=5.0):
    old_timeout = conn.gettimeout()
    conn.settimeout(timeout)
    end = time.monotonic() + timeout
    try:
        while time.monotonic() < end:
            message_type, payload = recv_frame(conn)
            if message_type == expected_type:
                return payload
    finally:
        conn.settimeout(old_timeout)
    raise AssertionError(f"did not receive frame type {expected_type:#06x}")


def next_frame_seq():
    global _NEXT_FRAME_SEQ
    seq = _NEXT_FRAME_SEQ
    _NEXT_FRAME_SEQ += 1
    if _NEXT_FRAME_SEQ > 0xFFFFFFFFFFFFFFFF:
        _NEXT_FRAME_SEQ = 1
    return seq


def send_frame(conn, message_type, payload=b"", seq=None):
    if seq is None:
        seq = next_frame_seq()
    conn.sendall(struct.pack(">IIQ", len(payload), message_type, seq) + payload)
    return seq


def recv_frame(conn):
    message_type, _seq, payload = recv_frame_full(conn)
    return message_type, payload


def recv_frame_full(conn):
    header = recv_exact(conn, _FRAME_HEADER_LEN)
    payload_len, message_type, seq = struct.unpack(">IIQ", header)
    return message_type, seq, recv_exact(conn, payload_len)


def recv_exact(conn, length):
    data = b""
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            raise AssertionError("connection closed while reading frame")
        data += chunk
    return data


def sessions_dir(env):
    runtime_dir = env.get("XDG_RUNTIME_DIR")
    if not runtime_dir:
        raise AssertionError("socket harness requires XDG_RUNTIME_DIR")
    return Path(runtime_dir) / "sessh" / "s"


def assert_runtime_dir_symlink(env, expected_runtime_root):
    link = Path(env["XDG_CACHE_HOME"]) / "sessh" / "runtime_dir"
    if not link.is_symlink():
        raise AssertionError(f"runtime dir pointer is missing: {link}")
    actual = Path(os.readlink(link))
    if actual != Path(expected_runtime_root):
        raise AssertionError(f"runtime dir pointer target mismatch: expected {expected_runtime_root}, got {actual}")


def session_dir(env, session_id="s1"):
    return sessions_dir(env) / session_id


def socket_path(env, session_id="s1"):
    return session_dir(env, session_id) / "s"


def start_session_agent(env, session_id="s1"):
    path = socket_path(env, session_id)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    proc = subprocess.Popen(
        [str(BIN), ":internal-session-agent:", "--session-dir", str(path.parent)],
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    wait_file(path)
    return proc


def session_agent_pids(env):
    needle = f":internal-session-agent: --session-dir {Path(env['XDG_RUNTIME_DIR']) / 'sessh' / 's'}"
    result = subprocess.run(
        ["ps", "-axo", "pid=,command="],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
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
        if needle in command:
            pids.append(pid)
    return pids


def run_login_shell_profile_test(_base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-login-shell-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        profile = Path(env["HOME"]) / ".profile"
        profile.write_text("printf 'LOGIN_PROFILE_READY\\n'\n")
        cleanup_runtime(env)
        try:
            start_session_agent(env)
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(Path("/bin/sh")))
                message_type, _payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                recv_draw_until(conn, b"LOGIN_PROFILE_READY")
                send_frame(conn, 0x0015, pack_bytes(b"exit\n"))
                recv_until_frame_type(conn, 0x0022)
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def startup_cwd_title_sequence():
    return b"\x1b]2;" + str(ROOT).encode() + b"\x1b\\"


def config_version():
    config = (ROOT / "src" / "config.zig").read_text()
    version = re.search(r'pub const version = "([^"]+)";', config).group(1)
    major = int(re.search(r"pub const protocol_major = ([0-9]+);", config).group(1))
    minor = int(re.search(r"pub const protocol_minor = ([0-9]+);", config).group(1))
    return version, major, minor


def send_hello(conn, minor_delta=0, expect_ok=True):
    version, major, minor = config_version()
    send_frame(
        conn,
        0x0001,
        sessh_hpb().HelloRequest(
            protocol_major=major,
            protocol_minor=minor + minor_delta,
            version=version,
        ).SerializeToString(),
    )
    message_type, payload = recv_frame(conn)
    if expect_ok:
        if message_type != 0x0002:
            raise AssertionError(f"expected HELLO_OK, got {message_type:#06x}")
        ok = sessh_hpb().HelloOk()
        ok.ParseFromString(payload)
    else:
        if message_type != 0x0003:
            raise AssertionError(f"expected HELLO_ERROR, got {message_type:#06x}")
        error = sessh_hpb().HelloError()
        error.ParseFromString(payload)
        return message_type, payload
    message_type, payload = recv_frame(conn)
    if message_type != 0x0001:
        raise AssertionError(f"expected peer HELLO_REQUEST, got {message_type:#06x}")
    peer = sessh_hpb().HelloRequest()
    peer.ParseFromString(payload)
    if peer.protocol_major != major or peer.protocol_minor != minor or peer.version != version:
        raise AssertionError(f"unexpected peer HELLO_REQUEST: {peer!r}")
    send_frame(conn, 0x0002, sessh_hpb().HelloOk().SerializeToString())
    return message_type, payload


def run_minor_version_compatibility_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-minor-compat-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        cleanup_runtime(env)
        try:
            start_session_agent(env)

            newer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            newer.settimeout(5.0)
            try:
                newer.connect(str(socket_path(env)))
                send_hello(newer, minor_delta=1)
            finally:
                newer.close()

            _version, _major, minor = config_version()
            if minor > 0:
                older = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                older.settimeout(5.0)
                try:
                    older.connect(str(socket_path(env)))
                    send_hello(older, minor_delta=-1, expect_ok=False)
                finally:
                    older.close()
        finally:
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                session_id = unpack_session_attached(payload)

                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
                _, draws = recv_draw_until(conn, b"PATCH_LINK")
                output = b"".join(draw["draw_bytes"] for draw in draws)
                if b"PATCH_MARKER" not in output:
                    raise AssertionError(f"live DRAW did not include updated text: {output!r}")
                for seq in (b"\x1b[1m", b"\x1b[31m", b"\x1b[44m"):
                    if seq not in output:
                        raise AssertionError(f"missing style sequence {seq!r}: {output!r}")
                if b"\x1b]8;;https://example.test/\x1b\\" not in output:
                    raise AssertionError(f"missing hyperlink sequence: {output!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_ping_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-ping-protocol-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "ping-shell"
        shell.write_text("#!/bin/sh\nwhile :; do sleep 1; done\n")
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        try:
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                ping_seq = send_frame(conn, 0x0018, pack_ping_request())
                response = recv_until_frame_type(conn, 0x0028)
                if parse_ping_response(response) != ping_seq:
                    raise AssertionError(f"unexpected ping response: {response!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)

def run_unrecognized_frame_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-unrecognized-frame-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "unrecognized-shell"
        shell.write_text("#!/bin/sh\nwhile :; do sleep 1; done\n")
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        try:
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                unknown_seq = 0x123456789ABCDEF0
                send_frame(conn, 0x7FFF, b"", seq=unknown_seq)
                response = recv_until_frame_type(conn, 0x0005)
                reported_seq, reported_type = parse_unrecognized_frame(response)
                if reported_seq != unknown_seq or reported_type != 0x7FFF:
                    raise AssertionError(
                        f"unexpected UNRECOGNIZED payload: seq={reported_seq:#x} type={reported_type:#x}"
                    )

                ping_seq = send_frame(conn, 0x0018, pack_ping_request())
                ping_response = recv_until_frame_type(conn, 0x0028)
                if parse_ping_response(ping_response) != ping_seq:
                    raise AssertionError(f"connection did not continue after unknown frame: {ping_response!r}")
            finally:
                conn.close()
        finally:
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, rows=10, cols=80)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                recv_draw_until(conn, b"SCROLL_READY$ ")
                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, rows=24, cols=80)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                recv_draw_until(conn, b"SCREEN_READY$ ")
                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
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


def run_split_escape_tail_is_not_passthrough_test(base_env):
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, rows=24, cols=80)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                recv_draw_until(conn, b"SPLIT_READY$ ")
                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
                draw, _ = recv_draw_until(conn, b"ALT_SCREEN")
                if b"\x1b[?1049h" in draw["draw_bytes"] or b"\x1b[?1049l" in draw["draw_bytes"]:
                    raise AssertionError(f"DRAW should not enter outer alternate screen: {draw!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_terminal_modes_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-terminal-modes-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "terminal-modes-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "while IFS= read -r line; do\n"
            "  printf '\\033[?1;1000;1004;1006;2004hMODES_READY'\n"
            "  sleep 1\n"
            "done\n"
        )
        shell.chmod(0o700)
        cleanup_runtime(env)
        try:
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
                draw, draws = recv_draw_until(conn, b"MODES_READY")
                output = b"".join(item["draw_bytes"] for item in draws)
                for seq in (b"\x1b[?1h", b"\x1b[?1000h", b"\x1b[?1006h", b"\x1b[?1004h", b"\x1b[?2004h"):
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                recv_draw_until(conn, b"\x1b]2;cursor-shape-ready\x1b\\")
                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
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
        pid, fd = spawn_client(env)
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
        pid, fd = spawn_client(env)
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                send_frame(conn, 0x0015, pack_bytes(b"set\n"))
                draw, _ = recv_draw_until(conn, b"COLOR_READY")
                if b"\x1b]10;rgb:01/02/03\x1b\\" not in draw["draw_bytes"] or b"\x1b]11;rgb:04/05/06\x1b\\" not in draw["draw_bytes"]:
                    raise AssertionError(f"missing default-color set DRAW: {draw!r}")

                send_frame(conn, 0x0015, pack_bytes(b"reset\n"))
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell, fg=0x010A0B0C, bg=0x010D0E0F))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn)
                send_frame(conn, 0x0011, pack_session_new(shell))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                _session_id = unpack_session_attached(payload)

                draw, _ = recv_draw_until(conn, b"COMPLEX_UI_QUERY_", timeout=5.0)
                if b"COMPLEX_UI_QUERY_BAD" in draw["draw_bytes"]:
                    raise AssertionError(f"complex UI query response failed: {draw!r}")
                if b"COMPLEX_UI_QUERY_OK" not in draw["draw_bytes"]:
                    raise AssertionError(f"missing complex UI query result: {draw!r}")
            finally:
                conn.close()
        finally:
            cleanup_runtime(env)


def run_scrollback_attach_draw_protocol_test(base_env):
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, 3, 40)
                send_frame(conn, 0x0011, pack_session_new(shell, scrollback=20))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                session_id = unpack_session_attached(payload)

                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
                _, draws = recv_draw_until(conn, b"AFTER$")
                output = b"".join(draw["draw_bytes"] for draw in draws)
                scrollback_cursor = max(draw["scrollback_cursor"] for draw in draws)
                if scrollback_cursor == 0 or b"history_01" not in output:
                    raise AssertionError(f"missing live scrollback DRAW: scrollback_cursor={scrollback_cursor}, output={output!r}")

                send_frame(conn, 0x0017, pack_repaint(1))
                response_id, screen_only = recv_repaint_response(conn)
                if response_id != 1:
                    raise AssertionError(f"unexpected screen-only repaint id: {response_id}")
                if screen_only["scrollback_cursor"] != scrollback_cursor:
                    raise AssertionError(f"screen-only repaint should not advance scrollback cursor: {screen_only!r}")
                if b"history_01" in screen_only["draw_bytes"] or b"\x1b[3J" in screen_only["draw_bytes"]:
                    raise AssertionError(f"screen-only repaint included retained scrollback: {screen_only!r}")
                if b"AFTER$" not in screen_only["draw_bytes"]:
                    raise AssertionError(f"screen-only repaint did not redraw visible screen: {screen_only!r}")

                send_frame(conn, 0x0017, pack_repaint(2, 0))
                response_id, full_repaint = recv_repaint_response(conn)
                if response_id != 2:
                    raise AssertionError(f"unexpected full repaint id: {response_id}")
                if full_repaint["scrollback_cursor"] == 0 or b"history_01" not in full_repaint["draw_bytes"]:
                    raise AssertionError(f"full repaint did not include retained scrollback: {full_repaint!r}")
            finally:
                conn.close()

            attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            attach.settimeout(5.0)
            try:
                attach.connect(str(socket_path(env)))
                send_hello(attach)
                send_resize(attach, 3, 40)
                send_frame(attach, 0x0012, pack_session_attach(session_id))

                message_type, _ = recv_frame(attach)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")

                draw = recv_draw(attach)
                if draw["scrollback_cursor"] == 0 or b"history_01" not in draw["draw_bytes"]:
                    raise AssertionError(f"missing retained scrollback rows in attach DRAW: {draw!r}")
            finally:
                attach.close()
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, 3, 40)
                send_frame(conn, 0x0011, pack_session_new(shell, scrollback=20))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                session_id = unpack_session_attached(payload)

                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
                _, draws = recv_draw_until(conn, b"AFTER_CLEAR$")
                output = b"".join(draw["draw_bytes"] for draw in draws)
                if b"\x1b[3J" not in output:
                    raise AssertionError(f"missing retained scrollback clear DRAW: {output!r}")
            finally:
                conn.close()

            attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            attach.settimeout(5.0)
            try:
                attach.connect(str(socket_path(env)))
                send_hello(attach)
                send_resize(attach, 3, 40)
                send_frame(attach, 0x0012, pack_session_attach(session_id))

                message_type, _ = recv_frame(attach)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")

                draw = recv_draw(attach)
                if draw["scrollback_cursor"] != 0:
                    raise AssertionError(f"cleared retained history returned in attach DRAW: {draw!r}")
                if b"AFTER_CLEAR$" not in draw["draw_bytes"]:
                    raise AssertionError(f"attach DRAW did not include current screen after clear: {draw!r}")
            finally:
                attach.close()
        finally:
            cleanup_runtime(env)


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
    start_session_agent(env)
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(5.0)
    conn.connect(str(socket_path(env)))
    send_hello(conn)
    send_resize(conn, 3, 40)
    send_frame(conn, 0x0011, pack_session_new(shell, scrollback=scrollback_limit))
    message_type, payload = recv_frame(conn)
    if message_type != 0x0021:
        raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
    session_id = unpack_session_attached(payload)
    return conn, session_id


def attach_gap_session(env, session_id, reconnect_cursor=None):
    attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    attach.settimeout(5.0)
    attach.connect(str(socket_path(env)))
    send_hello(attach)
    send_resize(attach, 3, 40)
    send_frame(attach, 0x0012, pack_session_attach(session_id, reconnect_cursor=reconnect_cursor))
    message_type, _ = recv_frame(attach)
    if message_type != 0x0021:
        raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
    return attach


def run_reconnect_scrollback_gap_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-reconnect-gap-complete-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "gap-complete-shell"
        write_reconnect_gap_shell(shell, before_count=3, during_count=4)
        cleanup_runtime(env)
        try:
            conn, session_id = start_gap_session(env, shell, scrollback_limit=50)
            try:
                recv_draw_until(conn, b"READY$ ")
                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
                _, before_draws = recv_draw_until(conn, b"BEFORE_DONE")
                cursor = (before_draws[-1]["epoch"], before_draws[-1]["scrollback_cursor"])
                last_before_frame_seq = before_draws[-1]["frame_seq"]
            finally:
                conn.close()

            time.sleep(0.6)

            attach = attach_gap_session(env, session_id, reconnect_cursor=cursor)
            try:
                _, reconnect_draws = recv_draw_until(attach, b"DURING_DONE$ ")
                if reconnect_draws[0]["frame_seq"] <= last_before_frame_seq:
                    raise AssertionError(
                        "session-agent frame seq reset across reconnect: "
                        f"before={last_before_frame_seq} reconnect={reconnect_draws[0]['frame_seq']}"
                    )
                output = b"".join(draw["draw_bytes"] for draw in reconnect_draws)
                if b"sessh scrollback truncated" in output:
                    raise AssertionError(f"unexpected truncation marker without truncation: {output!r}")
                for i in range(1, 5):
                    needle = f"during_{i:02d}".encode()
                    if needle not in output:
                        raise AssertionError(f"missing reconnect output {needle!r}: {output!r}")
            finally:
                attach.close()
        finally:
            cleanup_runtime(env)

    with tempfile.TemporaryDirectory(prefix="sessh-reconnect-gap-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "gap-shell"
        write_reconnect_gap_shell(shell, before_count=4, during_count=20)
        cleanup_runtime(env)
        try:
            conn, session_id = start_gap_session(env, shell, scrollback_limit=5)
            try:
                recv_draw_until(conn, b"READY$ ")
                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
                _, before_draws = recv_draw_until(conn, b"BEFORE_DONE")
                cursor = (before_draws[-1]["epoch"], before_draws[-1]["scrollback_cursor"])
            finally:
                conn.close()

            time.sleep(0.8)

            attach = attach_gap_session(env, session_id, reconnect_cursor=cursor)
            try:
                _, reconnect_draws = recv_draw_until(attach, b"DURING_DONE$ ")
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

                send_frame(attach, 0x0015, pack_bytes(b"after\n"))
                _, post_draws = recv_draw_until(attach, b"POST:after")
                post_output = b"".join(draw["draw_bytes"] for draw in post_draws)
                if b"POST:after" not in post_output:
                    raise AssertionError(f"post-reconnect input was not delivered: {post_output!r}")
            finally:
                attach.close()

            normal = attach_gap_session(env, session_id)
            try:
                _, attach_draws = recv_draw_until(normal, b"POST:after")
                output = b"".join(draw["draw_bytes"] for draw in attach_draws)
                # The post-reconnect command adds more retained history; a
                # normal attach should report the full omitted prefix.
                if b"--- sessh scrollback truncated: 21 lines ---" not in output:
                    raise AssertionError(f"missing normal attach truncation marker: {output!r}")
            finally:
                normal.close()
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
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, 3, 40)
                send_frame(conn, 0x0011, pack_session_new(shell, scrollback=20))

                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
                session_id = unpack_session_attached(payload)

                recv_draw_until(conn, b"READY$ ")
                send_frame(conn, 0x0015, pack_bytes(b"go\n"))
                _, before_draws = recv_draw_until(conn, b"AFTER$ ")
                cursor = (before_draws[-1]["epoch"], before_draws[-1]["scrollback_cursor"])

                send_resize(conn, 3, 20, repaint=(1, cursor[0], cursor[1]), viewport_offset=-1)
                response_id, resize_repaint = recv_repaint_response(conn)
                if response_id != 1:
                    raise AssertionError(f"unexpected resize repaint id: {response_id}")
                if resize_repaint["viewport_offset"] != 0:
                    raise AssertionError(f"resize repaint did not realign unknown viewport: {resize_repaint!r}")
                if resize_repaint["epoch"] == cursor[0]:
                    raise AssertionError(f"resize repaint did not bump scrollback epoch: {resize_repaint!r}")
                if resize_repaint["scrollback_cursor"] == 0:
                    raise AssertionError(f"resize repaint did not return a usable cursor: {resize_repaint!r}")
            finally:
                conn.close()

            attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            attach.settimeout(5.0)
            try:
                attach.connect(str(socket_path(env)))
                send_hello(attach)
                send_resize(attach, 3, 20)
                send_frame(attach, 0x0012, pack_session_attach(session_id, reconnect_cursor=cursor))

                message_type, _ = recv_frame(attach)
                if message_type != 0x0021:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")

                _, reconnect_draws = recv_draw_until(attach, b"AFTER$ ")
                output = b"".join(draw["draw_bytes"] for draw in reconnect_draws)
                if b"\x1b[3J" in output:
                    raise AssertionError(f"resize epoch bump cleared outer scrollback: {output!r}")
                if any(draw["epoch"] != resize_repaint["epoch"] for draw in reconnect_draws):
                    raise AssertionError(f"reconnect did not use resize epoch: {reconnect_draws!r}")
                if b"resize_history_01" not in output:
                    raise AssertionError(f"reconnect did not include retained scrollback after resize: {output!r}")
            finally:
                attach.close()
        finally:
            cleanup_runtime(env)


def run_slow_attachment_does_not_block_commands_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-slow-attachment-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        shell = Path(tmp) / "slow-attachment-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'SLOW_READY$ '\n"
            "while IFS= read -r line; do\n"
            "  python3 - <<'PY'\n"
            "import sys\n"
            "line = 'SLOW_ATTACHMENT_' + ('x' * 180) + '\\n'\n"
            "for _ in range(20000):\n"
            "    sys.stdout.write(line)\n"
            "sys.stdout.flush()\n"
            "PY\n"
            "  sleep 30\n"
            "done\n"
        )
        shell.chmod(0o700)
        cleanup_runtime(env)
        conn = None
        try:
            start_session_agent(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            conn.settimeout(5.0)
            conn.connect(str(socket_path(env)))
            send_hello(conn)
            send_resize(conn, 3, 200)
            send_frame(conn, 0x0011, pack_session_new(shell, scrollback=50000))

            message_type, payload = recv_frame(conn)
            if message_type != 0x0021:
                raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
            _session_id = unpack_session_attached(payload)

            recv_draw_until(conn, b"SLOW_READY")
            send_frame(conn, 0x0015, pack_bytes(b"go\n"))
            time.sleep(0.5)

            try:
                listed = run([":local:", "--compat-version", sessh_version(), "--list"], env, check=True, timeout=2.0)
            except subprocess.TimeoutExpired as exc:
                raise AssertionError("management command path blocked behind a slow attachment") from exc
            if "ID\tATTACHED\tPID" not in listed.stdout:
                raise AssertionError(listed.stdout)
        finally:
            if conn is not None:
                conn.close()
            cleanup_runtime(env)


def run_session_agent_crash_client_error_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-agent-crash-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        cleanup_runtime(env)
        pid, fd = spawn_client(env)
        child_closed = False
        try:
            read_until(fd, b"$ ")
            pids = session_agent_pids(env)
            if len(pids) != 1:
                raise AssertionError(f"expected one session agent, found {pids}")

            os.kill(pids[0], signal.SIGKILL)
            output = read_until(fd, b"sessh: session agent crashed", timeout=5.0)
            if b"session agent crashed" not in output:
                raise AssertionError(output)

            status = wait_child_draining_fd(pid, fd)
            if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 1:
                raise AssertionError(f"expected client exit status 1, got wait status {status}")
            os.close(fd)
            child_closed = True
        finally:
            if not child_closed:
                close_client(pid, fd)
            cleanup_runtime(env)


def run_session_agent_registry_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-agent-registry-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "agent-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'AGENT_READY\\n'\n"
            "while IFS= read -r line; do\n"
            "  if [ \"$line\" = exit ]; then exit 0; fi\n"
            "  printf 'AGENT:%s\\n' \"$line\"\n"
            "done\n"
        )
        shell.chmod(0o700)

        session_dir = Path(env["XDG_RUNTIME_DIR"]) / "sessh" / "s" / "s42"
        session_dir.mkdir(mode=0o700, parents=True)
        socket_file = session_dir / "s"
        meta_file = session_dir / "meta"
        detached_file = session_dir / "detached"
        compat_file = session_dir / "compat"

        proc = subprocess.Popen(
            [str(BIN), ":internal-session-agent:", "--session-dir", str(session_dir)],
            cwd=ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        conn = None
        attach = None
        try:
            wait_file(socket_file)
            wait_file(meta_file)
            wait_file(compat_file)
            meta = meta_file.read_text()
            if f"pid={proc.pid}\n" not in meta or f"version={sessh_version()}\n" not in meta:
                raise AssertionError(meta)
            if not os.path.islink(compat_file):
                raise AssertionError("session compat path is not a symlink")

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            conn.connect(str(socket_file))
            send_hello(conn)
            send_resize(conn, rows=4, cols=40)
            send_frame(conn, 0x0011, pack_session_new(shell))
            message_type, payload = recv_frame(conn)
            if message_type != 0x0021:
                raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
            unpack_session_attached(payload)
            if detached_file.exists():
                raise AssertionError("detached marker exists while attached")
            recv_draw_until(conn, b"AGENT_READY")

            conn.close()
            conn = None
            wait_file(detached_file)

            attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            attach.settimeout(5.0)
            attach.connect(str(socket_file))
            send_hello(attach)
            send_resize(attach, rows=4, cols=40)
            send_frame(attach, 0x0012, pack_session_attach("s42"))
            message_type, payload = recv_frame(attach)
            if message_type != 0x0021:
                raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
            unpack_session_attached(payload)
            if detached_file.exists():
                raise AssertionError("detached marker survived reattach")

            send_frame(attach, 0x0015, pack_bytes(b"exit\n"))
            recv_until_frame_type(attach, 0x0022)
            proc.wait(timeout=5.0)
            wait_missing(socket_file)
            wait_missing(compat_file)
            wait_missing(detached_file)
            if not session_dir.exists():
                raise AssertionError("session tombstone was removed")
        finally:
            if conn is not None:
                conn.close()
            if attach is not None:
                attach.close()
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2.0)


def run_host_broker_starts_session_agent_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-host-broker-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "broker-shell"
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
            [str(BIN), ":internal-host-broker:"],
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
            send_frame(conn, 0x0011, pack_session_new(shell))
            message_type, payload = recv_frame(conn)
            if message_type != 0x0021:
                raise AssertionError(f"expected SESSION_ATTACHED, got {message_type:#06x}")
            unpack_session_attached(payload)
            recv_draw_until(conn, b"BROKER_READY")

            session_dir = Path(env["XDG_RUNTIME_DIR"]) / "sessh" / "s" / "s1"
            if not (session_dir / "s").exists():
                raise AssertionError("host broker did not create a session-agent socket")
            if not os.path.islink(session_dir / "compat"):
                raise AssertionError("host broker session agent did not write compat symlink")
            assert_runtime_dir_symlink(env, Path(env["XDG_RUNTIME_DIR"]) / "sessh")

            send_frame(conn, 0x0015, pack_bytes(b"exit\n"))
            recv_until_frame_type(conn, 0x0022)
            proc.stdin.close()
            proc.wait(timeout=5.0)
            if proc.returncode != 0:
                raise AssertionError(proc.stderr.read().decode("utf-8", "replace"))
            wait_missing(session_dir / "s")
            wait_missing(session_dir / "compat")
            if not session_dir.exists():
                raise AssertionError("host broker removed session tombstone")
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2.0)


def run_host_broker_registry_commands_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-host-broker-commands-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "broker-command-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'BROKER_COMMAND_READY\\n'\n"
            "while IFS= read -r line; do\n"
            "  if [ \"$line\" = exit ]; then exit 0; fi\n"
            "  printf 'BROKER_COMMAND:%s\\n' \"$line\"\n"
            "done\n"
        )
        shell.chmod(0o700)
        session_dir = Path(env["XDG_RUNTIME_DIR"]) / "sessh" / "s" / "s1"

        proc = subprocess.Popen(
            [str(BIN), ":internal-host-broker:"],
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
            send_frame(conn, 0x0011, pack_session_new(shell))
            message_type, payload = recv_frame(conn)
            if message_type != 0x0021:
                raise AssertionError((message_type, payload))
            unpack_session_attached(payload)
            recv_draw_until(conn, b"BROKER_COMMAND_READY")
            proc.stdin.close()
            proc.wait(timeout=5.0)
            wait_file(session_dir / "detached")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)

        proc = subprocess.Popen(
            [str(BIN), ":internal-host-broker:"],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        conn = FdConn(proc.stdout.fileno(), proc.stdin.fileno())
        try:
            send_hello(conn)
            send_frame(conn, 0x0010, pack_command("list"))
            message_type, payload = recv_frame(conn)
            if message_type != 0x0020:
                raise AssertionError(f"expected COMMAND_RESPONSE, got {message_type:#06x}")
            status, stdout, stderr = unpack_command_response(payload)
            if status != 0 or stderr:
                raise AssertionError((status, stdout, stderr))
            if b"s1\tno\t" not in stdout:
                raise AssertionError(stdout)
            proc.stdin.close()
            proc.wait(timeout=5.0)
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)

        proc = subprocess.Popen(
            [str(BIN), ":internal-host-broker:"],
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
            send_frame(conn, 0x0012, pack_session_attach("s1"))
            message_type, payload = recv_frame(conn)
            if message_type != 0x0021:
                raise AssertionError((message_type, payload))
            unpack_session_attached(payload)
            if (session_dir / "detached").exists():
                raise AssertionError("broker attach did not remove detached marker")
            send_frame(conn, 0x0015, pack_bytes(b"exit\n"))
            recv_until_frame_type(conn, 0x0022)
            proc.stdin.close()
            proc.wait(timeout=5.0)
            wait_missing(session_dir / "s")
            wait_missing(session_dir / "compat")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)

        proc = subprocess.Popen(
            [str(BIN), ":internal-host-broker:"],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        conn = FdConn(proc.stdout.fileno(), proc.stdin.fileno())
        try:
            send_hello(conn)
            send_frame(conn, 0x0010, pack_command("kill", "s1"))
            message_type, payload = recv_frame(conn)
            if message_type != 0x0020:
                raise AssertionError(f"expected COMMAND_RESPONSE, got {message_type:#06x}")
            status, stdout, stderr = unpack_command_response(payload)
            if status != 1 or b"session not found" not in stderr:
                raise AssertionError((status, stdout, stderr))
            proc.stdin.close()
            proc.wait(timeout=5.0)
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)

        proc = subprocess.Popen(
            [str(BIN), ":internal-host-broker:"],
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
            send_frame(conn, 0x0011, pack_session_new(shell))
            message_type, payload = recv_frame(conn)
            if message_type != 0x0021:
                raise AssertionError((message_type, payload))
            unpack_session_attached(payload)
            recv_draw_until(conn, b"BROKER_COMMAND_READY")
            proc.stdin.close()
            proc.wait(timeout=5.0)
            wait_file(Path(env["XDG_RUNTIME_DIR"]) / "sessh" / "s" / "s2" / "detached")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)

        proc = subprocess.Popen(
            [str(BIN), ":internal-host-broker:"],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        conn = FdConn(proc.stdout.fileno(), proc.stdin.fileno())
        try:
            send_hello(conn)
            send_frame(conn, 0x0010, pack_command("kill", "s2"))
            message_type, payload = recv_frame(conn)
            if message_type != 0x0020:
                raise AssertionError(f"expected COMMAND_RESPONSE, got {message_type:#06x}")
            status, stdout, stderr = unpack_command_response(payload)
            if status != 0 or b"ENDED s2" not in stdout or stderr:
                raise AssertionError((status, stdout, stderr))
            proc.stdin.close()
            proc.wait(timeout=5.0)
            s2_dir = Path(env["XDG_RUNTIME_DIR"]) / "sessh" / "s" / "s2"
            wait_missing(s2_dir / "s")
            wait_missing(s2_dir / "compat")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)

        for expected_id in ("s3", "s4"):
            proc = subprocess.Popen(
                [str(BIN), ":internal-host-broker:"],
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
                send_frame(conn, 0x0011, pack_session_new(shell))
                message_type, payload = recv_frame(conn)
                if message_type != 0x0021:
                    raise AssertionError((expected_id, message_type, payload))
                unpack_session_attached(payload)
                recv_draw_until(conn, b"BROKER_COMMAND_READY")
                proc.stdin.close()
                proc.wait(timeout=5.0)
                wait_file(Path(env["XDG_RUNTIME_DIR"]) / "sessh" / "s" / expected_id / "detached")
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=2.0)

        proc = subprocess.Popen(
            [str(BIN), ":internal-host-broker:"],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        conn = FdConn(proc.stdout.fileno(), proc.stdin.fileno())
        try:
            send_hello(conn)
            send_frame(conn, 0x0010, pack_command("kill-all"))
            message_type, payload = recv_frame(conn)
            if message_type != 0x0020:
                raise AssertionError(f"expected COMMAND_RESPONSE, got {message_type:#06x}")
            status, stdout, stderr = unpack_command_response(payload)
            if status != 0 or b"KILLING_ALL" not in stdout or stderr:
                raise AssertionError((status, stdout, stderr))
            proc.stdin.close()
            proc.wait(timeout=5.0)
            for expected_id in ("s3", "s4"):
                session_dir = Path(env["XDG_RUNTIME_DIR"]) / "sessh" / "s" / expected_id
                wait_missing(session_dir / "s")
                wait_missing(session_dir / "compat")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)


def spawn_client(env, extra_args=None):
    extra_args = extra_args or []
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(env)
        os.execv(str(BIN), [str(BIN), ":local:", *extra_args])
    return pid, fd


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


def sessions(stdout):
    result = {}
    for line in stdout.splitlines()[1:]:
        if not line.strip():
            continue
        session_id, attached, pid = line.split("\t")
        result[session_id] = {"attached": attached, "pid": pid}
    return result


def run_env_config_client_test(tmp_root):
    env = isolated_env(Path(tmp_root) / "env-config")
    env["SHELL"] = "/bin/sh"
    cleanup_runtime(env)

    config_dir = Path(env["XDG_CONFIG_HOME"]) / "sessh"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "sessh.env").write_text(
        "leader=CTRL-B\nscrollback-limit=80\ninitial-scrollback=0\n"
    )

    try:
        pid, fd = spawn_client(env)
        try:
            read_until(fd, b"$ ")
            os.write(
                fd,
                b"i=1; while [ $i -le 40 ]; do printf 'cfg_%03d\\n' $i; i=$((i + 1)); done\n",
            )
            read_until(fd, b"cfg_040")
            os.write(fd, b"\x02d")
            read_until(fd, b"sessh: detached")
        finally:
            close_client(pid, fd)

        wait_log_contains(Path(env["XDG_RUNTIME_DIR"]) / "sessh" / "s" / "s1" / "agent.log", "scrollback_rows=80")

        pid, fd = spawn_client(env, ["--attach"])
        try:
            attached = read_until(fd, b"$ ")
            if b"cfg_001" in attached:
                raise AssertionError(f"initial-scrollback=0 replayed retained history: {attached!r}")
            if b"cfg_040" not in attached:
                raise AssertionError(f"initial-scrollback=0 did not draw current screen: {attached!r}")
            os.write(fd, b"~.")
        finally:
            close_client(pid, fd)

        killed = run([":local:", "--kill", "s1"], env, check=True, timeout=5.0)
        if "ENDED s1" not in killed.stdout:
            raise AssertionError(killed.stdout)

        (config_dir / "sessh.env").write_text("leader=None\n")
        pid, fd = spawn_client(env, ["--leader", "CTRL-B"])
        try:
            read_until(fd, b"$ ")
            os.write(fd, b"\x02d")
            read_until(fd, b"sessh: detached")
        finally:
            close_client(pid, fd)

        killed = run([":local:", "--kill", "s2"], env, check=True, timeout=5.0)
        if "ENDED s2" not in killed.stdout:
            raise AssertionError(killed.stdout)
    finally:
        cleanup_runtime(env)


def main():
    if not BIN.exists():
        raise SystemExit(f"missing binary: {BIN}")

    with tempfile.TemporaryDirectory(prefix="sessh-harness-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        cleanup_runtime(env)

        try:
            help_text = run(["--help"], env, timeout=5.0)
            if help_text.returncode != 0 or "sessh [ssh-options] HOST [sessh-options]" not in help_text.stdout:
                raise AssertionError(help_text)
            if ":local:" in help_text.stdout:
                raise AssertionError(help_text.stdout)
            short_help_text = run(["-h"], env, timeout=5.0)
            if short_help_text.returncode != 0 or short_help_text.stdout != help_text.stdout:
                raise AssertionError(short_help_text)

            bad = run([":local:", "/tmp/not-a-socket-path"], env, timeout=5.0)
            if bad.returncode != 64:
                raise AssertionError(bad)

            for bare_command in (["list"], ["kill", "s1"], ["kill-all"]):
                bad = run([":local:", *bare_command], env, timeout=5.0)
                if bad.returncode != 64:
                    raise AssertionError((bare_command, bad))

            old_socket = run(["--socket", "--list"], env, timeout=5.0)
            if old_socket.returncode != 64 or "unsupported ssh option" not in old_socket.stderr:
                raise AssertionError(old_socket)

            bad = run([":local:", "--leader", "CTRL-C", "--list"], env, timeout=5.0)
            if bad.returncode != 64:
                raise AssertionError(bad)

            bad = run([":local:", "--scrollback-limit", "0"], env, timeout=5.0)
            if bad.returncode != 64:
                raise AssertionError(bad)

            stopped = run([":local:", "--kill-all"], env, timeout=5.0)
            if stopped.returncode != 0 or stopped.stdout != "KILLING_ALL\n":
                raise AssertionError(stopped)
            stopped_alias = run([":local:", "--killall"], env, timeout=5.0)
            if stopped_alias.returncode != 0 or stopped_alias.stdout != "KILLING_ALL\n":
                raise AssertionError(stopped_alias)
            if sessions_dir(env).exists() and any(sessions_dir(env).iterdir()):
                raise AssertionError("kill-all started a session agent")

            run_login_shell_profile_test(env)
            run_session_agent_crash_client_error_test(env)
            run_session_agent_registry_test(env)
            run_host_broker_starts_session_agent_test(env)
            run_host_broker_registry_commands_test(env)
            run_minor_version_compatibility_test(env)
            run_live_draw_protocol_test(env)
            run_ping_protocol_test(env)
            run_unrecognized_frame_protocol_test(env)
            run_plain_scroll_protocol_test(env)
            run_plain_screen_protocol_test(env)
            run_split_escape_tail_is_not_passthrough_test(env)
            run_active_screen_protocol_test(env)
            run_terminal_modes_protocol_test(env)
            run_cursor_shape_protocol_test(env)
            run_state_only_client_render_test(env)
            run_display_clear_not_forwarded_test(env)
            run_title_protocol_test(env)
            run_default_colors_protocol_test(env)
            run_seeded_default_color_query_protocol_test(env)
            run_complex_ui_query_protocol_test(env)
            run_scrollback_attach_draw_protocol_test(env)
            run_scrollback_clear_protocol_test(env)
            run_reconnect_scrollback_gap_protocol_test(env)
            run_resize_epoch_does_not_clear_reconnect_scrollback_test(env)
            run_slow_attachment_does_not_block_commands_test(env)
            run_env_config_client_test(tmp)

            listed = run([":local:", "--list"], env, check=True, timeout=5.0)
            if "ID\tATTACHED\tPID" not in listed.stdout:
                raise AssertionError(listed.stdout)

            pid, fd = spawn_client(env)
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"echo TERM=$TERM\n")
                read_until(fd, b"TERM=xterm-256color")
                os.write(fd, b"echo SESSH_ID=$SESSH_ID\n")
                read_until(fd, b"SESSH_ID=s1")
                os.write(fd, b"echo sessh_before_reconnect\n")
                read_until_count(fd, b"sessh_before_reconnect", 2)
                os.write(fd, b"~.")
                read_until(fd, startup_cwd_title_sequence(), timeout=2.0)
            finally:
                close_client(pid, fd)

            listed = run([":local:", "--list"], env, check=True, timeout=5.0)
            if "ID\tATTACHED\tPID" not in listed.stdout:
                raise AssertionError(listed.stdout)
            if "s1\tno\t" not in listed.stdout:
                raise AssertionError(listed.stdout)

            pid, fd = spawn_client(env, ["--attach"])
            closed = False
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"echo sessh_after_reconnect\n")
                read_until_count(fd, b"sessh_after_reconnect", 2)
                os.write(fd, b"exit\n")
                wait_child_draining_fd(pid, fd)
                os.close(fd)
                closed = True
            finally:
                if not closed:
                    close_client(pid, fd)

            pid, fd = spawn_client(env, ["--scrollback-limit", "7"])
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"~.")
            finally:
                close_client(pid, fd)

            listed = run([":local:", "--list"], env, check=True, timeout=5.0)
            current_sessions = sessions(listed.stdout)
            if "s2" not in current_sessions:
                raise AssertionError(listed.stdout)

            killed = run([":local:", "--kill", "s2"], env, check=True, timeout=5.0)
            if "ENDED s2" not in killed.stdout:
                raise AssertionError(killed.stdout)

            listed = run([":local:", "--list"], env, check=True, timeout=5.0)
            if "s2" in sessions(listed.stdout):
                raise AssertionError(listed.stdout)

            missing = run([":local:", "--kill", "missing"], env, timeout=5.0)
            if missing.returncode != 1 or "ERROR session not found" not in missing.stderr:
                raise AssertionError(missing)

            pid, fd = spawn_client(env, ["--leader", "CTRL-B"])
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"\x02d")
            finally:
                close_client(pid, fd)

            listed = run([":local:", "--list"], env, check=True, timeout=5.0)
            current_sessions = sessions(listed.stdout)
            if current_sessions.get("s3", {}).get("attached") != "no":
                raise AssertionError(listed.stdout)

            killed = run([":local:", "--kill", "s3"], env, check=True, timeout=5.0)
            if "ENDED s3" not in killed.stdout:
                raise AssertionError(killed.stdout)

            pid, fd = spawn_client(env, ["--leader", "CTRL-B"])
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"echo sessh_before_sever\n")
                read_until_count(fd, b"sessh_before_sever", 2)
                os.write(fd, b"\x02s")
                read_until(fd, b"sessh: reconnecting")
                os.write(fd, b"echo sessh_after_sever\n")
                read_until_count(fd, b"sessh_after_sever", 2)
                os.write(fd, b"~.")
            finally:
                close_client(pid, fd)

            killed = run([":local:", "--kill", "s4"], env, check=True, timeout=5.0)
            if "ENDED s4" not in killed.stdout:
                raise AssertionError(killed.stdout)

            pid1, fd1 = spawn_client(env)
            try:
                read_until(fd1, b"$ ")
                listed = run([":local:", "--list"], env, check=True, timeout=5.0)
                current_sessions = sessions(listed.stdout)
                if current_sessions.get("s5", {}).get("attached") != "yes":
                    raise AssertionError(listed.stdout)

                pid2, fd2 = spawn_client(env, ["--attach", "s5"])
                try:
                    read_until(fd2, b"$ ")
                    os.write(fd2, b"echo sessh_multi_from_second\n")
                    read_until_count(fd1, b"sessh_multi_from_second", 2)
                    os.write(fd1, b"echo sessh_multi_attach\n")
                    read_until_count(fd2, b"sessh_multi_attach", 2)
                    os.write(fd2, b"~.")
                finally:
                    close_client(pid2, fd2)
                os.write(fd1, b"~.")
            finally:
                close_client(pid1, fd1)

            killed = run([":local:", "--kill", "s5"], env, check=True, timeout=5.0)
            if "ENDED s5" not in killed.stdout:
                raise AssertionError(killed.stdout)

            drain_done = Path(env["XDG_RUNTIME_DIR"]) / "detached_drain_done"
            pid, fd = spawn_client(env)
            try:
                read_until(fd, b"$ ")
                os.write(
                    fd,
                    b"python3 -c 'import os,sys; sys.stdout.write(\"x\"*200000); sys.stdout.flush(); open(os.environ[\"XDG_RUNTIME_DIR\"]+\"/detached_drain_done\",\"w\").write(\"done\")'\n",
                )
                # Wait for real command output, not text from the echoed command
                # line; PTY wrapping can split the path substring.
                read_until(fd, b"x" * 64)
                os.write(fd, b"~.")
            finally:
                close_client(pid, fd)
            wait_file(drain_done)

            killed = run([":local:", "--kill", "s6"], env, check=True, timeout=5.0)
            if "ENDED s6" not in killed.stdout:
                raise AssertionError(killed.stdout)

            log_path = Path(env["XDG_RUNTIME_DIR"]) / "sessh" / "s" / "s6" / "agent.log"
            log_text = wait_log_contains(log_path, "event=session_agent_stop")
            for needle in (
                "event=session_agent_start id=s6",
                "event=session_create id=s6",
                "event=attach id=s6",
                "event=detach id=s6",
                "event=session_kill_requested id=s6",
                "event=session_end id=s6",
                "event=session_agent_stop",
            ):
                if needle not in log_text:
                    raise AssertionError(f"missing session-agent log entry {needle!r}; log was {log_text!r}")

            stopped = run([":local:", "--kill-all"], env, check=True, timeout=5.0)
            if "KILLING_ALL" not in stopped.stdout:
                raise AssertionError(stopped.stdout)
        finally:
            cleanup_runtime(env)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"socket_harness: {exc}", file=sys.stderr)
        raise
