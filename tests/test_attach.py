import os
import pty
import io
import unittest
from unittest.mock import patch

from sessh.attach import (
    attach_remote_transaction,
    attach_environment,
    force_tty_ssh_options,
    format_terminal_boundary,
    write_terminal_boundary_on_new_line,
)
from sessh.pty_relay import RelayResult


class AttachTests(unittest.TestCase):
    def test_force_tty_adds_double_t(self):
        self.assertEqual(
            force_tty_ssh_options(["-p", "2222"]),
            ["-p", "2222", "-o", "LogLevel=ERROR", "-t", "-t"],
        )

    def test_force_tty_completes_single_t(self):
        self.assertEqual(
            force_tty_ssh_options(["-t"]), ["-t", "-o", "LogLevel=ERROR", "-t"]
        )

    def test_force_tty_preserves_existing_double_t(self):
        self.assertEqual(
            force_tty_ssh_options(["-tt", "-p", "2222"]),
            ["-tt", "-p", "2222", "-o", "LogLevel=ERROR"],
        )

    def test_force_tty_preserves_explicit_log_level(self):
        self.assertEqual(
            force_tty_ssh_options(["-o", "LogLevel=DEBUG"]),
            ["-o", "LogLevel=DEBUG", "-t", "-t"],
        )

    def test_force_tty_rejects_disabled_tty(self):
        with self.assertRaisesRegex(ValueError, "remote TTY"):
            force_tty_ssh_options(["-T"])

    def test_attach_environment_supplies_usable_term(self):
        self.assertEqual(attach_environment({"TERM": "dumb"})["TERM"], "xterm-256color")

    def test_attach_environment_preserves_existing_term(self):
        self.assertEqual(
            attach_environment({"TERM": "screen-256color"})["TERM"], "screen-256color"
        )

    def test_attach_environment_uses_portable_term_for_new_terminal_names(self):
        self.assertEqual(
            attach_environment({"TERM": "xterm-ghostty"})["TERM"], "xterm-256color"
        )

    def test_detached_boundary_can_start_from_current_terminal_column(self):
        master, slave = pty.openpty()
        try:
            os.set_blocking(master, False)
            with os.fdopen(os.dup(slave), "w", encoding="utf-8") as stream:
                stream.write("partial")
                write_terminal_boundary_on_new_line(
                    stream, "sessh detached", resume_id="abc123"
                )

            output = _read_available(master)
            normalized = output.replace(b"\r", b"")
            self.assertEqual(normalized, b"partial\n--- sessh detached abc123 ---\n")
        finally:
            os.close(master)
            os.close(slave)

    def test_format_terminal_boundary(self):
        self.assertEqual(
            format_terminal_boundary("sessh exited", resume_id="abc123"),
            "--- sessh exited abc123 ---\n",
        )

    def test_auto_reattach_retries_after_learned_session_disconnect(self):
        stderr = TtyStringIO()
        built_resume_ids = []
        results = iter(
            [
                RelayResult(exit_status=255, resume_id="abc123"),
                RelayResult(exit_status=7, resume_id="abc123"),
            ]
        )

        def build_reattach(resume_id):
            built_resume_ids.append(resume_id)
            return ["attach", resume_id]

        with patch(
            "sessh.attach.run_pty_relay", side_effect=lambda *a, **kw: next(results)
        ):
            exit_status = attach_remote_transaction(
                FakeClient(),
                ["new"],
                stdin=TtyStringIO(),
                stderr=stderr,
                metadata_nonce="nonce",
                auto_reattach=True,
                reattach_remote_argv_builder=build_reattach,
                auto_reattach_initial_delay=0,
            )

        self.assertEqual(exit_status, 7)
        self.assertEqual(built_resume_ids, ["abc123"])
        self.assertIn("--- sessh detached abc123 ---", stderr.getvalue())
        self.assertIn("sessh: reattaching session abc123", stderr.getvalue())

    def test_auto_reattach_retries_after_remote_detached_event(self):
        stderr = TtyStringIO()
        built_resume_ids = []
        results = iter(
            [
                RelayResult(
                    exit_status=255,
                    resume_id="abc123",
                    final_event="detached",
                ),
                RelayResult(exit_status=0, resume_id="abc123"),
            ]
        )

        def build_reattach(resume_id):
            built_resume_ids.append(resume_id)
            return ["attach", resume_id]

        with patch(
            "sessh.attach.run_pty_relay", side_effect=lambda *a, **kw: next(results)
        ):
            exit_status = attach_remote_transaction(
                FakeClient(),
                ["new"],
                stdin=TtyStringIO(),
                stderr=stderr,
                metadata_nonce="nonce",
                auto_reattach=True,
                reattach_remote_argv_builder=build_reattach,
                auto_reattach_initial_delay=0,
            )

        self.assertEqual(exit_status, 0)
        self.assertEqual(built_resume_ids, ["abc123"])
        self.assertNotIn("--- sessh detached abc123 ---", stderr.getvalue())
        self.assertIn("sessh: reattaching session abc123", stderr.getvalue())

    def test_auto_reattach_waits_until_session_id_was_learned(self):
        with patch(
            "sessh.attach.run_pty_relay",
            return_value=RelayResult(exit_status=255),
        ) as run_pty_relay:
            exit_status = attach_remote_transaction(
                FakeClient(),
                ["new"],
                stdin=TtyStringIO(),
                stderr=TtyStringIO(),
                metadata_nonce="nonce",
                auto_reattach=True,
                reattach_remote_argv_builder=lambda resume_id: ["attach", resume_id],
                auto_reattach_initial_delay=0,
            )

        self.assertEqual(exit_status, 255)
        self.assertEqual(run_pty_relay.call_count, 1)

    def test_auto_reattach_does_not_retry_user_requested_disconnect(self):
        with patch(
            "sessh.attach.run_pty_relay",
            return_value=RelayResult(
                exit_status=255,
                resume_id="abc123",
                user_requested_disconnect=True,
            ),
        ) as run_pty_relay:
            exit_status = attach_remote_transaction(
                FakeClient(),
                ["new"],
                stdin=TtyStringIO(),
                stderr=TtyStringIO(),
                resume_command="sessh example.com --attach abc123",
                resume_id="abc123",
                metadata_nonce="nonce",
                auto_reattach=True,
                reattach_remote_argv_builder=lambda resume_id: ["attach", resume_id],
                auto_reattach_initial_delay=0,
            )

        self.assertEqual(exit_status, 255)
        self.assertEqual(run_pty_relay.call_count, 1)

    def test_manual_resume_message_is_not_duplicated_after_remote_detached_event(self):
        stderr = TtyStringIO()
        with patch(
            "sessh.attach.run_pty_relay",
            return_value=RelayResult(
                exit_status=255,
                resume_id="abc123",
                final_event="detached",
            ),
        ) as run_pty_relay:
            exit_status = attach_remote_transaction(
                FakeClient(),
                ["new"],
                stdin=TtyStringIO(),
                stderr=stderr,
                resume_command="sessh example.com --attach abc123",
                resume_id="abc123",
                metadata_nonce="nonce",
            )

        self.assertEqual(exit_status, 255)
        self.assertEqual(run_pty_relay.call_count, 1)
        self.assertNotIn("To attach to this session", stderr.getvalue())

    def test_auto_reattach_does_not_retry_remote_exit_255(self):
        with patch(
            "sessh.attach.run_pty_relay",
            return_value=RelayResult(
                exit_status=255,
                resume_id="abc123",
                final_event="exited",
                remote_exit_status=255,
            ),
        ) as run_pty_relay:
            exit_status = attach_remote_transaction(
                FakeClient(),
                ["new"],
                stdin=TtyStringIO(),
                stderr=TtyStringIO(),
                metadata_nonce="nonce",
                auto_reattach=True,
                reattach_remote_argv_builder=lambda resume_id: ["attach", resume_id],
                auto_reattach_initial_delay=0,
            )

        self.assertEqual(exit_status, 255)
        self.assertEqual(run_pty_relay.call_count, 1)

    def test_auto_reattach_retries_exited_event_without_remote_status(self):
        built_resume_ids = []
        results = iter(
            [
                RelayResult(
                    exit_status=255,
                    resume_id="abc123",
                    final_event="exited",
                ),
                RelayResult(exit_status=0, resume_id="abc123"),
            ]
        )

        def build_reattach(resume_id):
            built_resume_ids.append(resume_id)
            return ["attach", resume_id]

        with patch(
            "sessh.attach.run_pty_relay", side_effect=lambda *a, **kw: next(results)
        ):
            exit_status = attach_remote_transaction(
                FakeClient(),
                ["new"],
                stdin=TtyStringIO(),
                stderr=TtyStringIO(),
                metadata_nonce="nonce",
                auto_reattach=True,
                reattach_remote_argv_builder=build_reattach,
                auto_reattach_initial_delay=0,
            )

        self.assertEqual(exit_status, 0)
        self.assertEqual(built_resume_ids, ["abc123"])


class TtyStringIO(io.StringIO):
    def isatty(self):
        return True


class FakeClient:
    host = "example.com"
    ssh_options = []
    ssh_bin = "ssh"


def _read_available(fd):
    chunks = []
    while True:
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            break
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


if __name__ == "__main__":
    unittest.main()
