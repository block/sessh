import unittest

from sessh.run_io import TtyError, validate_session_tty_state


class RunIoTests(unittest.TestCase):
    def test_accepts_tty_streams(self):
        validate_session_tty_state(
            stdin_is_tty=True, stdout_is_tty=True, stderr_is_tty=True
        )

    def test_rejects_redirected_stdin(self):
        with self.assertRaisesRegex(TtyError, "stdin"):
            validate_session_tty_state(
                stdin_is_tty=False, stdout_is_tty=True, stderr_is_tty=True
            )

    def test_rejects_redirected_stdout(self):
        with self.assertRaisesRegex(TtyError, "stdout"):
            validate_session_tty_state(
                stdin_is_tty=True, stdout_is_tty=False, stderr_is_tty=True
            )

    def test_rejects_redirected_stderr(self):
        with self.assertRaisesRegex(TtyError, "stderr"):
            validate_session_tty_state(
                stdin_is_tty=True, stdout_is_tty=True, stderr_is_tty=False
            )

    def test_rejects_all_redirected(self):
        with self.assertRaisesRegex(TtyError, "stdin, stdout, and stderr"):
            validate_session_tty_state(
                stdin_is_tty=False, stdout_is_tty=False, stderr_is_tty=False
            )


if __name__ == "__main__":
    unittest.main()
