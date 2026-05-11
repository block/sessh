from __future__ import annotations

from collections.abc import Sequence
from functools import cache
from importlib.resources import files

from sessh.config import Config
from sessh.sessions import SessionInfo


def build_list_transaction(config: Config) -> list[str]:
    return _transaction_argv(config, "list", metadata_nonce="")


def build_new_interactive_transaction(
    config: Config,
    *,
    resume_id: str,
    host: str,
    metadata_nonce: str,
) -> list[str]:
    return _transaction_argv(
        config, "new-interactive", resume_id, host, metadata_nonce=metadata_nonce
    )


def build_attach_interactive_transaction(
    config: Config,
    *,
    resume_id: str,
    host: str,
    metadata_nonce: str,
) -> list[str]:
    return _transaction_argv(
        config, "attach-interactive", resume_id, host, metadata_nonce=metadata_nonce
    )


def build_attach_picker_transaction(
    config: Config,
    *,
    host: str,
    metadata_nonce: str,
) -> list[str]:
    return _transaction_argv(
        config, "attach-picker", host, metadata_nonce=metadata_nonce
    )


def build_run_transaction(
    config: Config,
    *,
    resume_id: str,
    command: Sequence[str],
    eval_args: bool,
    host: str,
    metadata_nonce: str,
) -> list[str]:
    if not command:
        raise ValueError("run requires a command")
    return _transaction_argv(
        config,
        "run",
        resume_id,
        host,
        "1" if eval_args else "0",
        "" if eval_args else _command_name(command[0]),
        *command,
        metadata_nonce=metadata_nonce,
    )


def parse_session_rows(output: str) -> list[SessionInfo]:
    sessions: list[SessionInfo] = []
    for line in output.splitlines():
        if not line:
            continue
        fields = line.split("\t")
        while len(fields) < 6:
            fields.append("")
        resume_id, attached, created, working_dir, command, title = fields[:6]
        sessions.append(
            SessionInfo(
                resume_id=resume_id,
                attached_count=int(attached),
                created_at=int(created),
                working_dir=working_dir,
                foreground_command=command,
                window_title=title,
            )
        )
    return sessions


def _transaction_argv(
    config: Config, mode: str, *args: str, metadata_nonce: str
) -> list[str]:
    if config.remote_rc is None:
        raise ValueError("remote_rc must be populated")
    return [
        "sh",
        "-c",
        _remote_shell_program() + '\nsessh_main "$@"\n',
        "sessh",
        mode,
        config.shell,
        str(config.history_limit),
        config.remote_init,
        config.remote_rc,
        metadata_nonce,
        *args,
    ]


@cache
def _remote_shell_program() -> str:
    return files("sessh").joinpath("remote.sh").read_text(encoding="utf-8")


def _command_name(command: str) -> str:
    return command.rsplit("/", 1)[-1]
