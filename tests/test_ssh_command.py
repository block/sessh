import json
import subprocess
import unittest

from sessh.ssh_command import build_ssh_argv, shell_quote_command


class SshCommandTests(unittest.TestCase):
    def test_remote_argv_is_quoted_for_one_shell_evaluation(self):
        argv = build_ssh_argv(
            ssh_options=["-p", "2222", "-tt"],
            host="user@example.com",
            remote_argv=[
                "python3",
                "-c",
                "import json, sys; print(json.dumps(sys.argv[1:]))",
                "hello world",
                "$HOME",
                "*.log",
                "semi;colon",
            ],
        )

        result = subprocess.run(
            ["sh", "-c", argv[-1]],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

        self.assertEqual(
            json.loads(result.stdout), ["hello world", "$HOME", "*.log", "semi;colon"]
        )

    def test_rejects_empty_remote_argv(self):
        with self.assertRaises(ValueError):
            build_ssh_argv(ssh_options=[], host="example.com", remote_argv=[])

    def test_rejects_remote_command_above_size_budget(self):
        with self.assertRaisesRegex(ValueError, "remote command is too large"):
            build_ssh_argv(
                ssh_options=[],
                host="example.com",
                remote_argv=["printf", "x" * 100_000],
            )

    def test_shell_quote_command_round_trips_metacharacters(self):
        command = shell_quote_command(
            [
                "python3",
                "-c",
                "import json, sys; print(json.dumps(sys.argv[1:]))",
                "hello world",
                "$HOME",
                "*.log",
                "semi;colon",
            ]
        )

        result = subprocess.run(
            ["sh", "-c", command],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

        self.assertEqual(
            json.loads(result.stdout), ["hello world", "$HOME", "*.log", "semi;colon"]
        )


if __name__ == "__main__":
    unittest.main()
