import io
import os
import pty
import unittest
from unittest.mock import patch

from sessh.cli import execute, format_session_list, parse_args
from sessh.config import Config
from sessh.sessions import SessionInfo


class CliExecuteTests(unittest.TestCase):
    def test_format_session_list(self):
        self.assertEqual(
            format_session_list(
                [
                    SessionInfo("a1b2c3", 0, 10, "/home/alice", "vim", "code"),
                    SessionInfo("d4e5f6", 2, 20, "/var/log", "less", "logs"),
                ]
            ),
            "ID\tATTACHED\tCREATED\tCWD\tCOMMAND\tTITLE\n"
            "a1b2c3\tno\t1970-01-01T00:00:10Z\t/home/alice\tvim\tcode\n"
            "d4e5f6\tyes\t1970-01-01T00:00:20Z\t/var/log\tless\tlogs\n",
        )

    def test_preserve_args_is_rejected_for_non_run_commands(self):
        with self.assertRaises(SystemExit):
            parse_args(["--preserve-args", "example.com", "--list"])

    def test_run_requires_stdout_and_stderr_ttys(self):
        args = parse_args(["example.com", "true"])
        master_fd, slave_fd = pty.openpty()
        os.close(master_fd)

        try:
            with os.fdopen(slave_fd, "w", encoding="utf-8") as stderr:
                with self.assertRaisesRegex(RuntimeError, "stdout"):
                    execute(
                        args,
                        stdout=io.StringIO(),
                        stderr=stderr,
                        config_loader=lambda **kwargs: Config(
                            shell="bash", history_limit=50
                        ),
                    )
        finally:
            try:
                os.close(slave_fd)
            except OSError:
                pass

    def test_run_uses_evaluated_args_by_default(self):
        remote_argv = self._execute_run_and_capture_remote_argv(
            parse_args(["example.com", "printf", "$HOME"])
        )

        self.assertEqual(remote_argv[12], "1")
        self.assertEqual(remote_argv[13], "printf")
        self.assertEqual(remote_argv[14:], ["printf", "$HOME"])

    def test_preserve_args_disables_run_arg_evaluation(self):
        remote_argv = self._execute_run_and_capture_remote_argv(
            parse_args(["example.com", "--preserve-args", "printf", "$HOME"])
        )

        self.assertEqual(remote_argv[12], "0")
        self.assertEqual(remote_argv[13], "printf")
        self.assertEqual(remote_argv[14:], ["printf", "$HOME"])

    def _execute_run_and_capture_remote_argv(self, args):
        captured_remote_argv = None

        def fake_attach_remote_transaction(client, remote_argv, **kwargs):
            nonlocal captured_remote_argv
            captured_remote_argv = list(remote_argv)
            return 0

        with patch(
            "sessh.cli.attach_remote_transaction", fake_attach_remote_transaction
        ):
            exit_status = execute(
                args,
                stdin=TtyStringIO(),
                stdout=TtyStringIO(),
                stderr=TtyStringIO(),
                config_loader=lambda **kwargs: Config(
                    shell="bash",
                    history_limit=50,
                    remote_init="",
                    remote_rc="remote-rc",
                ),
                client_factory=FakeClient,
                id_generator=lambda existing_ids: "abc123",
            )

        self.assertEqual(exit_status, 0)
        self.assertIsNotNone(captured_remote_argv)
        return captured_remote_argv


class TtyStringIO(io.StringIO):
    def isatty(self):
        return True


class FakeClient:
    ssh_bin = "ssh"

    def __init__(self, *, host, ssh_options):
        self.host = host
        self.ssh_options = ssh_options


if __name__ == "__main__":
    unittest.main()
