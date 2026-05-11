from __future__ import annotations

from typing import Protocol


class SupportsIsatty(Protocol):
    def isatty(self) -> bool: ...


class TtyError(RuntimeError):
    pass


RunTtyError = TtyError


def validate_session_ttys(
    *,
    stdin: SupportsIsatty,
    stdout: SupportsIsatty,
    stderr: SupportsIsatty,
) -> None:
    validate_session_tty_state(
        stdin_is_tty=stdin.isatty(),
        stdout_is_tty=stdout.isatty(),
        stderr_is_tty=stderr.isatty(),
    )


def validate_run_ttys(
    *,
    stdin: SupportsIsatty,
    stdout: SupportsIsatty,
    stderr: SupportsIsatty,
) -> None:
    validate_session_ttys(stdin=stdin, stdout=stdout, stderr=stderr)


def validate_session_tty_state(
    *, stdin_is_tty: bool, stdout_is_tty: bool, stderr_is_tty: bool
) -> None:
    missing = []
    if not stdin_is_tty:
        missing.append("stdin")
    if not stdout_is_tty:
        missing.append("stdout")
    if not stderr_is_tty:
        missing.append("stderr")

    if not missing:
        return

    raise TtyError(
        f"sessh sessions require {_format_stream_list(missing)} "
        "to be connected to a TTY"
    )


validate_run_tty_state = validate_session_tty_state


def _format_stream_list(streams: list[str]) -> str:
    if len(streams) == 1:
        return streams[0]
    if len(streams) == 2:
        return f"{streams[0]} and {streams[1]}"
    return f"{', '.join(streams[:-1])}, and {streams[-1]}"
