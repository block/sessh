import io
import unittest

from sessh.diagnostics import ProgressReporter


class NonTtyStringIO(io.StringIO):
    def isatty(self):
        return False


class TtyStringIO(io.StringIO):
    def isatty(self):
        return True


class DiagnosticsTests(unittest.TestCase):
    def test_non_verbose_progress_updates_one_dynamic_line_on_tty(self):
        stream = TtyStringIO()
        progress = ProgressReporter(stream=stream)

        progress.update("connecting")
        progress.update("bootstrapping")
        progress.clear()

        self.assertEqual(
            stream.getvalue(),
            "\r\033[Ksessh: connecting\r\033[Ksessh: bootstrapping\r\033[K",
        )

    def test_verbose_progress_writes_lines(self):
        stream = TtyStringIO()
        progress = ProgressReporter(stream=stream, verbose=True)

        progress.update("connecting")
        progress.update("bootstrapping")
        progress.clear()

        self.assertEqual(stream.getvalue(), "sessh: connecting\nsessh: bootstrapping\n")

    def test_non_tty_progress_writes_lines(self):
        stream = NonTtyStringIO()
        progress = ProgressReporter(stream=stream)

        progress.update("connecting")
        progress.update("bootstrapping")
        progress.clear()

        self.assertEqual(stream.getvalue(), "sessh: connecting\nsessh: bootstrapping\n")

    def test_quiet_progress_is_silent(self):
        stream = TtyStringIO()
        progress = ProgressReporter(stream=stream, quiet=True)

        progress.update("connecting")
        progress.clear()

        self.assertEqual(stream.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
