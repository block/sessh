from __future__ import annotations

import os
import sys
import termios
from collections.abc import Mapping, Sequence
from contextlib import contextmanager
from typing import Protocol, TextIO

from sessh.diagnostics import ProgressReporter
from sessh.pty_relay import run_pty_relay
from sessh.ssh_command import build_ssh_argv


class AttachClient(Protocol):
    host: str
    ssh_options: list[str]
    ssh_bin: str


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
) -> int:
    stdin = sys.stdin if stdin is None else stdin
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
            result = run_pty_relay(
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

    if result.exit_status == 255 and result.final_event in {"detached", "exited"}:
        return (
            result.remote_exit_status
            if result.remote_exit_status is not None
            else result.exit_status
        )

    if result.exit_status == 255 and resume_command is not None:
        known_resume_id = result.resume_id or resume_id
        known_resume_command = resume_command
        if resume_id is None and known_resume_id is not None:
            known_resume_command = f"{resume_command} {known_resume_id}"
        write_terminal_boundary_on_new_line(
            stderr, "sessh detached", resume_id=known_resume_id
        )
        stderr.write(f"\nTo attach to this session, run:\n  {known_resume_command}\n")
        stderr.flush()
    return result.exit_status


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
