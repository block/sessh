from __future__ import annotations

import subprocess
from collections.abc import Callable, Sequence

from sessh.ssh_command import build_ssh_argv


Runner = Callable[..., subprocess.CompletedProcess[str]]


class RemoteCommandError(RuntimeError):
    def __init__(self, argv: Sequence[str], returncode: int, stdout: str, stderr: str) -> None:
        self.argv = list(argv)
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        detail = stderr.strip() or stdout.strip() or f"remote command exited with status {returncode}"
        super().__init__(detail)


class SshClient:
    def __init__(
        self,
        *,
        host: str,
        ssh_options: Sequence[str],
        ssh_bin: str = "ssh",
        runner: Runner = subprocess.run,
    ) -> None:
        self.host = host
        self.ssh_options = list(ssh_options)
        self.ssh_bin = ssh_bin
        self.runner = runner

    def run(
        self,
        remote_argv: Sequence[str],
        *,
        stdin: str | None = None,
        check: bool = True,
        stderr: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        argv = build_ssh_argv(
            ssh_options=self.ssh_options,
            host=self.host,
            remote_argv=remote_argv,
            ssh_bin=self.ssh_bin,
        )
        try:
            result = self.runner(
                argv,
                input=stdin,
                text=True,
                stdout=subprocess.PIPE,
                stderr=stderr,
            )
        except KeyboardInterrupt:
            raise
        if check and result.returncode != 0:
            raise RemoteCommandError(argv, result.returncode, result.stdout or "", result.stderr or "")
        return result
