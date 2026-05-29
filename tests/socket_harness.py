#!/usr/bin/env python3
import os
import pty
import re
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import json
import tarfile
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
_CLIENT_GUID_RE = re.compile(r"^c-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_COMPACT_GUID_RE = re.compile(r"^[0-9a-fA-F]{32}$")
_NEXT_CLIENT_GUID = 1

HELLO_REQUEST = "hello_request"
HELLO_OK = "hello_ok"
HELLO_ERROR = "hello_error"
ERROR = "error"
SESSION_CREATE = "session_create"
SESSION_ATTACH = "session_attach"
INPUT = "input"
RESIZE = "resize"
REPAINT_REQUEST = "repaint_request"
SESSION_CREATED = "session_created"
SESSION_ATTACHED = "session_attached"
SESSION_ENDED = "session_ended"
DRAW = "draw"
REPAINT_RESPONSE = "repaint_response"
INPUT_ACK = "input_ack"
SESSION_LIVE_STATE_QUERY = "session_live_state_query"
SESSION_LIVE_STATE = "session_live_state"
SESSION_CLIENT_CONTROL_RESPONSE = "session_client_control_response"
CLIENT_REPAINT_REQUEST = "client_repaint_request"
CLIENT_DETACH_REQUEST = "client_detach_request"
SESSION_CLIENT_DETACH_REQUEST = "session_client_detach_request"
SESSION_CLIENT_REPAINT_REQUEST = "session_client_repaint_request"
SESSION_CLIENT_DEBUG_SEVER_CONNECTION_REQUEST = "session_client_debug_sever_connection_request"
SESSION_CLIENT_DEBUG_UNRESPONSIVE_CONNECTION_REQUEST = "session_client_debug_unresponsive_connection_request"

_HELLO_FRAME_FIELDS = {
    HELLO_REQUEST: HELLO_REQUEST,
    HELLO_OK: HELLO_OK,
    HELLO_ERROR: HELLO_ERROR,
}
_FRAME_FIELDS = {
    ERROR: ERROR,
    SESSION_CREATE: SESSION_CREATE,
    SESSION_ATTACH: SESSION_ATTACH,
    INPUT: INPUT,
    RESIZE: RESIZE,
    REPAINT_REQUEST: REPAINT_REQUEST,
    SESSION_CREATED: SESSION_CREATED,
    SESSION_ATTACHED: SESSION_ATTACHED,
    SESSION_ENDED: SESSION_ENDED,
    DRAW: DRAW,
    REPAINT_RESPONSE: REPAINT_RESPONSE,
    INPUT_ACK: INPUT_ACK,
    SESSION_LIVE_STATE_QUERY: SESSION_LIVE_STATE_QUERY,
    SESSION_LIVE_STATE: SESSION_LIVE_STATE,
    SESSION_CLIENT_CONTROL_RESPONSE: SESSION_CLIENT_CONTROL_RESPONSE,
    CLIENT_REPAINT_REQUEST: CLIENT_REPAINT_REQUEST,
    CLIENT_DETACH_REQUEST: CLIENT_DETACH_REQUEST,
    SESSION_CLIENT_DETACH_REQUEST: SESSION_CLIENT_DETACH_REQUEST,
    SESSION_CLIENT_REPAINT_REQUEST: SESSION_CLIENT_REPAINT_REQUEST,
    SESSION_CLIENT_DEBUG_SEVER_CONNECTION_REQUEST: SESSION_CLIENT_DEBUG_SEVER_CONNECTION_REQUEST,
    SESSION_CLIENT_DEBUG_UNRESPONSIVE_CONNECTION_REQUEST: SESSION_CLIENT_DEBUG_UNRESPONSIVE_CONNECTION_REQUEST,
}


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
    return sessh_pb().Input(data=value, input_seq=input_seq).SerializeToString()


def pack_bytes(value):
    return pack_input(value)


def pack_session_create(shell, scrollback=2000, fg=0xFFFFFFFF, bg=0xFFFFFFFF, session_id="s1", command_argv=None):
    pb = sessh_pb()
    message = pb.SessionCreate(scrollback_row_limit=scrollback)
    message.session_guid = guid_for_ref(session_id)
    if not is_guid_ref(session_id):
        message.session_alias = session_id
    rows, cols = _LAST_RESIZE
    message.terminal_size.terminal_rows = rows
    message.terminal_size.terminal_cols = cols
    entry = message.environment.add()
    entry.name = "SHELL"
    entry.value = str(shell)
    if command_argv:
        message.command_argv.extend(str(arg) for arg in command_argv)
    message.query_default_colors.foreground_color = fg
    message.query_default_colors.background_color = bg
    return message.SerializeToString()


def pack_session_attach(initial_scrollback=None, reconnect_cursor=None, session_ref="", client_guid=None):
    global _NEXT_REPAINT_REQUEST_SEQ, _NEXT_CLIENT_GUID
    pb = sessh_pb()
    message = pb.SessionAttach()
    message.session_ref = session_ref
    if client_guid is None:
        client_guid = client_guid_for_index(_NEXT_CLIENT_GUID)
        _NEXT_CLIENT_GUID += 1
    if not _CLIENT_GUID_RE.match(client_guid):
        raise AssertionError(f"invalid client guid: {client_guid}")
    message.client_guid = client_guid
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
    message = sessh_pb().Resize(terminal_rows=rows, terminal_cols=cols)
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
    message = sessh_pb().Resize(terminal_rows=rows, terminal_cols=cols)
    if viewport_offset is not None:
        message.viewport_offset = viewport_offset
    message.repaint_request.repaint_request_seq = repaint_request_seq
    send_frame(conn, RESIZE, message.SerializeToString())


def pack_repaint(repaint_request_seq, scrollback_cursor=None, scrollback_epoch=0):
    message = sessh_pb().RepaintRequest(repaint_request_seq=repaint_request_seq)
    if scrollback_cursor is not None:
        message.scrollback_cursor = encode_request_scrollback_cursor(scrollback_epoch, scrollback_cursor)
    return message.SerializeToString()


def parse_input_ack(payload):
    message = sessh_pb().InputAck()
    message.ParseFromString(payload)
    return message.input_seq


def parse_session_ended(payload):
    message = sessh_pb().SessionEnded()
    message.ParseFromString(payload)
    return message


def assert_session_attached(payload):
    message = sessh_pb().SessionAttached()
    message.ParseFromString(payload)
    return message


def assert_session_created(payload):
    message = sessh_pb().SessionCreated()
    message.ParseFromString(payload)
    return message


def parse_session_live_state(payload):
    message = sessh_pb().SessionLiveState()
    message.ParseFromString(payload)
    return message


def parse_client_repaint_request(payload):
    message = sessh_pb().ClientRepaintRequest()
    message.ParseFromString(payload)
    return message


def create_and_attach_session(conn, shell, scrollback=2000, fg=0xFFFFFFFF, bg=0xFFFFFFFF, session_id="s1", initial_scrollback=None, command_argv=None, client_guid=None):
    send_frame(conn, SESSION_CREATE, pack_session_create(shell, scrollback=scrollback, fg=fg, bg=bg, session_id=session_id, command_argv=command_argv))
    assert_session_created(recv_until_message(conn, SESSION_CREATED))
    send_frame(conn, SESSION_ATTACH, pack_session_attach(initial_scrollback=initial_scrollback, client_guid=client_guid))


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


def client_route_hint_file(env, client_guid):
    return runtime_root(env) / "guid" / client_guid / "route.json"


def client_agent_socket_hint_file(env, client_guid):
    return runtime_root(env) / "guid" / client_guid / "agent.sock"


def aliases_dir(env):
    return state_root(env) / "alias"


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
    match = re.fullmatch(r"s([0-9]+)", ref)
    if not match:
        raise AssertionError(f"test alias cannot be mapped to a deterministic guid: {ref}")
    return f"s-00000000-0000-4000-8000-{int(match.group(1)):012x}"


def client_guid_for_index(index):
    return f"c-00000000-0000-4000-8000-{index:012x}"


def ensure_alias(env, alias, guid=None):
    guid = guid_for_ref(guid) if guid is not None else guid_for_ref(alias)
    alias_path = aliases_dir(env) / alias
    alias_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if alias_path.exists() or alias_path.is_symlink():
        return
    alias_path.symlink_to(Path("../guid") / guid)


def write_cached_remote_route(env, alias, host, guid=None, alive=True, agent_version="cached-test"):
    guid = guid_for_ref(guid) if guid is not None else guid_for_ref(alias)
    ensure_alias(env, alias, guid)
    route_dir = state_sessions_dir(env) / guid
    route_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    remote_session_dir = f"/tmp/sessh-remote/guid/{guid}"
    (route_dir / "route.json").write_text(
        json.dumps(
            {
                "guid": guid,
                "primary_alias": alias,
                "session_dir": remote_session_dir,
                "host": host,
                "agent_version": agent_version,
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


def session_dir(env, session_id="s1"):
    if is_guid_ref(session_id):
        return sessions_dir(env) / guid_for_ref(session_id)
    ensure_alias(env, session_id)
    alias_path = aliases_dir(env) / session_id
    if alias_path.is_symlink():
        return sessions_dir(env) / guid_for_ref(Path(os.readlink(alias_path)).name)
    return sessions_dir(env) / guid_for_ref(session_id)


def route_file(env, session_id="s1"):
    if is_guid_ref(session_id):
        return state_sessions_dir(env) / guid_for_ref(session_id) / "route.json"
    ensure_alias(env, session_id)
    alias_path = aliases_dir(env) / session_id
    if alias_path.is_symlink():
        return state_sessions_dir(env) / guid_for_ref(Path(os.readlink(alias_path)).name) / "route.json"
    return state_sessions_dir(env) / guid_for_ref(session_id) / "route.json"


def query_session_live_state(env, session_id="s1"):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(5.0)
    try:
        conn.connect(str(socket_path(env, session_id)))
        send_hello(conn)
        send_frame(conn, SESSION_LIVE_STATE_QUERY, sessh_pb().SessionLiveStateQuery().SerializeToString())
        message_type, payload = recv_frame(conn)
        if message_type != SESSION_LIVE_STATE:
            raise AssertionError(f"expected SESSION_LIVE_STATE, got {message_type}")
        return parse_session_live_state(payload)
    finally:
        conn.close()


def wait_session_detached(env, session_id="s1", timeout=5.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            state = query_session_live_state(env, session_id)
            last = state
            if state.HasField("detached_at_unix_ms") and not state.attached_clients:
                return state
        except (AssertionError, FileNotFoundError, ConnectionRefusedError, OSError, TimeoutError):
            pass
        time.sleep(0.02)
    raise AssertionError(f"session did not become detached: {session_id}: {last!r}")


def wait_session_attached(env, session_id="s1", timeout=5.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            state = query_session_live_state(env, session_id)
            last = state
            if not state.HasField("detached_at_unix_ms") and state.attached_clients:
                return state
        except (AssertionError, FileNotFoundError, ConnectionRefusedError, OSError, TimeoutError):
            pass
        time.sleep(0.02)
    raise AssertionError(f"session did not become attached: {session_id}: {last!r}")


def agent_log_file(env, session_id="s1"):
    return route_file(env, session_id).parent / "agent.log"


def socket_path(env, session_id="s1"):
    link = agent_sock_link_path(env, session_id)
    if link.is_symlink():
        return (link.parent / os.readlink(link)).resolve()
    return actual_socket_path(env, session_id)


def actual_socket_path(env, session_id="s1"):
    return runtime_root(env) / "s" / compact_guid(guid_for_ref(session_id))


def agent_sock_link_path(env, session_id="s1"):
    return session_dir(env, session_id) / "agent.sock"


def ensure_agent_socket_link(env, session_id="s1"):
    path = session_dir(env, session_id)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    (runtime_root(env) / "s").mkdir(mode=0o700, parents=True, exist_ok=True)
    link = path / "agent.sock"
    if not link.exists() and not link.is_symlink():
        link.symlink_to(Path("../../s") / compact_guid(guid_for_ref(session_id)))


def start_session_agent(env, session_id="s1"):
    ensure_agent_socket_link(env, session_id)
    path = socket_path(env, session_id)
    session_path = session_dir(env, session_id)
    proc = subprocess.Popen(
        [str(BIN), ":internal-session-agent:", "--session-dir", str(session_path)],
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    wait_file(path)
    return proc


def write_session_meta(env, session_id, agent_pid, version=None):
    ensure_agent_socket_link(env, session_id)
    path = session_dir(env, session_id)
    (path / "meta.json").write_text(
        json.dumps(
            {
                "agent_pid": agent_pid,
                "version": version or sessh_version(),
            },
            separators=(",", ":"),
        )
        + "\n"
    )
    return path


def write_compat_script(path, log_path, exit_status=0):
    path.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$*\" >>{str(log_path)!r}\n"
        f"exit {exit_status}\n"
    )
    path.chmod(0o700)


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_process_missing(pid, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_exists(pid):
            return
        time.sleep(0.05)
    raise AssertionError(f"process {pid} still exists")


def start_sigterm_ignoring_process(tmp, name):
    pid_file = Path(tmp) / f"{name}.pid"
    term_marker = Path(tmp) / f"{name}.term"
    ready_marker = Path(tmp) / f"{name}.ready"
    script = Path(tmp) / f"{name}.py"
    script.write_text(
        "import os, pathlib, signal, sys, time\n"
        "pid = os.fork()\n"
        "if pid:\n"
        "    pathlib.Path(sys.argv[1]).write_text(str(pid))\n"
        "    sys.exit(0)\n"
        "os.setsid()\n"
        "def on_term(signum, frame):\n"
        "    pathlib.Path(sys.argv[2]).write_text('term')\n"
        "signal.signal(signal.SIGTERM, on_term)\n"
        "pathlib.Path(sys.argv[3]).write_text('ready')\n"
        "while True:\n"
        "    time.sleep(1)\n"
    )
    subprocess.run(
        [sys.executable, str(script), str(pid_file), str(term_marker), str(ready_marker)],
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    wait_file(ready_marker)
    return int(pid_file.read_text()), term_marker


def session_agent_pids(env):
    needle = f":internal-session-agent: --session-dir {sessions_dir(env)}"
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
            start_session_agent(env)
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
                draw = recv_draw_until(conn, b"COMMAND_ARGV_READY:arg-one")
                if b"UNEXPECTED_SHELL" in draw:
                    raise AssertionError(draw)
                send_frame(conn, INPUT, pack_bytes(b"exit\n"))
                recv_until_message(conn, SESSION_ENDED)
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


def run_minor_version_compatibility_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-minor-compat-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        cleanup_runtime(env)
        try:
            proc = start_session_agent(env)

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
            start_session_agent(env)

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
            start_session_agent(env)

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


def run_session_create_without_attach_protocol_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-create-detached-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "detached-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'DETACHED_READY\\n'\n"
            "while IFS= read -r line; do\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "done\n"
        )
        shell.chmod(0o700)
        cleanup_runtime(env)
        try:
            start_session_agent(env)

            create = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            create.settimeout(5.0)
            try:
                create.connect(str(socket_path(env)))
                send_hello(create)
                send_resize(create)
                send_frame(create, SESSION_CREATE, pack_session_create(shell))
                assert_session_created(recv_until_message(create, SESSION_CREATED))
            finally:
                create.close()

            attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            attach.settimeout(5.0)
            try:
                attach.connect(str(socket_path(env)))
                send_hello(attach)
                send_frame(attach, SESSION_ATTACH, pack_session_attach())
                message_type, payload = recv_frame(attach)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
                assert_session_attached(payload)
                recv_draw_until(attach, b"DETACHED_READY")
                send_frame(attach, INPUT, pack_bytes(b"exit\n"))
                recv_until_message(attach, SESSION_ENDED)
            finally:
                attach.close()
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
            start_session_agent(env)

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
            proc = start_session_agent(env)
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
            if ended.reason != pb.SESSION_END_REASON_PROCESS_EXITED:
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

    with tempfile.TemporaryDirectory(prefix="sessh-session-ended-kill-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "kill-status-shell"
        shell.write_text("#!/bin/sh\nprintf 'KILL_READY\\n'\nwhile :; do sleep 1; done\n")
        shell.chmod(0o700)
        env["SHELL"] = str(shell)
        cleanup_runtime(env)
        conn = None
        proc = None
        try:
            proc = start_session_agent(env)
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
            recv_draw_until(conn, b"KILL_READY")

            os.kill(proc.pid, signal.SIGTERM)
            ended = parse_session_ended(recv_until_message(conn, SESSION_ENDED))
            pb = sessh_pb()
            if ended.reason != pb.SESSION_END_REASON_KILLED_BY_REQUEST:
                raise AssertionError(f"unexpected killed reason: {ended!r}")
            if ended.HasField("exit_status"):
                raise AssertionError(f"killed-by-request should not report a wait status: {ended!r}")
            if not ended.HasField("ended_at_unix_ms"):
                raise AssertionError(f"missing killed timestamp: {ended!r}")
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
            start_session_agent(env)

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
            start_session_agent(env)

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
            start_session_agent(env)

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
            "  printf '\\033[?1;1000;1004;1006;2004h\\033[>7uMODES_READY'\n"
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
            start_session_agent(env)

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
        pid, fd = spawn_client(env, ["--alias", "s1"])
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
        pid, fd = spawn_client(env, ["--alias", "s1"])
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
            start_session_agent(env)

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
            start_session_agent(env)

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
            start_session_agent(env)

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
            start_session_agent(env)

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
            start_session_agent(env)

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
            start_session_agent(env)

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
                send_frame(attach, SESSION_ATTACH, pack_session_attach())

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
            start_session_agent(env)

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
                send_frame(attach, SESSION_ATTACH, pack_session_attach())

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
    start_session_agent(env)
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
    send_frame(attach, SESSION_ATTACH, pack_session_attach(reconnect_cursor=reconnect_cursor))
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
            start_session_agent(env)

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
                send_frame(attach, SESSION_ATTACH, pack_session_attach(reconnect_cursor=cursor))

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
            start_session_agent(env)

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
            create_and_attach_session(conn, shell, scrollback=50000)

            message_type, payload = recv_frame(conn)
            if message_type != SESSION_ATTACHED:
                raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
            assert_session_attached(payload)

            recv_draw_until(conn, b"SLOW_READY")
            send_frame(conn, INPUT, pack_bytes(b"go\n"))
            time.sleep(0.5)

            try:
                listed = run([".", "--compat-version", sessh_version(), "list"], env, check=True, timeout=2.0)
            except subprocess.TimeoutExpired as exc:
                raise AssertionError("management command path blocked behind a slow attachment") from exc
            assert_list_header(listed.stdout)
        finally:
            if conn is not None:
                conn.close()
            cleanup_runtime(env)


def run_session_agent_crash_client_error_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-agent-crash-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        cleanup_runtime(env)
        pid, fd = spawn_client(env, ["--alias", "s1"])
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
        env["SESSH_TEST_RUNTIME_REFRESH_MS"] = "50"
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

        session_path = session_dir(env, "s42")
        ensure_agent_socket_link(env, "s42")
        socket_file = socket_path(env, "s42")
        socket_link = agent_sock_link_path(env, "s42")
        meta_file = session_path / "meta.json"
        compat_file = session_path / "compat"

        proc = subprocess.Popen(
            [str(BIN), ":internal-session-agent:", "--session-dir", str(session_path)],
            cwd=ROOT,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        conn = None
        attach = None
        rescued_attach = None
        try:
            wait_file(socket_file)
            wait_file(meta_file)
            wait_file(compat_file)
            wait_sticky(session_path)
            wait_sticky(socket_file)
            wait_sticky(meta_file)
            if not socket_link.is_symlink():
                raise AssertionError("session agent socket link is not a symlink")
            meta = json.loads(meta_file.read_text())
            if meta.get("agent_pid") != proc.pid or meta.get("version") != sessh_version():
                raise AssertionError(meta)
            if not os.path.islink(compat_file):
                raise AssertionError("session compat path is not a symlink")

            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            conn.connect(str(socket_file))
            send_hello(conn)
            send_resize(conn, rows=4, cols=40)
            create_and_attach_session(conn, shell, session_id="s42")
            message_type, payload = recv_frame(conn)
            if message_type != SESSION_ATTACHED:
                raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
            assert_session_attached(payload)
            live_state = wait_session_attached(env, "s42")
            client = live_state.attached_clients[0]
            if not client.client_guid:
                raise AssertionError(live_state)
            if not client.HasField("terminal_size") or client.terminal_size.terminal_rows != 4 or client.terminal_size.terminal_cols != 40:
                raise AssertionError(live_state)
            if client.attached_at_unix_ms <= 0:
                raise AssertionError(live_state)
            recv_draw_until(conn, b"AGENT_READY")

            shutil.rmtree(runtime_root(env))
            if socket_file.exists() or socket_link.exists() or socket_link.is_symlink():
                raise AssertionError("runtime session files survived test deletion")

            send_frame(conn, INPUT, pack_bytes(b"old-client\n"))
            recv_draw_until(conn, b"AGENT:old-client")

            wait_file(socket_file, timeout=10.0)
            wait_file(meta_file, timeout=10.0)
            wait_file(compat_file, timeout=10.0)
            wait_sticky(session_path, timeout=10.0)
            wait_sticky(socket_file, timeout=10.0)
            wait_sticky(meta_file, timeout=10.0)
            if not socket_link.is_symlink():
                raise AssertionError("session agent did not recreate socket link")
            live_state = wait_session_attached(env, "s42", timeout=10.0)
            if live_state.HasField("detached_at_unix_ms"):
                raise AssertionError(f"live state became detached while an attachment was active: {live_state}")

            rescued_attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            rescued_attach.settimeout(5.0)
            rescued_attach.connect(str(socket_file))
            send_hello(rescued_attach)
            send_resize(rescued_attach, rows=4, cols=40)
            send_frame(rescued_attach, SESSION_ATTACH, pack_session_attach())
            message_type, payload = recv_frame(rescued_attach)
            if message_type != SESSION_ATTACHED:
                raise AssertionError(f"expected SESSION_ATTACHED after runtime resurrection, got {message_type}")
            assert_session_attached(payload)
            send_frame(rescued_attach, INPUT, pack_bytes(b"new-client\n"))
            recv_draw_until(rescued_attach, b"AGENT:new-client")
            rescued_attach.close()
            rescued_attach = None

            conn.close()
            conn = None
            wait_session_detached(env, "s42")

            attach = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            attach.settimeout(5.0)
            attach.connect(str(socket_file))
            send_hello(attach)
            send_resize(attach, rows=4, cols=40)
            send_frame(attach, SESSION_ATTACH, pack_session_attach())
            message_type, payload = recv_frame(attach)
            if message_type != SESSION_ATTACHED:
                raise AssertionError(f"expected SESSION_ATTACHED, got {message_type}")
            assert_session_attached(payload)
            live_state = wait_session_attached(env, "s42")
            if live_state.HasField("detached_at_unix_ms"):
                raise AssertionError("live detached state survived reattach")

            send_frame(attach, INPUT, pack_bytes(b"exit\n"))
            recv_until_message(attach, SESSION_ENDED)
            proc.wait(timeout=5.0)
            wait_missing(socket_file)
            wait_missing(socket_link)
            wait_missing(compat_file)
            wait_missing(session_path)
        finally:
            if conn is not None:
                conn.close()
            if attach is not None:
                attach.close()
            if rescued_attach is not None:
                rescued_attach.close()
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2.0)


def run_broker_starts_session_agent_test(base_env):
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

            session_path = session_dir(env, "s1")
            if not agent_sock_link_path(env, "s1").is_symlink():
                raise AssertionError("broker did not create a session-agent socket link")
            if not socket_path(env, "s1").exists():
                raise AssertionError("broker did not create a session-agent socket")
            if not os.path.islink(session_path / "compat"):
                raise AssertionError("broker session agent did not write compat symlink")
            assert_runtime_dir_symlink(env, Path(env["XDG_RUNTIME_DIR"]))

            send_frame(conn, INPUT, pack_bytes(b"exit\n"))
            recv_until_message(conn, SESSION_ENDED)
            proc.stdin.close()
            proc.wait(timeout=5.0)
            if proc.returncode != 0:
                raise AssertionError(proc.stderr.read().decode("utf-8", "replace"))
            wait_missing(socket_path(env, "s1"))
            wait_missing(agent_sock_link_path(env, "s1"))
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


def run_broker_registry_commands_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-broker-commands-", dir="/tmp") as tmp:
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
        session_path = session_dir(env, "s1")

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
                raise AssertionError((message_type, payload))
            assert_session_attached(payload)
            recv_draw_until(conn, b"BROKER_COMMAND_READY")
            proc.stdin.close()
            proc.wait(timeout=5.0)
            wait_session_detached(env, "s1")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)

        listed = run([":internal-broker:", "list"], env, check=True, timeout=5.0)
        if "s1" not in sessions(listed.stdout):
            raise AssertionError(listed.stdout)

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
            send_frame(conn, SESSION_ATTACH, pack_session_attach())
            message_type, payload = recv_frame(conn)
            if message_type != SESSION_ATTACHED:
                raise AssertionError((message_type, payload))
            assert_session_attached(payload)
            live_state = wait_session_attached(env, "s1")
            if live_state.HasField("detached_at_unix_ms"):
                raise AssertionError("broker attach did not clear detached live state")
            send_frame(conn, INPUT, pack_bytes(b"exit\n"))
            recv_until_message(conn, SESSION_ENDED)
            proc.stdin.close()
            proc.wait(timeout=5.0)
            wait_missing(socket_path(env, "s1"))
            wait_missing(agent_sock_link_path(env, "s1"))
            wait_missing(session_path / "compat")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)

        missing = run([":internal-broker:", "kill", "s1"], env, timeout=5.0)
        if missing.returncode != 1 or "session already exited" not in missing.stderr:
            raise AssertionError(missing)

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
            create_and_attach_session(conn, shell, session_id="s2")
            message_type, payload = recv_frame(conn)
            if message_type != SESSION_ATTACHED:
                raise AssertionError((message_type, payload))
            assert_session_attached(payload)
            recv_draw_until(conn, b"BROKER_COMMAND_READY")
            proc.stdin.close()
            proc.wait(timeout=5.0)
            wait_session_detached(env, "s2")
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)

        killed = run([":internal-broker:", "kill", "s2"], env, check=True, timeout=5.0)
        if "ENDED s2" not in killed.stdout or killed.stderr:
            raise AssertionError(killed)
        s2_dir = session_dir(env, "s2")
        wait_missing(socket_path(env, "s2"))
        wait_missing(agent_sock_link_path(env, "s2"))
        wait_missing(s2_dir / "compat")

        for expected_id in ("s3", "s4"):
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
                create_and_attach_session(conn, shell, session_id=expected_id)
                message_type, payload = recv_frame(conn)
                if message_type != SESSION_ATTACHED:
                    raise AssertionError((expected_id, message_type, payload))
                assert_session_attached(payload)
                recv_draw_until(conn, b"BROKER_COMMAND_READY")
                proc.stdin.close()
                proc.wait(timeout=5.0)
                wait_session_detached(env, expected_id)
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=2.0)

        stopped = run([":internal-broker:", "kill", "--all"], env, check=True, timeout=5.0)
        if "KILLING_ALL" not in stopped.stdout or stopped.stderr:
            raise AssertionError(stopped)
        for expected_id in ("s3", "s4"):
            path = session_dir(env, expected_id)
            wait_missing(socket_path(env, expected_id))
            wait_missing(agent_sock_link_path(env, expected_id))
            wait_missing(path / "compat")


def run_client_control_commands_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-client-control-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "client-control-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'CLIENT_CONTROL_READY\\n'\n"
            "while IFS= read -r line; do\n"
            "  printf 'CLIENT_CONTROL:%s\\n' \"$line\"\n"
            "done\n"
        )
        shell.chmod(0o700)
        client_one = "c-11111111-1111-1111-1111-111111111111"
        client_two = "c-22222222-2222-2222-2222-222222222222"
        client_three = "c-33333333-3333-4333-8333-333333333333"
        proc = None
        conns = []

        def connect_socket():
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5.0)
            conn.connect(str(socket_path(env)))
            send_hello(conn)
            conns.append(conn)
            return conn

        def attach_existing(client_guid):
            conn = connect_socket()
            send_resize(conn, rows=8, cols=60)
            send_frame(conn, SESSION_ATTACH, pack_session_attach(session_ref="s1", client_guid=client_guid))
            message_type, payload = recv_frame(conn)
            if message_type != SESSION_ATTACHED:
                raise AssertionError((message_type, payload))
            assert_session_attached(payload)
            recv_draw(conn)
            return conn

        def clients_by_guid():
            state = query_session_live_state(env)
            return {client.client_guid: client for client in state.attached_clients}

        def assert_no_frame(conn):
            old_timeout = conn.gettimeout()
            conn.settimeout(0.2)
            try:
                try:
                    frame = recv_frame(conn)
                except TimeoutError:
                    return
            finally:
                conn.settimeout(old_timeout)
            raise AssertionError(f"unexpected frame: {frame!r}")

        try:
            proc = start_session_agent(env)
            conn1 = connect_socket()
            send_resize(conn1, rows=8, cols=60)
            create_and_attach_session(conn1, shell, session_id="s1", client_guid=client_one)
            message_type, payload = recv_frame(conn1)
            if message_type != SESSION_ATTACHED:
                raise AssertionError((message_type, payload))
            assert_session_attached(payload)
            recv_draw_until(conn1, b"CLIENT_CONTROL_READY")

            conn2 = attach_existing(client_two)
            clients = clients_by_guid()
            if set(clients) != {client_one, client_two}:
                raise AssertionError(clients)
            if clients[client_one].HasField("last_input_at_unix_ms") or clients[client_two].HasField("last_input_at_unix_ms"):
                raise AssertionError(clients)

            send_frame(conn2, INPUT, pack_input(b"\x1b]10;rgb:ffff/ffff/ffff\x07", input_seq=21))
            if parse_input_ack(recv_until_message(conn2, INPUT_ACK)) != 21:
                raise AssertionError("missing terminal-response input ack")
            clients = clients_by_guid()
            if clients[client_two].HasField("last_input_at_unix_ms"):
                raise AssertionError("terminal response counted as user input")

            send_frame(conn1, INPUT, pack_input(b"from-one\n", input_seq=22))
            if parse_input_ack(recv_until_message(conn1, INPUT_ACK)) != 22:
                raise AssertionError("missing user input ack")
            recv_draw_until(conn1, b"CLIENT_CONTROL:from-one")
            recv_draw_until(conn2, b"CLIENT_CONTROL:from-one")
            clients = clients_by_guid()
            if not clients[client_one].HasField("last_input_at_unix_ms"):
                raise AssertionError("user input did not update last input timestamp")
            if clients[client_two].HasField("last_input_at_unix_ms"):
                raise AssertionError("other client unexpectedly gained last input timestamp")

            listed_sessions = run([".", "list"], env, check=True, timeout=5.0)
            session_rows = sessions(listed_sessions.stdout)
            if session_rows.get("s1", {}).get("attached") != "2":
                raise AssertionError(listed_sessions.stdout)
            if session_rows["s1"].get("input") == "never":
                raise AssertionError(listed_sessions.stdout)

            listed = run([".", "list-clients", "--jsonl", "s1"], env, check=True, timeout=5.0)
            rows = [json.loads(line) for line in listed.stdout.splitlines()]
            if [row["client_guid"] for row in rows] != [client_one, client_two]:
                raise AssertionError(listed.stdout)
            if rows[0]["last_input_at_unix_ms"] is None or rows[1]["last_input_at_unix_ms"] is not None:
                raise AssertionError(rows)
            if rows[0]["terminal_size"] != {"terminal_rows": 8, "terminal_cols": 60}:
                raise AssertionError(rows)

            listed_clients = run([".", "list-clients", "s1"], env, check=True, timeout=5.0)
            if client_one in listed_clients.stdout or "c-11111111" not in listed_clients.stdout:
                raise AssertionError(listed_clients.stdout)

            ambiguous = run(["detach", "s1"], env, timeout=5.0)
            if ambiguous.returncode == 0 or "multiple clients are attached" not in ambiguous.stderr:
                raise AssertionError(ambiguous)

            repainted = run(["repaint", "--last-input", "s1"], env, check=True, timeout=5.0)
            if f"REPAINTED {client_one}" not in repainted.stdout:
                raise AssertionError(repainted)
            repaint_request = parse_client_repaint_request(recv_until_message(conn1, CLIENT_REPAINT_REQUEST))
            if repaint_request.include_scrollback:
                raise AssertionError(repaint_request)
            assert_no_frame(conn2)

            repainted = run(["repaint", "--scrollback", "--last-input", "s1"], env, check=True, timeout=5.0)
            if f"REPAINTED {client_one}" not in repainted.stdout:
                raise AssertionError(repainted)
            repaint_request = parse_client_repaint_request(recv_until_message(conn1, CLIENT_REPAINT_REQUEST))
            if not repaint_request.include_scrollback:
                raise AssertionError(repaint_request)
            assert_no_frame(conn2)

            repainted = run(["repaint", "c-11111111", "s1"], env, check=True, timeout=5.0)
            if f"REPAINTED {client_one}" not in repainted.stdout:
                raise AssertionError(repainted)
            recv_until_message(conn1, CLIENT_REPAINT_REQUEST)
            assert_no_frame(conn2)

            detached = run(["detach", "--last-input", "s1"], env, check=True, timeout=5.0)
            if f"DETACHED {client_one}" not in detached.stdout:
                raise AssertionError(detached)
            recv_until_message(conn1, CLIENT_DETACH_REQUEST)
            assert_no_frame(conn2)
            conn1.close()
            deadline = time.time() + 5.0
            while True:
                state = query_session_live_state(env)
                if [client.client_guid for client in state.attached_clients] == [client_two]:
                    break
                if time.time() > deadline:
                    raise AssertionError(state)
                time.sleep(0.02)
            listed_sessions = run([".", "list"], env, check=True, timeout=5.0)
            session_rows = sessions(listed_sessions.stdout)
            if session_rows.get("s1", {}).get("attached") != "1":
                raise AssertionError(listed_sessions.stdout)
            if session_rows["s1"].get("input") == "never":
                raise AssertionError(listed_sessions.stdout)

            missing_last_input = run(["detach", "--last-input", "s1"], env, timeout=5.0)
            if missing_last_input.returncode == 0 or "no attached client has sent user input" not in missing_last_input.stderr:
                raise AssertionError(missing_last_input)

            conn3 = attach_existing(client_three)
            socket_hint = client_agent_socket_hint_file(env, client_three)
            if not socket_hint.is_symlink():
                raise AssertionError(f"client agent socket hint is missing: {socket_hint}")
            expected_target = Path("..") / guid_for_ref("s1") / "agent.sock"
            if Path(os.readlink(socket_hint)) != expected_target:
                raise AssertionError(f"client agent socket hint target mismatch: {os.readlink(socket_hint)}")
            route_hint = client_route_hint_file(env, client_three)
            if route_hint.exists() or route_hint.is_symlink():
                raise AssertionError(f"local client unexpectedly wrote a route hint: {route_hint}")
            detached_by_client_guid = run(["detach", client_three], env, check=True, timeout=5.0)
            if f"DETACHED {client_three}" not in detached_by_client_guid.stdout:
                raise AssertionError(detached_by_client_guid)
            recv_until_message(conn3, CLIENT_DETACH_REQUEST)
            conn3.close()
            deadline = time.time() + 5.0
            while True:
                state = query_session_live_state(env)
                if [client.client_guid for client in state.attached_clients] == [client_two]:
                    break
                if time.time() > deadline:
                    raise AssertionError(state)
                time.sleep(0.02)
            if socket_hint.exists() or socket_hint.is_symlink():
                raise AssertionError(f"client agent socket hint was not removed: {socket_hint}")

            unresponsive = run(["debug", "unresponsive-connection", "--seconds", "1", client_two, "s1"], env, check=True, timeout=5.0)
            if f"UNRESPONSIVE {client_two}" not in unresponsive.stdout:
                raise AssertionError(unresponsive)
            send_frame(conn2, INPUT, pack_input(b"ignored\n", input_seq=23))
            try:
                recv_until_message(conn2, INPUT_ACK, timeout=0.2)
                raise AssertionError("unresponsive debug client still acknowledged input")
            except TimeoutError:
                pass
            if parse_input_ack(recv_until_message(conn2, INPUT_ACK, timeout=2.0)) != 23:
                raise AssertionError("unresponsive debug client did not recover after --seconds")

            replacement = attach_existing(client_two)
            clients = clients_by_guid()
            if set(clients) != {client_two}:
                raise AssertionError(clients)
            send_frame(replacement, INPUT, pack_input(b"replacement\n", input_seq=24))
            if parse_input_ack(recv_until_message(replacement, INPUT_ACK)) != 24:
                raise AssertionError("replacement client did not receive input ack")
        finally:
            for conn in conns:
                try:
                    conn.close()
                except OSError:
                    pass
            if proc is not None and proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=2.0)
            cleanup_runtime(env)


def run_broker_attach_without_id_uses_latest_detached_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-broker-latest-detached-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        shell = Path(tmp) / "broker-latest-detached-shell"
        shell.write_text(
            "#!/bin/sh\n"
            "printf 'BROKER_LATEST_DETACHED_READY\\n'\n"
            "while IFS= read -r line; do\n"
            "  if [ \"$line\" = exit ]; then exit 0; fi\n"
            "  printf 'BROKER_LATEST_DETACHED:%s\\n' \"$line\"\n"
            "done\n"
        )
        shell.chmod(0o700)
        attached = []

        def start_attached_session(session_id):
            proc = subprocess.Popen(
                [str(BIN), ":internal-broker:"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            conn = FdConn(proc.stdout.fileno(), proc.stdin.fileno())
            attached.append((proc, conn))
            send_hello(conn)
            send_resize(conn, rows=4, cols=40)
            create_and_attach_session(conn, shell, session_id=session_id)
            message_type, payload = recv_frame(conn)
            if message_type != SESSION_ATTACHED:
                raise AssertionError((session_id, message_type, payload))
            message = assert_session_attached(payload)
            if message.session_guid != guid_for_ref(session_id):
                raise AssertionError((session_id, message.session_guid))
            recv_draw_until(conn, b"BROKER_LATEST_DETACHED_READY")
            return proc, conn

        try:
            s1_proc, _ = start_attached_session("s1")
            s1_proc.stdin.close()
            s1_proc.wait(timeout=5.0)
            attached = [(proc, conn) for proc, conn in attached if proc is not s1_proc]
            wait_session_detached(env, "s1")

            time.sleep(0.02)
            s2_proc, s2_conn = start_attached_session("s2")
            live_state = wait_session_attached(env, "s2")
            if live_state.HasField("detached_at_unix_ms"):
                raise AssertionError("newer attached session has detached live state")

            attach_proc = subprocess.Popen(
                [str(BIN), ":internal-broker:"],
                cwd=ROOT,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            attach_conn = FdConn(attach_proc.stdout.fileno(), attach_proc.stdin.fileno())
            attached.append((attach_proc, attach_conn))
            send_hello(attach_conn)
            send_resize(attach_conn, rows=4, cols=40)
            send_frame(attach_conn, SESSION_ATTACH, pack_session_attach())
            message_type, payload = recv_frame(attach_conn)
            if message_type != SESSION_ATTACHED:
                raise AssertionError((message_type, payload))
            message = assert_session_attached(payload)
            if message.session_guid != guid_for_ref("s1"):
                raise AssertionError(f"expected no-id attach to select detached s1, got {message.session_guid}")

            send_frame(attach_conn, INPUT, pack_bytes(b"exit\n"))
            recv_until_message(attach_conn, SESSION_ENDED)
            attach_proc.stdin.close()
            attach_proc.wait(timeout=5.0)
            attached = [(proc, conn) for proc, conn in attached if proc is not attach_proc]

            send_frame(s2_conn, INPUT, pack_bytes(b"exit\n"))
            recv_until_message(s2_conn, SESSION_ENDED)
            s2_proc.stdin.close()
            s2_proc.wait(timeout=5.0)
            attached = [(proc, conn) for proc, conn in attached if proc is not s2_proc]
        finally:
            for proc, _ in attached:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=2.0)


def run_broker_kill_edge_cases_test(base_env):
    with tempfile.TemporaryDirectory(prefix="sessh-broker-sigkill-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        cleanup_runtime(env)
        agent_pid, term_marker = start_sigterm_ignoring_process(tmp, "ignore-term-agent")
        try:
            write_session_meta(env, "s1", agent_pid)
            killed = run([":internal-broker:", "kill", "s1"], env, timeout=6.0)
            if killed.returncode != 0 or "ENDED s1" not in killed.stdout:
                raise AssertionError(killed)
            wait_file(term_marker)
            wait_process_missing(agent_pid)
        finally:
            if process_exists(agent_pid):
                os.kill(agent_pid, signal.SIGKILL)
                wait_process_missing(agent_pid)
            cleanup_runtime(env)

    with tempfile.TemporaryDirectory(prefix="sessh-broker-compat-kill-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        cleanup_runtime(env)
        sleeper = subprocess.Popen(["sleep", "30"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            session_path = write_session_meta(env, "s1", sleeper.pid, version="0.0.0-compat-test")
            compat_log = Path(tmp) / "compat.log"
            write_compat_script(session_path / "compat", compat_log)

            killed = run([":internal-broker:", "kill", "s1"], env, check=True, timeout=5.0)
            if killed.stdout or killed.stderr:
                raise AssertionError(killed)
            expected = f". --compat-version {sessh_version()} kill s1"
            if expected not in compat_log.read_text().splitlines():
                raise AssertionError(compat_log.read_text())
            if sleeper.poll() is not None:
                raise AssertionError("broker killed a mismatched-version agent instead of delegating to compat")
        finally:
            if sleeper.poll() is None:
                sleeper.terminate()
                sleeper.wait(timeout=2.0)
            cleanup_runtime(env)

    with tempfile.TemporaryDirectory(prefix="sessh-broker-compat-kill-all-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        cleanup_runtime(env)
        sleepers = [
            subprocess.Popen(["sleep", "30"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(2)
        ]
        try:
            compat_log = Path(tmp) / "compat-all.log"
            for session_id, proc in zip(("s1", "s2"), sleepers):
                session_path = write_session_meta(env, session_id, proc.pid, version="0.0.0-compat-test")
                write_compat_script(session_path / "compat", compat_log)

            stopped = run([":internal-broker:", "kill", "--all"], env, check=True, timeout=5.0)
            if stopped.stdout != "KILLING_ALL\n" or stopped.stderr:
                raise AssertionError(stopped)
            lines = compat_log.read_text().splitlines()
            for session_id in ("s1", "s2"):
                expected = f". --compat-version {sessh_version()} kill {guid_for_ref(session_id)}"
                if expected not in lines:
                    raise AssertionError(lines)
            if any(proc.poll() is not None for proc in sleepers):
                raise AssertionError("broker killed a mismatched-version agent during kill-all")
        finally:
            for proc in sleepers:
                if proc.poll() is None:
                    proc.terminate()
                    proc.wait(timeout=2.0)
            cleanup_runtime(env)


def spawn_bin(env, args):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(env)
        os.execv(str(BIN), [str(BIN), *args])
    return pid, fd


def spawn_client(env, extra_args=None):
    extra_args = extra_args or []
    return spawn_bin(env, [".", *extra_args])


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
        if len(line) < 58:
            raise AssertionError(f"invalid list row: {line!r}\n{stdout}")
        session_id = line[0:10].strip()
        attached = line[12:20].strip()
        last_input = line[22:30].strip()
        host = line[32:56].strip()
        version = line[58:].strip()
        result[session_id] = {"attached": attached, "input": last_input, "host": host, "version": version}
    return result


def jsonl_sessions(stdout):
    result = {}
    for line in stdout.splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        result[row["id"]] = {
            "host": row["host"],
            "version": row["version"],
            "guid": row["guid"],
            "attached_count": row.get("attached_count"),
            "last_input_at_unix_ms": row.get("last_input_at_unix_ms"),
        }
    return result


def assert_list_header(stdout):
    header = stdout.splitlines()[0] if stdout.splitlines() else ""
    for column in ("ID", "ATTACHED", "INPUT", "HOST", "VERSION"):
        if column not in header:
            raise AssertionError(stdout)


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
        pid, fd = spawn_client(env, ["--alias", "s1"])
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

        wait_log_contains(agent_log_file(env, "s1"), "scrollback_rows=80")

        pid, fd = spawn_client(env, ["attach"])
        try:
            attached = read_until(fd, b"$ ")
            if b"cfg_001" in attached:
                raise AssertionError(f"initial-scrollback=0 replayed retained history: {attached!r}")
            if b"cfg_040" not in attached:
                raise AssertionError(f"initial-scrollback=0 did not draw current screen: {attached!r}")
            os.write(fd, b"~.")
        finally:
            close_client(pid, fd)

        killed = run([".", "kill", "s1"], env, check=True, timeout=5.0)
        if "ENDED s1" not in killed.stdout:
            raise AssertionError(killed.stdout)

        (config_dir / "sessh.env").write_text("leader=CTRL-B\n")
        pid, fd = spawn_client(env, ["--alias", "s2"])
        try:
            read_until(fd, b"$ ")
            os.write(fd, b"\x02d")
            read_until(fd, b"sessh: detached")
        finally:
            close_client(pid, fd)

        killed = run([".", "kill", "s2"], env, check=True, timeout=5.0)
        if "ENDED s2" not in killed.stdout:
            raise AssertionError(killed.stdout)
    finally:
        cleanup_runtime(env)


def run_tty_transcript_capture_test(tmp_root):
    env = isolated_env(Path(tmp_root) / "tty-transcript")
    env["SHELL"] = "/bin/sh"
    cleanup_runtime(env)

    archive = Path(tmp_root) / "tty-transcript.tar.gz"
    try:
        pid, fd = spawn_client(env, ["--alias", "s1", "--capture-tty-transcript", str(archive)])
        try:
            startup = read_until(fd, b"$ ")
            if b"WARNING: tty transcript capture is enabled" not in startup:
                raise AssertionError(f"missing transcript warning: {startup!r}")
            os.write(fd, b"printf 'transcript_inner_marker\\n'\n")
            read_until_count(fd, b"transcript_inner_marker", 2)
            os.write(fd, b"~.")
            read_until(fd, b"sessh: detached")
        finally:
            close_client(pid, fd)

        wait_file(archive)
        with tarfile.open(archive, "r:gz") as tar:
            names = set(tar.getnames())
            expected = {
                "manifest.json",
                "outer.in.bin",
                "outer.out.bin",
                "inner.in.bin",
                "inner.out.bin",
            }
            if names != expected:
                raise AssertionError(f"unexpected transcript archive contents: {names}")

            manifest = json.loads(tar.extractfile("manifest.json").read().decode())
            if manifest["format_version"] != 1:
                raise AssertionError(manifest)
            if manifest["streams"]["inner.in.bin"]["bytes"] <= 0:
                raise AssertionError(manifest)

            outer_in = tar.extractfile("outer.in.bin").read()
            outer_out = tar.extractfile("outer.out.bin").read()
            inner_in = tar.extractfile("inner.in.bin").read()
            inner_out = tar.extractfile("inner.out.bin").read()

        if b"printf 'transcript_inner_marker\\n'\n" not in outer_in:
            raise AssertionError(outer_in)
        if b"transcript_inner_marker" not in outer_out:
            raise AssertionError(outer_out)
        if b"printf 'transcript_inner_marker\\n'\n" not in inner_in:
            raise AssertionError(inner_in)
        if b"transcript_inner_marker" not in inner_out:
            raise AssertionError(inner_out)

        killed = run([".", "kill", "s1"], env, check=True, timeout=5.0)
        if "ENDED s1" not in killed.stdout:
            raise AssertionError(killed.stdout)
    finally:
        cleanup_runtime(env)


def run_initial_kitty_keyboard_restore_test(tmp_root):
    global kitty_keyboard_status_response

    env = isolated_env(Path(tmp_root) / "kitty-keyboard-restore")
    env["SHELL"] = "/bin/sh"
    cleanup_runtime(env)

    previous_response = kitty_keyboard_status_response
    kitty_keyboard_status_response = b"\x1b[?7u"
    try:
        pid, fd = spawn_client(env, ["--alias", "s1"])
        try:
            read_until(fd, b"$ ")
            os.write(fd, b"~.")
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
            if help_text.returncode != 0 or "sesshmux new" not in help_text.stdout:
                raise AssertionError(help_text)
            if "sessh [ssh-option" in help_text.stdout:
                raise AssertionError(help_text.stdout)
            version_text = run(["--version"], env, timeout=5.0)
            if version_text.returncode != 0 or version_text.stdout != f"sesshmux {sessh_version()}\n":
                raise AssertionError(version_text)
            short_help_text = run(["-h"], env, timeout=5.0)
            if short_help_text.returncode != 0 or short_help_text.stdout != help_text.stdout:
                raise AssertionError(short_help_text)
            internal_sessh_help = run([":internal-sessh:", "--help"], env, timeout=5.0)
            if internal_sessh_help.returncode != 0 or "sessh [ssh-option" not in internal_sessh_help.stdout:
                raise AssertionError(internal_sessh_help)
            if "sesshmux new" in internal_sessh_help.stdout:
                raise AssertionError(internal_sessh_help.stdout)
            internal_sessh_version = run([":internal-sessh:", "--version"], env, timeout=5.0)
            if internal_sessh_version.returncode != 0 or internal_sessh_version.stdout != f"sessh {sessh_version()}\n":
                raise AssertionError(internal_sessh_version)
            sessh_wrapper = ROOT / "zig-out" / "bin" / "sessh"
            if sessh_wrapper.exists():
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
                if "sesshmux new" in sessh_help.stdout:
                    raise AssertionError(sessh_help.stdout)
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
            sesshmux_wrapper = ROOT / "zig-out" / "bin" / "sesshmux"
            if sesshmux_wrapper.exists():
                sesshmux_version_text = subprocess.run(
                    [str(sesshmux_wrapper), "--version"],
                    cwd=ROOT,
                    env=env,
                    text=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                    check=False,
                )
                if sesshmux_version_text.returncode != 0 or sesshmux_version_text.stdout != f"sesshmux {sessh_version()}\n":
                    raise AssertionError(sesshmux_version_text)

            bad = run([".", "/tmp/not-a-socket-path"], env, timeout=5.0)
            if bad.returncode != 64:
                raise AssertionError(bad)

            listed = run([".", "list"], env, check=True, timeout=5.0)
            assert_list_header(listed.stdout)

            missing = run([".", "kill", "s1"], env, timeout=5.0)
            if missing.returncode != 1 or "ERROR session not found" not in missing.stderr:
                raise AssertionError(missing)

            bad = run([".", "--leader", "CTRL-C", "list"], env, timeout=5.0)
            if bad.returncode != 64:
                raise AssertionError(bad)

            bad = run([".", "--scrollback-limit", "0"], env, timeout=5.0)
            if bad.returncode != 64:
                raise AssertionError(bad)

            stopped = run([".", "kill", "--all"], env, timeout=5.0)
            if stopped.returncode != 0 or stopped.stdout != "KILLING_ALL\n":
                raise AssertionError(stopped)
            if sessions_dir(env).exists() and any(sessions_dir(env).iterdir()):
                raise AssertionError("kill all started a session agent")

            run_login_shell_profile_test(env)
            run_session_create_command_argv_test(env)
            run_session_agent_crash_client_error_test(env)
            run_session_agent_registry_test(env)
            run_broker_starts_session_agent_test(env)
            run_broker_registry_commands_test(env)
            run_client_control_commands_test(env)
            run_broker_attach_without_id_uses_latest_detached_test(env)
            run_broker_kill_edge_cases_test(env)
            run_minor_version_compatibility_test(env)
            run_session_create_without_attach_protocol_test(env)
            run_live_draw_protocol_test(env)
            run_synchronized_output_protocol_test(env)
            run_input_ack_protocol_test(env)
            run_session_ended_payload_protocol_test(env)
            run_plain_scroll_protocol_test(env)
            run_plain_screen_protocol_test(env)
            run_split_escape_tail_is_not_passthrough_test(env)
            run_active_screen_protocol_test(env)
            run_terminal_modes_protocol_test(env)
            run_cursor_shape_protocol_test(env)
            run_state_only_client_render_test(env)
            run_display_clear_not_forwarded_test(env)
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
            run_slow_attachment_does_not_block_commands_test(env)
            run_env_config_client_test(tmp)
            run_tty_transcript_capture_test(tmp)
            run_initial_kitty_keyboard_restore_test(tmp)

            listed = run([".", "list"], env, check=True, timeout=5.0)
            assert_list_header(listed.stdout)

            remote_guid = guid_for_ref("s7")
            write_cached_remote_route(env, "remote8", "work.blox", remote_guid)
            listed = run([".", "list"], env, check=True, timeout=5.0)
            if "cached remote session status may be out of date" not in listed.stderr:
                raise AssertionError(listed)
            current_sessions = sessions(listed.stdout)
            remote_route = current_sessions.get("remote8")
            if remote_route is None:
                raise AssertionError(listed.stdout)
            if (
                remote_route.get("host") != "work.blox"
                or remote_route.get("version") != "cached-test"
                or remote_route.get("attached") != "???"
                or remote_route.get("input") != "???"
            ):
                raise AssertionError(listed.stdout)
            listed_jsonl = run([".", "list", "--jsonl"], env, check=True, timeout=5.0)
            if "cached remote session status may be out of date" not in listed_jsonl.stderr:
                raise AssertionError(listed_jsonl)
            jsonl_route = jsonl_sessions(listed_jsonl.stdout).get("remote8")
            if jsonl_route != {
                "host": "work.blox",
                "version": "cached-test",
                "guid": remote_guid,
                "attached_count": None,
                "last_input_at_unix_ms": None,
            }:
                raise AssertionError(listed_jsonl.stdout)
            listed = run([".", "list", "--local-only"], env, check=True, timeout=5.0)
            if listed.stderr:
                raise AssertionError(listed)
            if "remote8" in sessions(listed.stdout):
                raise AssertionError(listed.stdout)

            pid, fd = spawn_client(env, ["--alias", "s1"])
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"echo TERM=$TERM\n")
                read_until(fd, b"TERM=xterm-256color")
                os.write(fd, b"echo SESSH_ID=${SESSH_ID-unset}\n")
                read_until(fd, b"SESSH_ID=unset")
                os.write(fd, b"echo SESSH_GUID=$SESSH_GUID\n")
                read_until(fd, b"SESSH_GUID=")
                os.write(fd, b"echo sessh_before_reconnect\n")
                read_until_count(fd, b"sessh_before_reconnect", 2)
                os.write(fd, b"~.")
                read_until(fd, startup_cwd_title_sequence(), timeout=2.0)
            finally:
                close_client(pid, fd)

            listed = run([".", "list"], env, check=True, timeout=5.0)
            assert_list_header(listed.stdout)
            current_sessions = sessions(listed.stdout)
            if "s1" not in current_sessions:
                raise AssertionError(listed.stdout)
            if current_sessions["s1"].get("version") != sessh_version():
                raise AssertionError(listed.stdout)
            route_text = route_file(env, "s1").read_text()
            route = json.loads(route_text)
            if (
                route.get("session_dir") != str(session_dir(env, "s1"))
                or route.get("host") != "."
                or route.get("agent_version") != sessh_version()
            ):
                raise AssertionError(route_text)
            if "session_dir=2f" in route_text or "host=2e" in route_text:
                raise AssertionError(route_text)

            pid, fd = spawn_client(env, ["attach"])
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

            config_dir = Path(env["XDG_CONFIG_HOME"]) / "sessh"
            config_dir.mkdir(parents=True, exist_ok=True)
            (config_dir / "sessh.env").write_text("scrollback-limit=7\n")
            pid, fd = spawn_client(env, ["--alias", "s2"])
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"~.")
            finally:
                close_client(pid, fd)

            listed = run([".", "list"], env, check=True, timeout=5.0)
            current_sessions = sessions(listed.stdout)
            if "s2" not in current_sessions:
                raise AssertionError(listed.stdout)

            killed = run([".", "kill", "s2"], env, check=True, timeout=5.0)
            if "ENDED s2" not in killed.stdout:
                raise AssertionError(killed.stdout)

            listed = run([".", "list"], env, check=True, timeout=5.0)
            if "s2" in sessions(listed.stdout):
                raise AssertionError(listed.stdout)

            missing = run([".", "kill", "missing"], env, timeout=5.0)
            if missing.returncode != 1 or "ERROR session not found" not in missing.stderr:
                raise AssertionError(missing)

            (config_dir / "sessh.env").write_text("leader=CTRL-B\n")
            pid, fd = spawn_client(env, ["--alias", "s3"])
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"\x02d")
            finally:
                close_client(pid, fd)

            listed = run([".", "list"], env, check=True, timeout=5.0)
            current_sessions = sessions(listed.stdout)
            if "s3" not in current_sessions:
                raise AssertionError(listed.stdout)

            changed_runtime_env = dict(env)
            changed_runtime_env["XDG_RUNTIME_DIR"] = str(Path(tmp) / "changed-runtime")
            pid, fd = spawn_bin(changed_runtime_env, ["attach", "s3"])
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"echo sessh_runtime_route_attach\n")
                read_until_count(fd, b"sessh_runtime_route_attach", 2)
                os.write(fd, b"~.")
            finally:
                close_client(pid, fd)

            killed = run(["kill", "s3"], changed_runtime_env, check=True, timeout=5.0)
            if "ENDED s3" not in killed.stdout:
                raise AssertionError(killed.stdout)

            (config_dir / "sessh.env").write_text("leader=CTRL-B\n")
            pid, fd = spawn_client(env, ["--alias", "s4"])
            try:
                read_until(fd, b"$ ")
                os.write(fd, b"echo sessh_before_sever\n")
                read_until_count(fd, b"sessh_before_sever", 2)
                os.write(fd, b"\x02s")
                read_until(fd, b"sessh: disconnected: Reconnecting")
                os.write(fd, b"\x12")
                read_until(fd, b"$ ")
                os.write(fd, b"echo sessh_after_sever\n")
                read_until_count(fd, b"sessh_after_sever", 2)
                os.write(fd, b"~.")
            finally:
                close_client(pid, fd)

            killed = run([".", "kill", "s4"], env, check=True, timeout=5.0)
            if "ENDED s4" not in killed.stdout:
                raise AssertionError(killed.stdout)

            pid1, fd1 = spawn_client(env, ["--alias", "s5"])
            try:
                read_until(fd1, b"$ ")
                listed = run([".", "list"], env, check=True, timeout=5.0)
                current_sessions = sessions(listed.stdout)
                if "s5" not in current_sessions:
                    raise AssertionError(listed.stdout)

                pid2, fd2 = spawn_client(env, ["attach", "s5"])
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

            killed = run([".", "kill", "s5"], env, check=True, timeout=5.0)
            if "ENDED s5" not in killed.stdout:
                raise AssertionError(killed.stdout)

            drain_done = Path(env["XDG_RUNTIME_DIR"]) / "detached_drain_done"
            pid, fd = spawn_client(env, ["--alias", "s6"])
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

            log_path = agent_log_file(env, "s6")
            killed = run([".", "kill", "s6"], env, check=True, timeout=5.0)
            if "ENDED s6" not in killed.stdout:
                raise AssertionError(killed.stdout)

            log_text = wait_log_contains(log_path, "event=session_agent_stop")
            for needle in (
                "event=session_agent_start",
                "event=session_create",
                "event=attach",
                "event=detach",
                "event=session_agent_shutdown_requested",
                "event=session_end",
                "event=session_agent_stop",
            ):
                if needle not in log_text:
                    raise AssertionError(f"missing session-agent log entry {needle!r}; log was {log_text!r}")

            stopped = run([".", "kill", "--all"], env, check=True, timeout=5.0)
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
