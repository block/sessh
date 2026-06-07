#!/usr/bin/env python3
import os
import pty
import re
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import json
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
_FRAME_HEADER_LEN = 4
_LAST_RESIZE = (24, 80)
_NEXT_REPAINT_REQUEST_SEQ = 1
_SCROLLBACK_CURSOR_LEN = 16
_GUID_RE = re.compile(r"^s-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_COMPACT_GUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")

HELLO_REQUEST = "hello_request"
HELLO_OK = "hello_ok"
HELLO_ERROR = "hello_error"
ERROR = "error"
TERMINAL_STREAM_OPEN = "te_stream_open"
SESSION_CREATE = TERMINAL_STREAM_OPEN
SESSION_ATTACH = TERMINAL_STREAM_OPEN
INPUT = "te_input"
RESIZE = "te_resize"
REPAINT_REQUEST = "te_repaint_request"
SESSION_ATTACHED = "te_session_attached"
SESSION_ENDED = "te_session_ended"
DRAW = "te_draw"
REPAINT_RESPONSE = "te_repaint_response"
INPUT_ACK = "te_input_ack"
SESSION_CLIENT_CONTROL_RESPONSE = "te_session_client_control_response"
SESSION_CLIENT_DEBUG_SEVER_CONNECTION_REQUEST = "te_session_client_debug_sever_connection_request"
SESSION_CLIENT_DEBUG_UNRESPONSIVE_CONNECTION_REQUEST = "te_session_client_debug_unresponsive_connection_request"
PING = "ping"
PONG = "pong"

_HELLO_FRAME_FIELDS = {
    HELLO_REQUEST: HELLO_REQUEST,
    HELLO_OK: HELLO_OK,
    HELLO_ERROR: HELLO_ERROR,
}
_FRAME_FIELDS = {
    ERROR: ERROR,
    PING: PING,
    PONG: PONG,
}
_TE_STREAM_ITEM_FIELDS = {
    TERMINAL_STREAM_OPEN: "open",
    INPUT: "input",
    RESIZE: "resize",
    REPAINT_REQUEST: "repaint_request",
    SESSION_ATTACHED: "session_attached",
    SESSION_ENDED: "session_ended",
    DRAW: "draw",
    REPAINT_RESPONSE: "repaint_response",
    INPUT_ACK: "input_ack",
    SESSION_CLIENT_CONTROL_RESPONSE: "session_client_control_response",
    SESSION_CLIENT_DEBUG_SEVER_CONNECTION_REQUEST: "debug_sever_connection_request",
    SESSION_CLIENT_DEBUG_UNRESPONSIVE_CONNECTION_REQUEST: "debug_unresponsive_connection_request",
}


def test_session_guid(index):
    return f"s-{index:08x}-0000-4000-8000-{index:012x}"


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


def run_public(args, env, **kwargs):
    return subprocess.run(
        [str(BIN), *args],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        **kwargs,
    )


def run(args, env, **kwargs):
    return run_public(args, env, **kwargs)


def sessh_version():
    for line in (ROOT / "src" / "core" / "config.zig").read_text().splitlines():
        if line.startswith("pub const version = "):
            return line.split('"')[1]
    raise AssertionError("could not find sessh version")


KITTY_KEYBOARD_QUERY = b"\x1b[?u"
KITTY_KEYBOARD_STATUS_RESPONSE = b"\x1b[?0u"
SYNCHRONIZED_UPDATE_START = b"\x1b[?2026h"
SYNCHRONIZED_UPDATE_END = b"\x1b[?2026l"
kitty_keyboard_status_response = KITTY_KEYBOARD_STATUS_RESPONSE


def read_pty_chunk(fd):
    chunk = os.read(fd, 4096)
    for _ in range(chunk.count(KITTY_KEYBOARD_QUERY)):
        os.write(fd, kitty_keyboard_status_response)
    return chunk


def synchronized_draw_body(output):
    if output.startswith(SYNCHRONIZED_UPDATE_START) and output.endswith(SYNCHRONIZED_UPDATE_END):
        return output[len(SYNCHRONIZED_UPDATE_START) : -len(SYNCHRONIZED_UPDATE_END)]
    return output


def read_until(fd, needle, timeout=5.0):
    end = time.monotonic() + timeout
    data = b""
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        chunk = read_pty_chunk(fd)
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
        chunk = read_pty_chunk(fd)
        if not chunk:
            break
        data += chunk
        if data.count(needle) >= count:
            return data
    raise AssertionError(f"did not see {count} copies of {needle!r}; saw {data!r}")


def send_escape_detach(fd):
    os.write(fd, b"\n")
    time.sleep(0.05)
    os.write(fd, b"~.\n")


def read_available(fd, timeout=0.2):
    end = time.monotonic() + timeout
    data = b""
    while time.monotonic() < end:
        ready, _, _ = select.select([fd], [], [], 0.02)
        if not ready:
            continue
        chunk = read_pty_chunk(fd)
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
                    if not read_pty_chunk(fd):
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


def wait_sticky(path, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if os.lstat(path).st_mode & stat.S_ISVTX:
                return
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    raise AssertionError(f"sticky bit was not set: {path}")


def wait_missing(path, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if not os.path.lexists(path):
            return
        time.sleep(0.05)
    raise AssertionError(f"file still exists: {path}")


def unlink_existing(path):
    try:
        path.unlink()
    except FileNotFoundError:
        raise AssertionError(f"expected file to exist before deletion: {path}")


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
    handshake_generated = output_dir / "sessh_handshake_pb2.py"
    handshake_spec = importlib.util.spec_from_file_location("sessh_handshake_pb2", handshake_generated)
    handshake_module = importlib.util.module_from_spec(handshake_spec)
    sys.modules["sessh_handshake_pb2"] = handshake_module
    handshake_spec.loader.exec_module(handshake_module)
    _PROTO_HANDSHAKE_MODULE = handshake_module

    generated = output_dir / "sessh_pb2.py"
    spec = importlib.util.spec_from_file_location("sessh_pb2", generated)
    module = importlib.util.module_from_spec(spec)
    sys.modules["sessh_pb2"] = module
    spec.loader.exec_module(module)
    _PROTO_MODULE = module
    return module


def sessh_hpb():
    if _PROTO_HANDSHAKE_MODULE is None:
        sessh_pb()
    return _PROTO_HANDSHAKE_MODULE


def pack_input(value, input_seq=0):
    return sessh_pb().TeInput(data=value, input_seq=input_seq).SerializeToString()


def pack_bytes(value):
    return pack_input(value)


def pack_session_create(
    shell,
    scrollback=2000,
    fg=0xFFFFFFFF,
    bg=0xFFFFFFFF,
    session_id=None,
    command_argv=None,
    shell_command=None,
    tty_settings=None,
    initial_scrollback=None,
):
    global _NEXT_REPAINT_REQUEST_SEQ
    pb = sessh_pb()
    message = pb.TeStreamOpen()
    create = message.create
    create.scrollback_row_limit = scrollback
    if session_id is None:
        session_id = test_session_guid(1)
    message.session_guid = guid_for_ref(session_id)
    rows, cols = _LAST_RESIZE
    message.resize.terminal_rows = rows
    message.resize.terminal_cols = cols
    repaint = message.resize.repaint_request
    repaint.repaint_request_seq = _NEXT_REPAINT_REQUEST_SEQ
    _NEXT_REPAINT_REQUEST_SEQ += 1
    if initial_scrollback != 0:
        repaint.scrollback_cursor = b""
    if initial_scrollback is not None:
        repaint.initial_scrollback_rows = initial_scrollback
    entry = create.environment.add()
    entry.name = "SHELL"
    entry.value = str(shell)
    if command_argv:
        create.exec_command.argv.extend(str(arg) for arg in command_argv)
    if shell_command is not None:
        create.shell_command.command = str(shell_command)
    if tty_settings is not None:
        if "term" in tty_settings:
            create.tty_settings.term = tty_settings["term"]
        for opcode, value in tty_settings.get("modes", ()):
            mode = create.tty_settings.tty_mode.add()
            mode.opcode = opcode
            mode.value = value
    create.query_default_colors.foreground_color = fg
    create.query_default_colors.background_color = bg
    return message.SerializeToString()


def pack_session_attach(initial_scrollback=None, reconnect_cursor=None, session_guid="", session_dir_path=""):
    global _NEXT_REPAINT_REQUEST_SEQ
    pb = sessh_pb()
    message = pb.TeStreamOpen()
    message.session_guid = session_guid
    _ = session_dir_path
    rows, cols = _LAST_RESIZE
    message.resize.terminal_rows = rows
    message.resize.terminal_cols = cols
    repaint = message.resize.repaint_request
    repaint.repaint_request_seq = _NEXT_REPAINT_REQUEST_SEQ
    _NEXT_REPAINT_REQUEST_SEQ += 1
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
    message = sessh_pb().TeResize(terminal_rows=rows, terminal_cols=cols)
    if viewport_offset is not None:
        message.viewport_offset = viewport_offset
    if repaint is not None:
        if len(repaint) == 2:
            repaint_request_seq, scrollback_cursor = repaint
            scrollback_epoch = 0
        else:
            repaint_request_seq, scrollback_epoch, scrollback_cursor = repaint
        message.repaint_request.repaint_request_seq = repaint_request_seq
        message.repaint_request.scrollback_cursor = encode_request_scrollback_cursor(scrollback_epoch, scrollback_cursor)
    send_frame(conn, RESIZE, message.SerializeToString())


def send_resize_screen_repaint(conn, rows, cols, repaint_request_seq, viewport_offset=None):
    global _LAST_RESIZE
    _LAST_RESIZE = (rows, cols)
    message = sessh_pb().TeResize(terminal_rows=rows, terminal_cols=cols)
    if viewport_offset is not None:
        message.viewport_offset = viewport_offset
    message.repaint_request.repaint_request_seq = repaint_request_seq
    send_frame(conn, RESIZE, message.SerializeToString())


def pack_repaint(repaint_request_seq, scrollback_cursor=None, scrollback_epoch=0):
    message = sessh_pb().TeRepaintRequest(repaint_request_seq=repaint_request_seq)
    if scrollback_cursor is not None:
        message.scrollback_cursor = encode_request_scrollback_cursor(scrollback_epoch, scrollback_cursor)
    return message.SerializeToString()


def parse_input_ack(payload):
    message = sessh_pb().TeInputAck()
    message.ParseFromString(payload)
    return message.input_seq


def parse_session_ended(payload):
    message = sessh_pb().TeSessionEnded()
    message.ParseFromString(payload)
    return message


def assert_session_attached(payload):
    message = sessh_pb().TeSessionAttached()
    message.ParseFromString(payload)
    return message


def create_and_attach_session(
    conn,
    shell,
    scrollback=2000,
    fg=0xFFFFFFFF,
    bg=0xFFFFFFFF,
    session_id=None,
    initial_scrollback=None,
    command_argv=None,
    shell_command=None,
    tty_settings=None,
):
    send_frame(
        conn,
        SESSION_CREATE,
        pack_session_create(
            shell,
            scrollback=scrollback,
            fg=fg,
            bg=bg,
            session_id=session_id,
            command_argv=command_argv,
            shell_command=shell_command,
            tty_settings=tty_settings,
            initial_scrollback=initial_scrollback,
        ),
    )


def parse_draw(payload):
    message = sessh_pb().TeDraw()
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
        "attached_client_end_restore_bytes": message.attached_client_end_restore_bytes if message.HasField("attached_client_end_restore_bytes") else None,
    }


def parse_repaint_response(payload):
    message = sessh_pb().TeRepaintResponse()
    message.ParseFromString(payload)
    if not message.HasField("draw"):
        raise AssertionError(f"missing repaint response draw: {payload!r}")
    return message.repaint_request_seq, parse_draw(message.draw.SerializeToString())


def recv_draw(conn, timeout=5.0):
    old_timeout = conn.gettimeout()
    conn.settimeout(timeout)
    try:
        while True:
            message_kind, payload = recv_frame(conn)
            if message_kind == DRAW:
                draw = parse_draw(payload)
                return draw
            if message_kind == REPAINT_RESPONSE:
                response_id, draw = parse_repaint_response(payload)
                draw["repaint_request_seq"] = response_id
                return draw
            if message_kind == SESSION_ENDED:
                raise AssertionError("session ended before DRAW arrived")
    finally:
        conn.settimeout(old_timeout)


def recv_repaint_response(conn, timeout=5.0):
    old_timeout = conn.gettimeout()
    conn.settimeout(timeout)
    try:
        while True:
            message_kind, payload = recv_frame(conn)
            if message_kind == REPAINT_RESPONSE:
                response_id, draw = parse_repaint_response(payload)
                return response_id, draw
            if message_kind == SESSION_ENDED:
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


def recv_until_message(conn, expected_kind, timeout=5.0):
    old_timeout = conn.gettimeout()
    conn.settimeout(timeout)
    end = time.monotonic() + timeout
    try:
        while time.monotonic() < end:
            message_kind, payload = recv_frame(conn)
            if message_kind == expected_kind:
                return payload
    finally:
        conn.settimeout(old_timeout)
    raise AssertionError(f"did not receive message kind {expected_kind}")


def send_frame(conn, message_kind, payload=b""):
    body = encode_frame_body(message_kind, payload)
    conn.sendall(struct.pack(">I", len(body)) + body)


def encode_frame_body(message_kind, payload):
    if message_kind in _HELLO_FRAME_FIELDS:
        frame = sessh_hpb().HelloFrame()
        set_submessage(frame, _HELLO_FRAME_FIELDS[message_kind], payload)
        return frame.SerializeToString()
    if message_kind in _FRAME_FIELDS:
        frame = sessh_pb().Frame()
        set_submessage(frame, _FRAME_FIELDS[message_kind], payload)
        return frame.SerializeToString()
    if message_kind in _TE_STREAM_ITEM_FIELDS:
        frame = sessh_pb().Frame()
        item = sessh_pb().TeStreamItem()
        set_submessage(item, _TE_STREAM_ITEM_FIELDS[message_kind], payload)
        frame.te_stream_item.CopyFrom(item)
        return frame.SerializeToString()
    raise AssertionError(f"unknown test message kind: {message_kind}")


def set_submessage(frame, field_name, payload):
    field = frame.DESCRIPTOR.fields_by_name[field_name]
    submessage = field.message_type._concrete_class()
    submessage.ParseFromString(payload)
    getattr(frame, field_name).CopyFrom(submessage)


def recv_frame(conn):
    header = recv_exact(conn, _FRAME_HEADER_LEN)
    (payload_len,) = struct.unpack(">I", header)
    body = recv_exact(conn, payload_len)
    hello_frame = sessh_hpb().HelloFrame()
    hello_frame.ParseFromString(body)
    hello_field = hello_frame.WhichOneof("payload")
    if hello_field is not None:
        return hello_field, getattr(hello_frame, hello_field).SerializeToString()

    frame = sessh_pb().Frame()
    frame.ParseFromString(body)
    field = frame.WhichOneof("payload")
    if field is None:
        raise AssertionError(f"missing frame payload: {body!r}")
    if field == "te_stream_item":
        item = frame.te_stream_item
        item_field = item.WhichOneof("payload")
        if item_field is None:
            raise AssertionError(f"missing terminal stream item payload: {body!r}")
        for message_kind, mapped_field in _TE_STREAM_ITEM_FIELDS.items():
            if mapped_field == item_field:
                return message_kind, getattr(item, item_field).SerializeToString()
        raise AssertionError(f"unknown terminal stream item payload: {item_field}")
    return field, getattr(frame, field).SerializeToString()


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
    return Path(runtime_dir) / "guid"


def runtime_root(env):
    return Path(env["XDG_RUNTIME_DIR"])


def state_root(env):
    return Path(env["XDG_STATE_HOME"]) / "sessh"


def state_sessions_dir(env):
    return state_root(env) / "guid"


def is_guid_ref(value):
    return bool(_GUID_RE.match(value) or _COMPACT_GUID_RE.match(value))


def compact_guid(guid):
    if _COMPACT_GUID_RE.match(guid):
        return guid.lower()
    if not _GUID_RE.match(guid):
        raise AssertionError(f"invalid guid: {guid}")
    return guid[2:].replace("-", "").lower()


def guid_for_ref(ref):
    if _GUID_RE.match(ref):
        return ref.lower()
    if _COMPACT_GUID_RE.match(ref):
        compact = ref.lower()
        return f"s-{compact[0:8]}-{compact[8:12]}-{compact[12:16]}-{compact[16:20]}-{compact[20:32]}"
    raise AssertionError(f"invalid guid ref: {ref}")


def write_cached_remote_route(env, session_id, host, guid=None, alive=True, runtime_version="cached-test"):
    guid = guid_for_ref(guid) if guid is not None else guid_for_ref(session_id)
    route_dir = state_sessions_dir(env) / guid
    route_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    remote_session_dir = f"/tmp/sessh-remote/guid/{guid}"
    (route_dir / "route.json").write_text(
        json.dumps(
            {
                "guid": guid,
                "session_dir": remote_session_dir,
                "host": host,
                "runtime_version": runtime_version,
                "alive": alive,
                "ssh_options": [],
            },
            separators=(",", ":"),
        )
        + "\n"
    )


def assert_runtime_dir_symlink(env, expected_runtime_root):
    link = Path(env["XDG_CACHE_HOME"]) / "sessh" / "runtime_dir"
    if not link.is_symlink():
        raise AssertionError(f"runtime dir pointer is missing: {link}")
    actual = Path(os.readlink(link))
    if actual != Path(expected_runtime_root):
        raise AssertionError(f"runtime dir pointer target mismatch: expected {expected_runtime_root}, got {actual}")


def session_dir(env, session_id=None):
    if session_id is None:
        session_id = test_session_guid(1)
    return sessions_dir(env) / guid_for_ref(session_id)


def route_file(env, session_id=None):
    if session_id is None:
        session_id = test_session_guid(1)
    return state_sessions_dir(env) / guid_for_ref(session_id) / "route.json"


def runtime_log_file(env, session_id=None):
    return route_file(env, session_id).parent / "runtime.log"


def socket_path(env, session_id=None):
    _ = session_id
    return runtime_root(env) / "d" / "sesshd.sock"


def start_daemon(env, session_id=None):
    _ = session_id
    path = socket_path(env, session_id)
    proc = subprocess.Popen(
        [str(BIN), ":internal-daemon:"],
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    wait_file(path)
    return proc


def session_runtime_pids(env):
    pids = []
    root = sessions_dir(env)
    if root.exists():
        for meta_file in sorted(root.glob("*/meta.json")):
            try:
                meta = json.loads(meta_file.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            pid = meta.get("runtime_pid")
            if isinstance(pid, int):
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
        [str(BIN), ":internal-broker:"],
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
        [str(BIN), ":internal-daemon:"],
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    socket_path = Path(env["XDG_RUNTIME_DIR"]) / "d" / "sesshd.sock"
    try:
        wait_file(socket_path)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(5.0)
            sock.connect(str(socket_path))
            send_hello(sock)
            send_frame(sock, PING, sessh_pb().Ping().SerializeToString())
            message_type, payload = recv_frame(sock)
            if message_type != PONG:
                raise AssertionError(f"expected PONG from sesshd, got {message_type}")
            pong = sessh_pb().Pong()
            pong.ParseFromString(payload)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5.0)
        cleanup_runtime(env)


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

            broker_hello(env, minor_delta=1)
            broker_hello(env, version_override="0.0.0-compatible-test")
            broker_hello(env, major_delta=1)
            broker_hello(env, major_delta=-1, expect_ok=False)
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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
            create_and_attach_session(conn, shell)
            message_kind, payload = recv_frame(conn)
            if message_kind != SESSION_ATTACHED:
                raise AssertionError(f"expected SESSION_ATTACHED, got {message_kind}")
            assert_session_attached(payload)
            recv_draw_until(conn, b"EXIT_READY")
            send_frame(conn, INPUT, pack_bytes(b"exit\n"))

            ended = parse_session_ended(recv_until_message(conn, SESSION_ENDED))
            pb = sessh_pb()
            if ended.reason != pb.TE_SESSION_END_REASON_PROCESS_EXITED:
                raise AssertionError(f"unexpected process-exit reason: {ended!r}")
            if not ended.HasField("exit_status"):
                raise AssertionError(f"missing process exit status: {ended!r}")
            if ended.exit_status.kind != pb.EXIT_STATUS_KIND_EXITED or ended.exit_status.status != 7:
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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                draw, draws = recv_draw_until(conn, b"ALT_SCREEN")
                output = b"".join(item["draw_bytes"] for item in draws)
                if b"\x1b[?1049h" not in output:
                    raise AssertionError(f"DRAW should enter outer alternate screen: {draws!r}")
                if b"\x1b[?1049l" in output:
                    raise AssertionError(f"DRAW should not leave outer alternate screen immediately: {draws!r}")
                restore = draw["attached_client_end_restore_bytes"]
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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
    with tempfile.TemporaryDirectory(prefix="sessh-terminal-modes-", dir="/tmp") as tmp:
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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)
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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell, fg=0x010A0B0C, bg=0x010D0E0F)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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
            start_daemon(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, 3, 40)
                create_and_attach_session(conn, shell, scrollback=20)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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

            attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            attach.settimeout(5.0)
            try:
                attach.connect(str(socket_path(env)))
                send_hello(attach)
                send_resize(attach, 3, 40)
                send_frame(
                    attach,
                    SESSION_ATTACH,
                    pack_session_attach(
                        session_guid=test_session_guid(1),
                        session_dir_path=session_dir(env, test_session_guid(1)),
                    ),
                )

                message_type, _ = recv_frame(attach)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")

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
            start_daemon(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, 3, 40)
                create_and_attach_session(conn, shell, scrollback=20)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

                send_frame(conn, INPUT, pack_bytes(b"go\n"))
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
                send_frame(
                    attach,
                    SESSION_ATTACH,
                    pack_session_attach(
                        session_guid=test_session_guid(1),
                        session_dir_path=session_dir(env, test_session_guid(1)),
                    ),
                )

                message_type, _ = recv_frame(attach)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")

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
    start_daemon(env)
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(5.0)
    conn.connect(str(socket_path(env)))
    send_hello(conn)
    send_resize(conn, 3, 40)
    create_and_attach_session(conn, shell, scrollback=scrollback_limit)
    message_type, payload = recv_frame(conn)
    if message_type != SESSION_ATTACHED:
        raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
    assert_session_attached(payload)
    return conn


def attach_gap_session(env, reconnect_cursor=None):
    attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    attach.settimeout(5.0)
    attach.connect(str(socket_path(env)))
    send_hello(attach)
    send_resize(attach, 3, 40)
    send_frame(
        attach,
        SESSION_ATTACH,
        pack_session_attach(
            session_guid=test_session_guid(1),
            session_dir_path=session_dir(env, test_session_guid(1)),
            reconnect_cursor=reconnect_cursor,
        ),
    )
    message_type, _ = recv_frame(attach)
    if message_type != SESSION_ATTACHED:
        raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
    return attach


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

            attach = attach_gap_session(env, reconnect_cursor=cursor)
            try:
                _, reconnect_draws = recv_draw_until(attach, b"DURING_DONE$ ")
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
            conn = start_gap_session(env, shell, scrollback_limit=5)
            try:
                recv_draw_until(conn, b"READY$ ")
                send_frame(conn, INPUT, pack_bytes(b"go\n"))
                _, before_draws = recv_draw_until(conn, b"BEFORE_DONE")
                cursor = (before_draws[-1]["epoch"], before_draws[-1]["scrollback_cursor"])
            finally:
                conn.close()

            time.sleep(0.8)

            attach = attach_gap_session(env, reconnect_cursor=cursor)
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

                send_frame(attach, INPUT, pack_bytes(b"after\n"))
                _, post_draws = recv_draw_until(attach, b"POST:after")
                post_output = b"".join(draw["draw_bytes"] for draw in post_draws)
                if b"POST:after" not in post_output:
                    raise AssertionError(f"post-reconnect input was not delivered: {post_output!r}")
            finally:
                attach.close()

            normal = attach_gap_session(env)
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
            start_daemon(env)

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            try:
                conn.connect(str(socket_path(env)))
                send_hello(conn)
                send_resize(conn, 3, 40)
                create_and_attach_session(conn, shell, scrollback=20)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)

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

            attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            attach.settimeout(5.0)
            try:
                attach.connect(str(socket_path(env)))
                send_hello(attach)
                send_resize(attach, 3, 20)
                send_frame(
                    attach,
                    SESSION_ATTACH,
                    pack_session_attach(
                        session_guid=test_session_guid(1),
                        session_dir_path=session_dir(env, test_session_guid(1)),
                        reconnect_cursor=cursor,
                    ),
                )

                message_type, _ = recv_frame(attach)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")

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
                create_and_attach_session(conn, shell)

                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)
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


def run_session_runtime_crash_client_error_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-runtime-crash-", dir="/tmp") as tmp:
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
            pids = session_runtime_pids(env)
            if len(pids) != 1:
                raise AssertionError(f"expected one session runtime, found {pids}")

            os.kill(pids[0], signal.SIGKILL)
            output += read_until(fd, b"sessh: ssh runtime attach failed", timeout=5.0)
            if b"ssh runtime attach failed" not in output:
                raise AssertionError(output)
            alt_leave = output.rfind(b"\x1b[?1049l")
            if alt_leave < 0:
                raise AssertionError(f"runtime crash did not leave alternate screen: {output!r}")
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


def run_broker_starts_daemon_session_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-broker-", dir="/tmp") as tmp:
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
            [str(BIN), ":internal-broker:"],
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
            create_and_attach_session(conn, shell)
            message_type, payload = recv_frame(conn)
            if message_type != SESSION_ATTACHED:
                raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
            assert_session_attached(payload)
            recv_draw_until(conn, b"BROKER_READY")

            session_1_guid = test_session_guid(1)
            session_path = session_dir(env, session_1_guid)
            meta_file = session_path / "meta.json"
            wait_file(meta_file)
            meta = json.loads(meta_file.read_text())
            if meta.get("type") != "local-session" or meta.get("version") != sessh_version():
                raise AssertionError(meta)
            if not os.path.islink(session_path / "compat"):
                raise AssertionError("broker session did not write compat symlink")
            assert_runtime_dir_symlink(env, Path(env["XDG_RUNTIME_DIR"]))

            send_frame(conn, INPUT, pack_bytes(b"exit\n"))
            recv_until_message(conn, SESSION_ENDED)
            proc.stdin.close()
            proc.wait(timeout=5.0)
            if proc.returncode != 0:
                raise AssertionError(proc.stderr.read().decode("utf-8", "replace"))
            wait_missing(session_path / "compat")
            wait_missing(session_path)
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
    if extra_args and extra_args[0] == "attach":
        return spawn_bin(env, ["attach", *extra_args[1:]])
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
            send_escape_detach(fd)
            output = read_until(fd, b"sessh: detached")
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


def main():
    if not BIN.exists():
        raise SystemExit(f"missing binary: {BIN}")

    with tempfile.TemporaryDirectory(prefix="sessh-harness-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        cleanup_runtime(env)

        try:
            help_text = run(["--help"], env, timeout=5.0)
            if help_text.returncode != 0 or "sessh [ssh-option" not in help_text.stdout:
                raise AssertionError(help_text)
            version_text = run(["--version"], env, timeout=5.0)
            if version_text.returncode != 0 or version_text.stdout != f"sessh {sessh_version()}\n":
                raise AssertionError(version_text)
            short_help_text = run(["-h"], env, timeout=5.0)
            if short_help_text.returncode != 0 or short_help_text.stdout != help_text.stdout:
                raise AssertionError(short_help_text)
            sessh_wrapper = ROOT / "zig-out" / "bin" / "sessh"
            release_artifact_dir = ROOT / "zig-out" / "libexec" / "sessh"
            if sessh_wrapper.exists() and release_artifact_dir.exists() and any(release_artifact_dir.glob("sessh-*")):
                sessh_help = subprocess.run(
                    [str(sessh_wrapper), "--help"],
                    cwd=ROOT,
                    env=env,
                    text=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                    check=False,
                )
                if sessh_help.returncode != 0 or "sessh [ssh-option" not in sessh_help.stdout:
                    raise AssertionError(sessh_help)
                sessh_version_text = subprocess.run(
                    [str(sessh_wrapper), "--version"],
                    cwd=ROOT,
                    env=env,
                    text=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                    check=False,
                )
                if sessh_version_text.returncode != 0 or sessh_version_text.stdout != f"sessh {sessh_version()}\n":
                    raise AssertionError(sessh_version_text)
                sessh_short_version_text = subprocess.run(
                    [str(sessh_wrapper), "-V"],
                    cwd=ROOT,
                    env=env,
                    text=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                    check=False,
                )
                if sessh_short_version_text.returncode != 0 or sessh_short_version_text.stdout != f"sessh {sessh_version()}\n":
                    raise AssertionError(sessh_short_version_text)

            run_login_shell_profile_test(env)
            run_daemon_ping_test(env)
            run_session_create_command_argv_test(env)
            run_session_create_shell_command_test(env)
            run_session_create_tty_settings_test(env)
            run_broker_starts_daemon_session_test(env)
            run_minor_version_compatibility_test(env)
            run_live_draw_protocol_test(env)
            run_synchronized_output_protocol_test(env)
            run_input_ack_protocol_test(env)
            run_session_ended_payload_protocol_test(env)
            run_plain_scroll_protocol_test(env)
            run_plain_screen_protocol_test(env)
            run_split_escape_tail_is_not_replayed_as_text_test(env)
            run_active_screen_protocol_test(env)
            run_active_screen_barrier_protocol_test(env)
            run_terminal_modes_protocol_test(env)
            run_cursor_shape_protocol_test(env)
            run_complete_display_clear_protocol_test(env)
            run_title_protocol_test(env)
            run_default_colors_protocol_test(env)
            run_seeded_default_color_query_protocol_test(env)
            run_complex_ui_query_protocol_test(env)
            run_scrollback_attach_draw_protocol_test(env)
            run_scrollback_clear_protocol_test(env)
            run_reconnect_scrollback_gap_protocol_test(env)
            run_resize_epoch_does_not_clear_reconnect_scrollback_test(env)
            run_screen_repaint_after_presentation_reset_clears_rows_test(env)
        finally:
            cleanup_runtime(env)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"socket_harness: {exc}", file=sys.stderr)
        raise
