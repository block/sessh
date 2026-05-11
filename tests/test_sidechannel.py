import unittest

from sessh.sidechannel import SideChannelEvent, SideChannelParser, format_sidechannel_frame


class SideChannelTests(unittest.TestCase):
    def test_strips_frames_and_preserves_visible_bytes_exactly(self):
        parser = SideChannelParser("abc123")
        stream = (
            b"before\n"
            + format_sidechannel_frame("abc123", "created", "k7m4q2")
            + b"\x00binary\xffafter\n"
        )

        visible, events = parser.feed(stream)

        self.assertEqual(visible, b"before\n\x00binary\xffafter\n")
        self.assertEqual(events, [SideChannelEvent("created", ("k7m4q2",))])
        self.assertEqual(parser.flush(), b"")

    def test_strips_frame_split_across_reads(self):
        parser = SideChannelParser("abc123")
        frame = format_sidechannel_frame("abc123", "exited", "k7m4q2", "255")

        first_visible, first_events = parser.feed(b"out" + frame[:8])
        second_visible, second_events = parser.feed(frame[8:] + b"tail")
        flushed = parser.flush()

        self.assertEqual(first_visible, b"out")
        self.assertEqual(first_events, [])
        self.assertEqual(second_visible, b"tail")
        self.assertEqual(second_events, [SideChannelEvent("exited", ("k7m4q2", "255"))])
        self.assertEqual(flushed, b"")

    def test_preserves_other_bytes_that_look_similar(self):
        parser = SideChannelParser("expected")
        wrong_nonce = format_sidechannel_frame("other", "created", "k7m4q2")

        visible, events = parser.feed(b"left" + wrong_nonce + b"right")

        self.assertEqual(visible + parser.flush(), b"left" + wrong_nonce + b"right")
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
