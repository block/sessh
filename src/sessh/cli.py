from __future__ import annotations

import argparse
import secrets
import sys
from collections.abc import Callable
from datetime import UTC, datetime
from dataclasses import dataclass, field
from pathlib import Path
from typing import TextIO
from typing import Sequence

from sessh import __version__
from sessh.attach import attach_remote_transaction, restore_terminal_on_exit
from sessh.config import load_config
from sessh.diagnostics import ProgressReporter
from sessh.ids import generate_resume_id, is_valid_resume_id
from sessh.remote import SshClient
from sessh.remote_transaction import (
    build_attach_picker_transaction,
    build_attach_interactive_transaction,
    build_list_transaction,
    build_new_interactive_transaction,
    build_run_transaction,
    parse_session_rows,
)
from sessh.run_io import validate_run_ttys
from sessh.sessions import SessionInfo


SSH_OPTIONS_WITH_VALUES = {
    "-B",
    "-b",
    "-c",
    "-D",
    "-E",
    "-e",
    "-F",
    "-I",
    "-i",
    "-J",
    "-L",
    "-l",
    "-m",
    "-o",
    "-P",
    "-p",
    "-R",
}
SSH_FLAG_OPTIONS = {"-4", "-6", "-A", "-a", "-C", "-g", "-K", "-k", "-t", "-tt", "-X", "-x", "-Y"}
INCOMPATIBLE_SSH_OPTIONS = {
    "-f": (
        "it backgrounds ssh after authentication, "
        "but sessh must keep ssh in the foreground to relay the terminal"
    ),
    "-G": "it prints resolved ssh configuration instead of opening a session",
    "-N": (
        "it prevents ssh from running a remote command, "
        "but sessh must run its remote tmux bootstrap"
    ),
    "-n": "it redirects stdin from /dev/null, but sessh needs stdin for interactive sessions",
    "-O": "it controls an existing ssh multiplex master instead of opening a session",
    "-Q": "it queries ssh capabilities instead of opening a session",
    "-s": "it requests an ssh subsystem, but sessh must run its remote tmux bootstrap",
    "-T": (
        "it disables remote TTY allocation, "
        "but sessh requires a remote TTY for tmux-backed sessions"
    ),
    "-W": (
        "it forwards stdio to another host and replaces the remote session stream "
        "that sessh needs"
    ),
}


@dataclass
class ParsedArgs:
    host: str
    command: str
    ssh_options: list[str] = field(default_factory=list)
    config: Path | None = None
    shell: str | None = None
    history_limit: int | None = None
    eval_args: bool = False
    verbose: bool = False
    quiet: bool = False
    resume_id: str | None = None
    remote_argv: list[str] = field(default_factory=list)


def parse_args(argv: Sequence[str] | None = None) -> ParsedArgs:
    tokens = list(sys.argv[1:] if argv is None else argv)
    ssh_options: list[str] = []
    config: Path | None = None
    shell: str | None = None
    history_limit: int | None = None
    eval_args = False
    verbose = False
    quiet = False

    i = 0
    host: str | None = None
    while i < len(tokens):
        token = tokens[i]
        if token == "--help":
            _raise_usage()
        if token == "--version":
            print(f"sessh {__version__}")
            raise SystemExit(0)
        if token == "--config":
            value = _next_value(tokens, i, token)
            config = Path(value)
            i += 2
            continue
        if token == "--shell":
            shell = _next_value(tokens, i, token)
            i += 2
            continue
        if token == "--history-limit":
            value = _next_value(tokens, i, token)
            try:
                history_limit = int(value)
            except ValueError as exc:
                raise SystemExit("--history-limit must be an integer") from exc
            i += 2
            continue
        if token == "--eval-args":
            eval_args = True
            i += 1
            continue
        if token in {"--verbose", "-v"}:
            verbose = True
            i += 1
            continue
        if token in {"--quiet", "-q"}:
            quiet = True
            i += 1
            continue
        parsed_ssh_option = _parse_ssh_option(tokens, i)
        if parsed_ssh_option is not None:
            option_argv, next_index = parsed_ssh_option
            ssh_options.extend(option_argv)
            i = next_index
            continue
        if token.startswith("-"):
            raise SystemExit(f"unknown option before HOST: {token}")
        host = token
        i += 1
        break

    if host is None:
        raise SystemExit("missing HOST")
    if verbose and quiet:
        raise SystemExit("--verbose and --quiet cannot be used together")

    remainder = tokens[i:]
    if not remainder:
        if eval_args:
            raise SystemExit("--eval-args is only valid with run")
        return ParsedArgs(
            host=host,
            command="new",
            ssh_options=ssh_options,
            config=config,
            shell=shell,
            history_limit=history_limit,
            eval_args=eval_args,
            verbose=verbose,
            quiet=quiet,
        )

    command = remainder[0]
    if command in {"resume", "attach"}:
        if eval_args:
            raise SystemExit("--eval-args is only valid with run")
        if len(remainder) > 2:
            raise SystemExit(f"{command} accepts at most one id")
        return ParsedArgs(
            host=host,
            command="attach",
            ssh_options=ssh_options,
            config=config,
            shell=shell,
            history_limit=history_limit,
            eval_args=eval_args,
            verbose=verbose,
            quiet=quiet,
            resume_id=remainder[1] if len(remainder) == 2 else None,
        )

    if command == "list":
        if eval_args:
            raise SystemExit("--eval-args is only valid with run")
        if len(remainder) != 1:
            raise SystemExit("list does not accept arguments")
        return ParsedArgs(
            host=host,
            command="list",
            ssh_options=ssh_options,
            config=config,
            shell=shell,
            history_limit=history_limit,
            eval_args=eval_args,
            verbose=verbose,
            quiet=quiet,
        )

    if command == "run":
        remote_argv = remainder[1:]
        if not remote_argv:
            raise SystemExit("run requires a command")
        return ParsedArgs(
            host=host,
            command="run",
            ssh_options=ssh_options,
            config=config,
            shell=shell,
            history_limit=history_limit,
            eval_args=eval_args,
            verbose=verbose,
            quiet=quiet,
            remote_argv=remote_argv,
        )

    if command.startswith("-"):
        raise SystemExit("options must appear before HOST")
    raise SystemExit(f"unknown command after HOST: {command}")


ConfigLoader = Callable[..., object]
ClientFactory = Callable[..., object]
IdGenerator = Callable[[set[str]], str]


def execute(
    args: ParsedArgs,
    *,
    stdin: TextIO | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    config_loader: ConfigLoader = load_config,
    client_factory: ClientFactory = SshClient,
    id_generator: IdGenerator = generate_resume_id,
) -> int:
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    stdin = sys.stdin if stdin is None else stdin

    if args.command == "run":
        validate_run_ttys(stdout=stdout, stderr=stderr)

    progress = ProgressReporter(stream=stderr, verbose=args.verbose, quiet=args.quiet)
    progress.update(f"connecting to {args.host}")
    try:
        config = config_loader(path=args.config, shell=args.shell, history_limit=args.history_limit)
        client = client_factory(host=args.host, ssh_options=args.ssh_options)

        if args.command == "list":
            progress.update("listing remote sessions")
            result = client.run(build_list_transaction(config), check=True)
            sessions = parse_session_rows(result.stdout)
            progress.clear()
            stdout.write(format_session_list(sessions))
            return 0

        if args.command == "new":
            resume_id = id_generator(set())
            metadata_nonce = generate_metadata_nonce()
            progress.update(f"starting session {resume_id}")
            remote_argv = build_new_interactive_transaction(
                config,
                resume_id=resume_id,
                host=args.host,
                metadata_nonce=metadata_nonce,
            )
            return attach_remote_transaction(
                client,
                remote_argv,
                stderr=stderr,
                stdin=stdin,
                progress=progress,
                resume_command=f"sessh {args.host} attach {resume_id}",
                resume_id=resume_id,
                metadata_nonce=metadata_nonce,
            )

        if args.command == "attach":
            if args.resume_id is None:
                metadata_nonce = generate_metadata_nonce()
                progress.update("selecting session")
                remote_argv = build_attach_picker_transaction(
                    config,
                    host=args.host,
                    metadata_nonce=metadata_nonce,
                )
                return attach_remote_transaction(
                    client,
                    remote_argv,
                    stderr=stderr,
                    stdin=stdin,
                    progress=progress,
                    resume_command=f"sessh {args.host} attach",
                    resume_id=None,
                    metadata_nonce=metadata_nonce,
                )
            if not is_valid_resume_id(args.resume_id):
                raise RuntimeError(f"invalid session id: {args.resume_id}")
            metadata_nonce = generate_metadata_nonce()
            progress.update(f"attaching session {args.resume_id}")
            remote_argv = build_attach_interactive_transaction(
                config,
                resume_id=args.resume_id,
                host=args.host,
                metadata_nonce=metadata_nonce,
            )
            return attach_remote_transaction(
                client,
                remote_argv,
                stderr=stderr,
                stdin=stdin,
                progress=progress,
                resume_command=f"sessh {args.host} attach {args.resume_id}",
                resume_id=args.resume_id,
                metadata_nonce=metadata_nonce,
            )

        if args.command == "run":
            resume_id = id_generator(set())
            metadata_nonce = generate_metadata_nonce()
            progress.update(f"starting run session {resume_id}")
            remote_argv = build_run_transaction(
                config,
                resume_id=resume_id,
                command=args.remote_argv,
                eval_args=args.eval_args,
                host=args.host,
                metadata_nonce=metadata_nonce,
            )
            return attach_remote_transaction(
                client,
                remote_argv,
                stderr=stderr,
                stdin=stdin,
                progress=progress,
                resume_command=f"sessh {args.host} attach {resume_id}",
                resume_id=resume_id,
                metadata_nonce=metadata_nonce,
            )
    except Exception:
        progress.clear()
        raise

    raise NotImplementedError(f"{args.command} is not implemented yet")


def format_session_list(sessions: Sequence[SessionInfo]) -> str:
    lines = ["ID\tATTACHED\tCREATED\tCWD\tCOMMAND\tTITLE"]
    for session in sessions:
        lines.append(
            "\t".join(
                [
                    session.resume_id,
                    "yes" if session.attached_count else "no",
                    _format_created_at(session.created_at),
                    session.working_dir,
                    session.foreground_command,
                    session.window_title,
                ]
            )
        )
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        with restore_terminal_on_exit(sys.stdin):
            return execute(args)
    except SystemExit:
        raise
    except Exception as exc:
        print(f"sessh: {exc}", file=sys.stderr)
        return 1


def _format_created_at(created_at: int) -> str:
    return datetime.fromtimestamp(created_at, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def generate_metadata_nonce() -> str:
    return secrets.token_hex(8)


def _next_value(tokens: Sequence[str], index: int, option: str) -> str:
    try:
        return tokens[index + 1]
    except IndexError as exc:
        raise SystemExit(f"{option} requires a value") from exc


def _parse_ssh_option(tokens: Sequence[str], index: int) -> tuple[list[str], int] | None:
    token = tokens[index]
    incompatible_option = _incompatible_ssh_option(token)
    if incompatible_option is not None:
        raise SystemExit(_format_incompatible_ssh_option_error(token, incompatible_option))
    if token in SSH_OPTIONS_WITH_VALUES:
        value = _next_value(tokens, index, token)
        if token == "-o":
            _reject_incompatible_ssh_config_option(value)
        return [token, value], index + 2
    attached_option = _attached_ssh_option(token, SSH_OPTIONS_WITH_VALUES)
    if attached_option is not None:
        value = token[len(attached_option) :]
        if attached_option == "-o":
            _reject_incompatible_ssh_config_option(value)
        return [attached_option, value], index + 1
    if token in SSH_FLAG_OPTIONS:
        return [token], index + 1
    return None


def _incompatible_ssh_option(token: str) -> str | None:
    if token in INCOMPATIBLE_SSH_OPTIONS:
        return token
    return _attached_ssh_option(token, set(INCOMPATIBLE_SSH_OPTIONS))


def _format_incompatible_ssh_option_error(token: str, option: str) -> str:
    return f"ssh option {token} is not compatible with sessh: {INCOMPATIBLE_SSH_OPTIONS[option]}"


def _reject_incompatible_ssh_config_option(value: str) -> None:
    option, option_value = _parse_ssh_config_option(value)
    if option == "forkafterauthentication" and _is_ssh_config_yes(option_value):
        raise SystemExit(
            "ssh option -o ForkAfterAuthentication=yes is not compatible with sessh: "
            "it backgrounds ssh and implies StdinNull=yes, but sessh must relay an interactive terminal"
        )
    if option == "remotecommand" and option_value.lower() != "none":
        raise SystemExit(
            "ssh option -o RemoteCommand is not compatible with sessh: "
            "sessh must supply its own remote tmux bootstrap command"
        )
    if option == "requesttty" and option_value.lower() == "no":
        raise SystemExit(
            "ssh option -o RequestTTY=no is not compatible with sessh: "
            "it disables remote TTY allocation, but sessh requires a remote TTY for tmux-backed sessions"
        )
    if option == "sessiontype" and option_value.lower() != "default":
        raise SystemExit(
            f"ssh option -o SessionType={option_value} is not compatible with sessh: "
            "it prevents sessh from running its remote tmux bootstrap command"
        )
    if option == "stdinnull" and _is_ssh_config_yes(option_value):
        raise SystemExit(
            "ssh option -o StdinNull=yes is not compatible with sessh: "
            "it prevents ssh from reading stdin, but sessh needs stdin for interactive sessions"
        )


def _parse_ssh_config_option(value: str) -> tuple[str, str]:
    stripped = value.strip()
    if "=" in stripped:
        option, option_value = stripped.split("=", 1)
    else:
        parts = stripped.split(None, 1)
        option = parts[0] if parts else ""
        option_value = parts[1] if len(parts) == 2 else ""
    return option.lower(), option_value.strip()


def _is_ssh_config_yes(value: str) -> bool:
    return value.lower() in {"yes", "true"}


def _attached_ssh_option(token: str, options: set[str]) -> str | None:
    for option in sorted(options, key=len, reverse=True):
        if token != option and token.startswith(option):
            return option
    return None


def _raise_usage() -> None:
    parser = argparse.ArgumentParser(prog="sessh")
    parser.print_help()
    raise SystemExit(0)
