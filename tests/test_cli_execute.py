import io
import os
import pty
import unittest

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

    def test_eval_args_is_rejected_for_non_run_commands(self):
        with self.assertRaises(SystemExit):
            parse_args(["--eval-args", "example.com", "list"])

    def test_run_requires_stdout_and_stderr_ttys(self):
        args = parse_args(["example.com", "run", "true"])
        master_fd, slave_fd = pty.openpty()
        os.close(master_fd)

        try:
            with os.fdopen(slave_fd, "w", encoding="utf-8") as stderr:
                with self.assertRaisesRegex(RuntimeError, "stdout"):
                    execute(
                        args,
                        stdout=io.StringIO(),
                        stderr=stderr,
                        config_loader=lambda **kwargs: Config(shell="bash", history_limit=50),
                    )
        finally:
            try:
                os.close(slave_fd)
            except OSError:
                pass


if __name__ == "__main__":
    unittest.main()
