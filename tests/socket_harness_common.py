#!/usr/bin/env python3
import hashlib
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
BIN = Path(os.environ.get("SESSH_TEST_BIN", str(ROOT / "zig-out" / "bin" / "sessh")))
_PROTO_TMP = None
_PROTO_MODULE = None
_PROTO_HANDSHAKE_MODULE = None
_FRAME_HEADER_LEN = 4
_LAST_RESIZE = (24, 80)
_NEXT_REPAINT_REQUEST_SEQ = 1
_SCROLLBACK_CURSOR_LEN = 16
_GUID_RE = re.compile(r"^s-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

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
MUX_STREAM_FRAME = "mux_stream_frame"
REMOTE_PROCESS_STARTED = "remote_process_started"
REMOTE_PROCESS_RECORDED = "remote_process_recorded"
REMOTE_PROCESS_CLEANUP_REQUEST = "remote_process_cleanup_request"
REMOTE_PROCESS_CLEANUP_RESPONSE = "remote_process_cleanup_response"
CLIENT_DAEMON = "client_daemon"

_HELLO_FRAME_FIELDS = {
    HELLO_REQUEST: HELLO_REQUEST,
    HELLO_OK: HELLO_OK,
    HELLO_ERROR: HELLO_ERROR,
}
_FRAME_FIELDS = {
    ERROR: ERROR,
    CLIENT_DAEMON: CLIENT_DAEMON,
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


def daemon_namespace_executable():
    path = BIN if BIN.is_absolute() else ROOT / BIN
    if path.name == "sessh-dev":
        return path
    os_name, arch = canonical_local_platform()
    wrapper_artifact = platform_wrapper_executable(path, "sessh")
    if wrapper_artifact.exists():
        return wrapper_artifact
    artifact = ROOT / "zig-out" / "libexec" / "sessh" / f"{os_name}-{arch}" / "sessh"
    if artifact.exists():
        return artifact
    return path


def platform_wrapper_executable(wrapper, name):
    os_name, arch = canonical_local_platform()
    return wrapper.parent / ".." / "libexec" / "sessh" / f"{os_name}-{arch}" / name


def sessh_protocol_major():
    for line in (ROOT / "src" / "core" / "config.zig").read_text().splitlines():
        match = re.match(r"pub const protocol_major = ([0-9]+);", line)
        if match:
            return int(match.group(1))
    raise AssertionError("could not find sessh protocol_major")


def daemon_socket_dir_name():
    return daemon_socket_dir_name_for_executable(daemon_namespace_executable())


def daemon_socket_dir_name_for_executable(executable):
    version = sessh_version()
    base = str(sessh_protocol_major())
    if not version.endswith("-dev"):
        return base
    return f"{base}.dev.{hashlib.sha256(executable.read_bytes()).hexdigest()[:8]}"


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


def send_escape_close(fd):
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


def process_command_basename(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "command="],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(result)
    command = result.stdout.strip()
    if not command:
        raise AssertionError(f"missing command for pid {pid}")
    return Path(command.split()[0]).name


def wait_process_command_containing(needle, timeout=5.0):
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        result = subprocess.run(
            ["ps", "-axo", "pid=,command="],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        last = result.stdout
        for line in result.stdout.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            _pid_text, _sep, command = stripped.partition(" ")
            if needle in command:
                return command
        time.sleep(0.05)
    raise AssertionError(f"did not find process command containing {needle!r}; saw {last!r}")


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
    return sessh_pb().TerminalEmulatorItem.Input(data=value, input_seq=input_seq).SerializeToString()


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
    isolation_mode=None,
):
    global _NEXT_REPAINT_REQUEST_SEQ
    pb = sessh_pb()
    message = pb.TerminalEmulatorItem.Open()
    create = message.create
    create.scrollback_row_limit = scrollback
    if session_id is None:
        session_id = test_session_guid(1)
    message.session_guid = guid_for_ref(session_id)
    if isolation_mode is not None:
        message.isolation_mode = isolation_mode
    rows, cols = _LAST_RESIZE
    message.resize.terminal_rows = rows
    message.resize.terminal_cols = cols
    repaint = message.resize.repaint_request
    repaint.repaint_request_seq = _NEXT_REPAINT_REQUEST_SEQ
    _NEXT_REPAINT_REQUEST_SEQ += 1
    repaint.scrollback_cursor = b""
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


def pack_session_attach(reconnect_cursor=None, session_guid=""):
    global _NEXT_REPAINT_REQUEST_SEQ
    pb = sessh_pb()
    message = pb.TerminalEmulatorItem.Open()
    message.session_guid = session_guid
    rows, cols = _LAST_RESIZE
    message.resize.terminal_rows = rows
    message.resize.terminal_cols = cols
    repaint = message.resize.repaint_request
    repaint.repaint_request_seq = _NEXT_REPAINT_REQUEST_SEQ
    _NEXT_REPAINT_REQUEST_SEQ += 1
    if reconnect_cursor is not None:
        epoch, cursor = reconnect_cursor
        repaint.scrollback_cursor = encode_scrollback_cursor(epoch, cursor)
    return message.SerializeToString()


def send_resize(conn, rows=24, cols=80, repaint=None, viewport_offset=None):
    global _LAST_RESIZE
    _LAST_RESIZE = (rows, cols)
    message = sessh_pb().TerminalEmulatorItem.Resize(terminal_rows=rows, terminal_cols=cols)
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
    message = sessh_pb().TerminalEmulatorItem.Resize(terminal_rows=rows, terminal_cols=cols)
    if viewport_offset is not None:
        message.viewport_offset = viewport_offset
    message.repaint_request.repaint_request_seq = repaint_request_seq
    send_frame(conn, RESIZE, message.SerializeToString())


def pack_repaint(repaint_request_seq, scrollback_cursor=None, scrollback_epoch=0):
    message = sessh_pb().TerminalEmulatorItem.RepaintRequest(repaint_request_seq=repaint_request_seq)
    if scrollback_cursor is not None:
        message.scrollback_cursor = encode_request_scrollback_cursor(scrollback_epoch, scrollback_cursor)
    return message.SerializeToString()


def parse_input_ack(payload):
    message = sessh_pb().TerminalEmulatorItem.InputAck()
    message.ParseFromString(payload)
    return message.input_seq


def parse_session_ended(payload):
    message = sessh_pb().TerminalEmulatorItem.SessionEnded()
    message.ParseFromString(payload)
    return message


def assert_session_attached(payload):
    message = sessh_pb().TerminalEmulatorItem.SessionAttached()
    message.ParseFromString(payload)
    return message


def create_and_attach_session(
    conn,
    shell,
    scrollback=2000,
    fg=0xFFFFFFFF,
    bg=0xFFFFFFFF,
    session_id=None,
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
        ),
    )


def parse_draw(payload):
    message = sessh_pb().TerminalEmulatorItem.Draw()
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
    message = sessh_pb().TerminalEmulatorItem.RepaintResponse()
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


def recv_mux_frame(conn, timeout=5.0):
    old_timeout = conn.gettimeout()
    conn.settimeout(timeout)
    try:
        while True:
            message_kind, payload = recv_frame(conn)
            if message_kind != MUX_STREAM_FRAME:
                continue
            mux = sessh_pb().DaemonTunnelItem.MuxStreamFrame()
            mux.ParseFromString(payload)
            return mux
    finally:
        conn.settimeout(old_timeout)


def send_mux_te_open(conn, shell, stream_id=1, session_id=None, isolation_mode=None):
    te_open = sessh_pb().TerminalEmulatorItem.Open()
    te_open.ParseFromString(pack_session_create(shell, session_id=session_id, isolation_mode=isolation_mode))
    mux = sessh_pb().DaemonTunnelItem.MuxStreamFrame(stream_id=stream_id)
    mux.open.recv_next_offset = 0
    send_frame(conn, MUX_STREAM_FRAME, mux.SerializeToString())
    payload = sessh_pb().DaemonTunnelItem.MuxStreamFrame(stream_id=stream_id)
    payload.payload.offset = 0
    payload.payload.terminal_emulator.open.CopyFrom(te_open)
    send_frame(conn, MUX_STREAM_FRAME, payload.SerializeToString())


def recv_mux_te_payload_frame(conn, expected_payload, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        mux = recv_mux_frame(conn, timeout=max(0.1, end - time.monotonic()))
        if mux.WhichOneof("message") != "payload":
            continue
        if mux.payload.WhichOneof("item") != "terminal_emulator":
            continue
        if mux.payload.terminal_emulator.WhichOneof("payload") == expected_payload:
            return mux
    raise AssertionError(f"did not receive mux terminal payload {expected_payload}")


def recv_mux_te_payload(conn, expected_payload, timeout=5.0):
    return recv_mux_te_payload_frame(conn, expected_payload, timeout=timeout).payload.terminal_emulator


def recv_mux_eof(conn, stream_id=1, expected_final_offset=None, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        mux = recv_mux_frame(conn, timeout=max(0.1, end - time.monotonic()))
        if mux.stream_id != stream_id:
            continue
        if mux.WhichOneof("message") != "eof":
            continue
        if expected_final_offset is not None and mux.eof.final_offset != expected_final_offset:
            raise AssertionError(
                f"unexpected mux eof offset: expected {expected_final_offset}, got {mux.eof.final_offset}"
            )
        return mux.eof
    raise AssertionError(f"did not receive mux eof for stream {stream_id}")


def recv_mux_session_ended_then_eof_without_reset(conn, stream_id=1, timeout=5.0):
    end = time.monotonic() + timeout
    ended_mux = None
    while time.monotonic() < end:
        mux = recv_mux_frame(conn, timeout=max(0.1, end - time.monotonic()))
        if mux.stream_id != stream_id:
            continue
        message = mux.WhichOneof("message")
        if message == "reset":
            raise AssertionError(f"graceful terminal session emitted mux reset: {mux!r}")
        if message == "payload":
            if mux.payload.WhichOneof("item") != "terminal_emulator":
                continue
            if mux.payload.terminal_emulator.WhichOneof("payload") == "session_ended":
                ended_mux = mux
            continue
        if message == "eof":
            if ended_mux is None:
                raise AssertionError(f"mux eof arrived before terminal session_ended: {mux!r}")
            expected_offset = ended_mux.payload.offset + 1
            if mux.eof.final_offset != expected_offset:
                raise AssertionError(
                    f"unexpected mux eof offset: expected {expected_offset}, got {mux.eof.final_offset}"
                )
            return ended_mux, mux.eof
    raise AssertionError("did not receive terminal session_ended followed by mux eof")


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
    if message_kind in (PING, PONG, MUX_STREAM_FRAME):
        frame = sessh_pb().Frame()
        if message_kind == MUX_STREAM_FRAME:
            set_submessage(frame.daemon_tunnel, "mux_stream", payload)
        else:
            set_submessage(frame.daemon_tunnel, message_kind, payload)
        return frame.SerializeToString()
    if message_kind in _TE_STREAM_ITEM_FIELDS:
        frame = sessh_pb().Frame()
        item = sessh_pb().TerminalEmulatorItem()
        set_submessage(item, _TE_STREAM_ITEM_FIELDS[message_kind], payload)
        frame.client_remote.terminal_emulator.CopyFrom(item)
        return frame.SerializeToString()
    raise AssertionError(f"unknown test message kind: {message_kind}")


def set_submessage(frame, field_name, payload):
    field = frame.DESCRIPTOR.fields_by_name[field_name]
    submessage = field.message_type._concrete_class()
    submessage.ParseFromString(payload)
    getattr(frame, field_name).CopyFrom(submessage)


def recv_frame(conn):
    header = recv_exact(conn, _FRAME_HEADER_LEN)
    (message_len,) = struct.unpack(">I", header)
    body = recv_exact(conn, message_len)
    hello_frame = sessh_hpb().HelloFrame()
    hello_frame.ParseFromString(body)
    hello_field = hello_frame.WhichOneof("payload")
    if hello_field is not None:
        return hello_field, getattr(hello_frame, hello_field).SerializeToString()

    frame = sessh_pb().Frame()
    frame.ParseFromString(body)
    if frame.HasField("attached") and frame.attached.attached_bytes_len:
        attached = recv_exact(conn, frame.attached.attached_bytes_len)
        raise AssertionError(f"unexpected attached bytes in socket harness: {attached!r}")
    field = frame.WhichOneof("payload")
    if field is None:
        raise AssertionError(f"missing frame payload: {body!r}")
    if field == "client_remote":
        if frame.client_remote.WhichOneof("payload") != "terminal_emulator":
            return field, getattr(frame, field).SerializeToString()
        item = frame.client_remote.terminal_emulator
        item_field = item.WhichOneof("payload")
        if item_field is None:
            raise AssertionError(f"missing terminal stream item payload: {body!r}")
        for message_kind, mapped_field in _TE_STREAM_ITEM_FIELDS.items():
            if mapped_field == item_field:
                return message_kind, getattr(item, item_field).SerializeToString()
        raise AssertionError(f"unknown terminal stream item payload: {item_field}")
    if field == "daemon_tunnel":
        tunnel_field = frame.daemon_tunnel.WhichOneof("payload")
        if tunnel_field is None:
            raise AssertionError(f"missing daemon tunnel payload: {body!r}")
        if tunnel_field == "mux_stream":
            return MUX_STREAM_FRAME, frame.daemon_tunnel.mux_stream.SerializeToString()
        if tunnel_field in (
            PING,
            PONG,
            REMOTE_PROCESS_STARTED,
            REMOTE_PROCESS_RECORDED,
            REMOTE_PROCESS_CLEANUP_REQUEST,
            REMOTE_PROCESS_CLEANUP_RESPONSE,
        ):
            return tunnel_field, getattr(frame.daemon_tunnel, tunnel_field).SerializeToString()
        raise AssertionError(f"unknown daemon tunnel payload: {tunnel_field}")
    return field, getattr(frame, field).SerializeToString()


def recv_exact(conn, length):
    data = b""
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            raise AssertionError("connection closed while reading frame")
        data += chunk
    return data


def read_until_pipe(pipe, needle, timeout=5.0):
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


def runtime_root(env):
    return Path(env["XDG_RUNTIME_DIR"])


def state_root(env):
    return Path(env["XDG_STATE_HOME"]) / "sessh"


def guid_for_ref(ref):
    if _GUID_RE.match(ref):
        return ref.lower()
    raise AssertionError(f"invalid guid ref: {ref}")


def assert_runtime_dir_symlink(env, expected_runtime_root):
    link = Path(env["XDG_CACHE_HOME"]) / "sessh" / "runtime_dir"
    if not link.is_symlink():
        raise AssertionError(f"runtime dir pointer is missing: {link}")
    actual = Path(os.readlink(link))
    if actual != Path(expected_runtime_root):
        raise AssertionError(f"runtime dir pointer target mismatch: expected {expected_runtime_root}, got {actual}")


def socket_path(env, session_id=None):
    _ = session_id
    return runtime_root(env) / daemon_socket_dir_name() / "sesshd.sock"


def socket_path_for_dir(env, dir_name):
    return runtime_root(env) / dir_name / "sesshd.sock"


def start_daemon(env, session_id=None):
    _ = session_id
    path = socket_path(env, session_id)
    proc = subprocess.Popen(
        [str(BIN), ":daemon:"],
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    wait_file(path)
    return proc


def terminal_remote_pids(env):
    pids = []
    daemon_exe = socket_path(env).parent / "sesshd"
    try:
        output = subprocess.check_output(["ps", "-eo", "pid=,command="], text=True)
    except subprocess.CalledProcessError:
        return pids
    needle = str(daemon_exe)
    for line in output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid_text, command = parts
        if needle not in command:
            continue
        try:
            pids.append(int(pid_text))
        except ValueError:
            pass
    return pids
