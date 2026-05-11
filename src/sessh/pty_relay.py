from __future__ import annotations

import fcntl
import os
import select
import signal
import struct
import termios
import tty
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import TextIO

from ptyprocess import PtyProcess

from sessh.sidechannel import SideChannelEvent, SideChannelParser


@dataclass
class RelayResult:
    exit_status: int
    events: list[SideChannelEvent] = field(default_factory=list)
    resume_id: str | None = None
    final_event: str | None = None
    remote_exit_status: int | None = None
    user_requested_disconnect: bool = False


def run_pty_relay(
    argv: Sequence[str],
    *,
    stdin: TextIO,
    output: TextIO,
    env: Mapping[str, str],
    nonce: str,
) -> RelayResult:
    stdin_fd = stdin.fileno()
    output_fd = output.fileno()
    rows, cols = _terminal_size(stdin_fd)
    child = PtyProcess.spawn(list(argv), env=dict(env), dimensions=(rows, cols))
    parser = SideChannelParser(nonce)
    result = RelayResult(exit_status=1)
    escape_detector = SshEscapeDisconnectDetector()
    previous_winch = signal.getsignal(signal.SIGWINCH)

    def resize_child(signum, frame):  # noqa: ARG001
        child.setwinsize(*_terminal_size(stdin_fd))

    try:
        with _raw_terminal(stdin_fd):
            signal.signal(signal.SIGWINCH, resize_child)
            stdin_open = True
            while True:
                read_fds = [child.fd]
                if stdin_open and _fd_is_open(stdin_fd):
                    read_fds.append(stdin_fd)
                readable, _, _ = select.select(read_fds, [], [])

                if stdin_fd in readable:
                    data = os.read(stdin_fd, 65536)
                    if data:
                        if escape_detector.feed(data):
                            result.user_requested_disconnect = True
                        child.write(data)
                    else:
                        stdin_open = False

                if child.fd in readable:
                    try:
                        data = child.read(65536)
                    except EOFError:
                        break
                    visible, events = parser.feed(data)
                    _record_events(result, events)
                    if visible:
                        _write_all(output_fd, visible)

            remaining = parser.flush()
            if remaining:
                _write_all(output_fd, remaining)
    finally:
        signal.signal(signal.SIGWINCH, previous_winch)

    child.wait()
    if child.exitstatus is not None:
        result.exit_status = child.exitstatus
    elif child.signalstatus is not None:
        result.exit_status = 128 + child.signalstatus
    else:
        result.exit_status = 1
    return result


class SshEscapeDisconnectDetector:
    def __init__(self) -> None:
        self._at_line_start = True
        self._after_tilde_at_line_start = False

    def feed(self, data: bytes) -> bool:
        user_requested_disconnect = False
        for byte in data:
            if self._after_tilde_at_line_start:
                if byte == ord("."):
                    user_requested_disconnect = True
                self._after_tilde_at_line_start = False
                self._at_line_start = byte in {ord("\r"), ord("\n")}
                continue

            if self._at_line_start and byte == ord("~"):
                self._after_tilde_at_line_start = True
                continue

            self._at_line_start = byte in {ord("\r"), ord("\n")}
        return user_requested_disconnect


def _record_events(result: RelayResult, events: list[SideChannelEvent]) -> None:
    for event in events:
        result.events.append(event)
        if event.name in {"created", "attached"} and event.fields:
            result.resume_id = event.fields[0]
        elif event.name == "detached" and event.fields:
            result.resume_id = event.fields[0]
            result.final_event = event.name
        elif event.name == "exited" and event.fields:
            result.resume_id = event.fields[0]
            result.final_event = event.name
            if len(event.fields) > 1:
                try:
                    result.remote_exit_status = int(event.fields[1])
                except ValueError:
                    result.remote_exit_status = None


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written == 0:
            raise OSError("terminal write returned 0 bytes")
        view = view[written:]


def _terminal_size(fd: int) -> tuple[int, int]:
    try:
        packed = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
        rows, cols, _, _ = struct.unpack("HHHH", packed)
    except OSError:
        return 24, 80
    if rows <= 0 or cols <= 0:
        return 24, 80
    return rows, cols


def _fd_is_open(fd: int) -> bool:
    try:
        os.fstat(fd)
    except OSError:
        return False
    return True


class _raw_terminal:
    def __init__(self, fd: int):
        self._fd = fd
        self._attrs = None

    def __enter__(self):
        try:
            self._attrs = termios.tcgetattr(self._fd)
            tty.setraw(self._fd)
        except termios.error:
            self._attrs = None
        return self

    def __exit__(self, exc_type, exc, tb):
        if self._attrs is not None:
            try:
                termios.tcflush(self._fd, termios.TCIFLUSH)
                termios.tcsetattr(self._fd, termios.TCSADRAIN, self._attrs)
            except termios.error:
                pass
