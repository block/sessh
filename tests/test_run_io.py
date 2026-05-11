import unittest

from sessh.run_io import RunTtyError, validate_run_tty_state


class RunIoTests(unittest.TestCase):
    def test_accepts_tty_stdout_and_stderr(self):
        validate_run_tty_state(stdout_is_tty=True, stderr_is_tty=True)

    def test_rejects_redirected_stdout(self):
        with self.assertRaisesRegex(RunTtyError, "stdout"):
            validate_run_tty_state(stdout_is_tty=False, stderr_is_tty=True)

    def test_rejects_redirected_stderr(self):
        with self.assertRaisesRegex(RunTtyError, "stderr"):
            validate_run_tty_state(stdout_is_tty=True, stderr_is_tty=False)

    def test_rejects_both_redirected(self):
        with self.assertRaisesRegex(RunTtyError, "stdout and stderr"):
            validate_run_tty_state(stdout_is_tty=False, stderr_is_tty=False)


if __name__ == "__main__":
    unittest.main()
