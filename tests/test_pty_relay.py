import unittest

from sessh.pty_relay import SshEscapeDisconnectDetector


class SshEscapeDisconnectDetectorTests(unittest.TestCase):
    def test_detects_disconnect_escape_at_line_start(self):
        detector = SshEscapeDisconnectDetector()

        self.assertTrue(detector.feed(b"\r~."))

    def test_detects_disconnect_escape_split_across_reads(self):
        detector = SshEscapeDisconnectDetector()

        self.assertFalse(detector.feed(b"\n~"))
        self.assertTrue(detector.feed(b"."))

    def test_ignores_disconnect_escape_after_other_input(self):
        detector = SshEscapeDisconnectDetector()

        self.assertFalse(detector.feed(b"echo ~."))

    def test_ignores_other_ssh_escapes(self):
        detector = SshEscapeDisconnectDetector()

        self.assertFalse(detector.feed(b"\r~~"))


if __name__ == "__main__":
    unittest.main()
