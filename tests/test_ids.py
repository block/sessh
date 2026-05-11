import unittest

from sessh.ids import generate_resume_id, is_valid_resume_id


class IdTests(unittest.TestCase):
    def test_generated_id_is_short_and_shell_safe(self):
        resume_id = generate_resume_id(existing=set())

        self.assertEqual(len(resume_id), 6)
        self.assertTrue(is_valid_resume_id(resume_id))

    def test_generated_id_avoids_existing_ids(self):
        first = generate_resume_id(existing=set())
        second = generate_resume_id(existing={first})

        self.assertNotEqual(first, second)
        self.assertTrue(is_valid_resume_id(second))

    def test_validates_resume_ids(self):
        self.assertTrue(is_valid_resume_id("k7m4q2"))
        self.assertTrue(is_valid_resume_id("f83ad0"))
        self.assertFalse(is_valid_resume_id(""))
        self.assertFalse(is_valid_resume_id("abc_def"))
        self.assertFalse(is_valid_resume_id("ABC123"))


if __name__ == "__main__":
    unittest.main()

