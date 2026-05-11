from __future__ import annotations

import shlex
from collections.abc import Sequence


MAX_REMOTE_COMMAND_BYTES = 100_000


def build_ssh_argv(
    *,
    ssh_options: Sequence[str],
    host: str,
    remote_argv: Sequence[str],
    ssh_bin: str = "ssh",
) -> list[str]:
    if not remote_argv:
        raise ValueError("remote_argv must not be empty")
    if not host:
        raise ValueError("host must not be empty")

    remote_command = shell_quote_command(remote_argv)
    remote_command_bytes = len(remote_command.encode("utf-8"))
    if remote_command_bytes > MAX_REMOTE_COMMAND_BYTES:
        raise ValueError(
            "remote command is too large for reliable ssh execution "
            f"({remote_command_bytes} bytes > {MAX_REMOTE_COMMAND_BYTES} bytes)"
        )

    return [ssh_bin, *ssh_options, host, remote_command]


def shell_quote_command(argv: Sequence[str]) -> str:
    return shlex.join(argv)
