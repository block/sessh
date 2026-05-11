from __future__ import annotations

from typing import Protocol


class SupportsIsatty(Protocol):
    def isatty(self) -> bool: ...


class RunTtyError(RuntimeError):
    pass


def validate_run_ttys(*, stdout: SupportsIsatty, stderr: SupportsIsatty) -> None:
    validate_run_tty_state(stdout_is_tty=stdout.isatty(), stderr_is_tty=stderr.isatty())


def validate_run_tty_state(*, stdout_is_tty: bool, stderr_is_tty: bool) -> None:
    if stdout_is_tty and stderr_is_tty:
        return
    if not stdout_is_tty and not stderr_is_tty:
        raise RunTtyError("sessh run requires stdout and stderr to be connected to a TTY")
    if not stdout_is_tty:
        raise RunTtyError("sessh run requires stdout to be connected to a TTY")
    raise RunTtyError("sessh run requires stderr to be connected to a TTY")
