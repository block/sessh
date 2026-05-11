import io
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from sessh.cli import execute, format_session_list, main, parse_args
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

    def test_session_commands_require_ttys_before_config_or_ssh(self):
        cases = {
            "new": ["example.com"],
            "attach": ["example.com", "--attach", "k7m4q2"],
            "run": ["example.com", "true"],
        }
        for command, argv in cases.items():
            for stream_name in ("stdin", "stdout", "stderr"):
                with self.subTest(command=command, stream=stream_name):
                    streams = {
                        "stdin": TtyStringIO(),
                        "stdout": TtyStringIO(),
                        "stderr": TtyStringIO(),
                    }
                    streams[stream_name] = NonTtyStringIO()

                    with self.assertRaisesRegex(RuntimeError, stream_name):
                        execute(
                            parse_args(argv),
                            **streams,
                            config_loader=self._unexpected_config_loader,
                            client_factory=UnexpectedClient,
                        )

    def test_list_does_not_require_ttys(self):
        stdout = NonTtyStringIO()

        exit_status = execute(
            parse_args(["example.com", "--list"]),
            stdin=NonTtyStringIO(),
            stdout=stdout,
            stderr=NonTtyStringIO(),
            config_loader=lambda **kwargs: Config(
                shell="bash",
                history_limit=50,
                remote_init="",
                remote_rc="remote-rc",
            ),
            client_factory=FakeListClient,
        )

        self.assertEqual(exit_status, 0)
        self.assertEqual(
            stdout.getvalue(), "ID\tATTACHED\tCREATED\tCWD\tCOMMAND\tTITLE\n"
        )

    def test_main_reports_non_tty_error(self):
        stderr = NonTtyStringIO()

        with (
            patch("sys.stdin", NonTtyStringIO()),
            patch("sys.stdout", NonTtyStringIO()),
            patch("sys.stderr", stderr),
        ):
            exit_status = main(["example.com"])

        self.assertEqual(exit_status, 1)
        self.assertIn("sessh: sessh sessions require", stderr.getvalue())
        self.assertIn("stdin, stdout, and stderr", stderr.getvalue())

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

    def test_auto_reattach_defaults_from_config(self):
        captured_kwargs = self._execute_new_and_capture_attach_kwargs(
            parse_args(["example.com"]),
            Config(
                shell="bash",
                history_limit=50,
                auto_reattach=True,
                remote_rc="remote-rc",
            ),
        )

        self.assertTrue(captured_kwargs["auto_reattach"])
        self.assertIsNotNone(captured_kwargs["reattach_remote_argv_builder"])

    def test_no_auto_reattach_suppresses_config_default(self):
        captured_kwargs = self._execute_new_and_capture_attach_kwargs(
            parse_args(["--no-auto-reattach", "example.com"]),
            Config(
                shell="bash",
                history_limit=50,
                auto_reattach=True,
                remote_rc="remote-rc",
            ),
        )

        self.assertFalse(captured_kwargs["auto_reattach"])

    def test_auto_reattach_cli_override_enables_config_default(self):
        captured_kwargs = self._execute_new_and_capture_attach_kwargs(
            parse_args(["--auto-reattach", "example.com"]),
            Config(
                shell="bash",
                history_limit=50,
                auto_reattach=False,
                remote_rc="remote-rc",
            ),
        )

        self.assertTrue(captured_kwargs["auto_reattach"])

    def test_scrollback_defaults_from_config(self):
        remote_argv = self._execute_new_and_capture_remote_argv(
            parse_args(["example.com"]),
            Config(
                shell="bash",
                history_limit=50,
                scrollback=25,
                remote_rc="remote-rc",
            ),
        )

        self.assertEqual(remote_argv[12], "25")

    def test_scrollback_cli_override_takes_priority_over_config(self):
        remote_argv = self._execute_new_and_capture_remote_argv(
            parse_args(["--scrollback", "5", "example.com"]),
            Config(
                shell="bash",
                history_limit=50,
                scrollback=25,
                remote_rc="remote-rc",
            ),
        )

        self.assertEqual(remote_argv[12], "5")

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

    def _execute_new_and_capture_remote_argv(self, args, config):
        captured_remote_argv = None

        def fake_attach_remote_transaction(client, remote_argv, **kwargs):  # noqa: ARG001
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
                config_loader=lambda **kwargs: config,
                client_factory=FakeClient,
                id_generator=lambda existing_ids: "abc123",
            )

        self.assertEqual(exit_status, 0)
        self.assertIsNotNone(captured_remote_argv)
        return captured_remote_argv

    def _execute_new_and_capture_attach_kwargs(self, args, config):
        captured_kwargs = None

        def fake_attach_remote_transaction(client, remote_argv, **kwargs):  # noqa: ARG001
            nonlocal captured_kwargs
            captured_kwargs = dict(kwargs)
            return 0

        with patch(
            "sessh.cli.attach_remote_transaction", fake_attach_remote_transaction
        ):
            exit_status = execute(
                args,
                stdin=TtyStringIO(),
                stdout=TtyStringIO(),
                stderr=TtyStringIO(),
                config_loader=lambda **kwargs: config,
                client_factory=FakeClient,
                id_generator=lambda existing_ids: "abc123",
            )

        self.assertEqual(exit_status, 0)
        self.assertIsNotNone(captured_kwargs)
        return captured_kwargs

    def _unexpected_config_loader(self, **kwargs):
        self.fail("config should not be loaded before TTY validation")


class TtyStringIO(io.StringIO):
    def isatty(self):
        return True


class NonTtyStringIO(io.StringIO):
    def isatty(self):
        return False


class FakeClient:
    ssh_bin = "ssh"

    def __init__(self, *, host, ssh_options):
        self.host = host
        self.ssh_options = ssh_options


class FakeListClient(FakeClient):
    def run(self, remote_argv, *, check):  # noqa: ARG002
        return SimpleNamespace(stdout="")


class UnexpectedClient(FakeClient):
    def __init__(self, *, host, ssh_options):  # noqa: ARG002
        raise AssertionError("ssh client should not be created before TTY validation")


if __name__ == "__main__":
    unittest.main()
