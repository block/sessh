from __future__ import annotations

import os
import select
import sys
import termios
import time
from collections.abc import Callable, Mapping, Sequence
from contextlib import contextmanager
from typing import Protocol, TextIO

from sessh.diagnostics import ProgressReporter
from sessh.pty_relay import RelayResult, run_pty_relay
from sessh.ssh_command import build_ssh_argv


class AttachClient(Protocol):
    host: str
    ssh_options: list[str]
    ssh_bin: str


ReattachRemoteArgvBuilder = Callable[[str], Sequence[str]]
AUTO_REATTACH_INITIAL_DELAY = 1.0
AUTO_REATTACH_MAX_DELAY = 30.0


def attach_remote_transaction(
    client: AttachClient,
    remote_argv: Sequence[str],
    *,
    stdin: TextIO | None = None,
    stderr: TextIO,
    progress: ProgressReporter | None = None,
    resume_command: str | None = None,
    resume_id: str | None = None,
    metadata_nonce: str,
    auto_reattach: bool = False,
    reattach_remote_argv_builder: ReattachRemoteArgvBuilder | None = None,
    auto_reattach_initial_delay: float = AUTO_REATTACH_INITIAL_DELAY,
    auto_reattach_max_delay: float = AUTO_REATTACH_MAX_DELAY,
) -> int:
    stdin = sys.stdin if stdin is None else stdin
    current_remote_argv = list(remote_argv)
    known_resume_id: str | None = None
    delay = auto_reattach_initial_delay

    while True:
        result = _run_remote_transaction_once(
            client,
            current_remote_argv,
            stdin=stdin,
            stderr=stderr,
            progress=progress,
            metadata_nonce=metadata_nonce,
        )

        if result.resume_id is not None:
            known_resume_id = result.resume_id

        final_exit_status = _final_remote_exit_status(result)
        if final_exit_status is not None:
            return final_exit_status

        if (
            result.exit_status == 255
            and auto_reattach
            and not result.user_requested_disconnect
            and known_resume_id is not None
            and reattach_remote_argv_builder is not None
        ):
            if result.final_event != "detached":
                write_terminal_boundary_on_new_line(
                    stderr, "sessh detached", resume_id=known_resume_id
                )
            _wait_before_auto_reattach(
                stdin,
                stderr,
                delay,
                resume_id=known_resume_id,
            )
            _write_auto_reattach_attempt(stderr, known_resume_id)
            current_remote_argv = list(reattach_remote_argv_builder(known_resume_id))
            delay = min(delay * 2, auto_reattach_max_delay)
            continue

        if (
            result.exit_status == 255
            and result.final_event != "detached"
            and resume_command is not None
        ):
            known_manual_resume_id = result.resume_id or resume_id
            _write_manual_resume_message(
                stderr,
                resume_command=resume_command,
                resume_id=resume_id,
                known_resume_id=known_manual_resume_id,
            )
        return result.exit_status


def _run_remote_transaction_once(
    client: AttachClient,
    remote_argv: Sequence[str],
    *,
    stdin: TextIO,
    stderr: TextIO,
    progress: ProgressReporter | None,
    metadata_nonce: str,
) -> RelayResult:
    argv = build_ssh_argv(
        ssh_options=force_tty_ssh_options(client.ssh_options),
        host=client.host,
        remote_argv=remote_argv,
        ssh_bin=client.ssh_bin,
    )
    try:
        with restore_terminal_on_exit(stdin):
            if progress is not None:
                progress.clear()
            return run_pty_relay(
                argv,
                stdin=stdin,
                output=stderr,
                env=attach_environment(),
                nonce=metadata_nonce,
            )
    except KeyboardInterrupt:
        if progress is not None:
            progress.clear()
        raise


def _final_remote_exit_status(result: RelayResult) -> int | None:
    if (
        result.exit_status == 255
        and result.final_event == "exited"
        and result.remote_exit_status is not None
    ):
        return result.remote_exit_status
    return None


def _write_manual_resume_message(
    stderr: TextIO,
    *,
    resume_command: str,
    resume_id: str | None,
    known_resume_id: str | None,
) -> None:
    known_resume_command = resume_command
    if resume_id is None and known_resume_id is not None:
        known_resume_command = f"{resume_command} {known_resume_id}"
    write_terminal_boundary_on_new_line(
        stderr, "sessh detached", resume_id=known_resume_id
    )
    stderr.write(f"\nTo attach to this session, run:\n  {known_resume_command}\n")
    stderr.flush()


def _wait_before_auto_reattach(
    stdin: TextIO,
    stderr: TextIO,
    delay: float,
    *,
    resume_id: str,
) -> None:
    if delay <= 0:
        return

    deadline = time.monotonic() + delay
    last_displayed_remaining: int | None = None
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        displayed_remaining = max(1, int(remaining + 0.999))
        if displayed_remaining != last_displayed_remaining:
            _write_auto_reattach_wait(stderr, resume_id, displayed_remaining)
            last_displayed_remaining = displayed_remaining
        if _read_retry_request(stdin, min(0.2, remaining)):
            break
    _clear_dynamic_terminal_line(stderr)


def _read_retry_request(stdin: TextIO, timeout: float) -> bool:
    try:
        fd = stdin.fileno()
    except (AttributeError, OSError):
        time.sleep(timeout)
        return False
    try:
        readable, _, _ = select.select([fd], [], [], timeout)
    except (OSError, ValueError):
        time.sleep(timeout)
        return False
    if not readable:
        return False
    try:
        return bool(os.read(fd, 65536))
    except OSError:
        return False


def _write_auto_reattach_wait(
    stderr: TextIO, resume_id: str, remaining_seconds: int
) -> None:
    message = (
        f"sessh: connection lost for {resume_id}; auto-reattaching in "
        f"{remaining_seconds}s (Enter retry now, Ctrl-C cancel)"
    )
    if _stream_isatty(stderr):
        stderr.write(f"\r\033[K{message}")
    else:
        stderr.write(f"{message}\n")
    stderr.flush()


def _write_auto_reattach_attempt(stderr: TextIO, resume_id: str) -> None:
    _clear_dynamic_terminal_line(stderr)
    stderr.write(f"sessh: reattaching session {resume_id}\n")
    stderr.flush()


def _clear_dynamic_terminal_line(stderr: TextIO) -> None:
    if _stream_isatty(stderr):
        stderr.write("\r\033[K")
        stderr.flush()


def _stream_isatty(stream: TextIO) -> bool:
    try:
        return stream.isatty()
    except (AttributeError, OSError):
        return False


def force_tty_ssh_options(ssh_options: Sequence[str]) -> list[str]:
    if "-T" in ssh_options:
        raise ValueError("sessh requires a remote TTY; remove -T")

    forced = list(ssh_options)
    if not _has_log_level_option(forced):
        forced.extend(["-o", "LogLevel=ERROR"])
    if "-tt" in forced:
        return forced

    t_count = sum(1 for option in forced if option == "-t")
    while t_count < 2:
        forced.append("-t")
        t_count += 1
    return forced


def _has_log_level_option(ssh_options: Sequence[str]) -> bool:
    for index, option in enumerate(ssh_options):
        if option == "-q":
            return True
        if option == "-o":
            try:
                value = ssh_options[index + 1]
            except IndexError:
                continue
            if value.lower().replace(" ", "").startswith("loglevel="):
                return True
        if option.lower().startswith("-ologlevel="):
            return True
    return False


def attach_environment(environ: Mapping[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ if environ is None else environ)
    term = env.get("TERM", "")
    if term in {"", "dumb", "unknown"} or not _is_portable_term(term):
        env["TERM"] = "xterm-256color"
    return env


def _is_portable_term(term: str) -> bool:
    return term in {
        "xterm",
        "xterm-256color",
        "screen",
        "screen-256color",
        "tmux",
        "tmux-256color",
    }


def write_terminal_boundary_on_new_line(
    stream: TextIO, label: str, *, resume_id: str | None = None
) -> None:
    try:
        if not stream.isatty():
            return
    except (AttributeError, OSError):
        return

    stream.write("\r\n")
    stream.write(format_terminal_boundary(label, resume_id=resume_id))
    stream.flush()


def format_terminal_boundary(label: str, *, resume_id: str | None = None) -> str:
    if resume_id:
        return f"--- {label} {resume_id} ---\n"
    return f"--- {label} ---\n"


@contextmanager
def restore_terminal_on_exit(stream):
    fd = None
    attrs = None
    try:
        if stream is not None and stream.isatty():
            fd = stream.fileno()
            attrs = termios.tcgetattr(fd)
    except (AttributeError, OSError, termios.error):
        fd = None
        attrs = None

    try:
        yield
    finally:
        if fd is not None and attrs is not None:
            try:
                termios.tcflush(fd, termios.TCIFLUSH)
                termios.tcsetattr(fd, termios.TCSADRAIN, attrs)
            except termios.error:
                pass
