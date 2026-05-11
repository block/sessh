import os
import pty
import unittest

from sessh.attach import (
    attach_environment,
    force_tty_ssh_options,
    format_terminal_boundary,
    write_terminal_boundary_on_new_line,
)


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
