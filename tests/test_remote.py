import unittest

from sessh.remote import RemoteCommandError, SshClient


class RemoteTests(unittest.TestCase):
    def test_ssh_client_raises_on_failure_when_checking(self):
        client = SshClient(host="example.com", ssh_options=[], ssh_bin="/usr/bin/false")

        with self.assertRaises(RemoteCommandError) as ctx:
            client.run(["true"])

        self.assertNotEqual(ctx.exception.returncode, 0)
        self.assertEqual(ctx.exception.stdout, "")


if __name__ == "__main__":
    unittest.main()
