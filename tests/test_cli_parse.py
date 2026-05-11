import unittest

from sessh.cli import parse_args


class CliParseTests(unittest.TestCase):
    def test_new_session(self):
        args = parse_args(["-p", "2222", "user@example.com"])

        self.assertEqual(args.ssh_options, ["-p", "2222"])
        self.assertEqual(args.host, "user@example.com")
        self.assertEqual(args.command, "new")

    def test_common_ssh_flags_pass_through(self):
        args = parse_args(["-4", "-6", "-A", "-a", "-C", "-g", "-K", "-k", "-X", "-x", "-Y", "example.com"])

        self.assertEqual(args.ssh_options, ["-4", "-6", "-A", "-a", "-C", "-g", "-K", "-k", "-X", "-x", "-Y"])
        self.assertEqual(args.host, "example.com")

    def test_common_ssh_options_with_separate_values_pass_through(self):
        args = parse_args(
            [
                "-B",
                "en0",
                "-b",
                "192.0.2.10",
                "-c",
                "aes128-ctr",
                "-D",
                "1080",
                "-E",
                "ssh.log",
                "-e",
                "none",
                "-F",
                "ssh_config",
                "-I",
                "pkcs11.so",
                "-i",
                "id_ed25519",
                "-J",
                "jump.example.com",
                "-L",
                "8080:localhost:80",
                "-l",
                "alice",
                "-m",
                "hmac-sha2-256",
                "-o",
                "StrictHostKeyChecking=no",
                "-P",
                "tag",
                "-p",
                "2222",
                "-R",
                "9090:localhost:90",
                "example.com",
            ]
        )

        self.assertEqual(
            args.ssh_options,
            [
                "-B",
                "en0",
                "-b",
                "192.0.2.10",
                "-c",
                "aes128-ctr",
                "-D",
                "1080",
                "-E",
                "ssh.log",
                "-e",
                "none",
                "-F",
                "ssh_config",
                "-I",
                "pkcs11.so",
                "-i",
                "id_ed25519",
                "-J",
                "jump.example.com",
                "-L",
                "8080:localhost:80",
                "-l",
                "alice",
                "-m",
                "hmac-sha2-256",
                "-o",
                "StrictHostKeyChecking=no",
                "-P",
                "tag",
                "-p",
                "2222",
                "-R",
                "9090:localhost:90",
            ],
        )
        self.assertEqual(args.host, "example.com")

    def test_ssh_options_with_attached_values_pass_through(self):
        args = parse_args(
            [
                "-Ben0",
                "-b192.0.2.10",
                "-caes128-ctr",
                "-D1080",
                "-Essh.log",
                "-enone",
                "-Fssh_config",
                "-Ipkcs11.so",
                "-iid_ed25519",
                "-Jjump.example.com",
                "-L8080:localhost:80",
                "-lalice",
                "-mhmac-sha2-256",
                "-oStrictHostKeyChecking=no",
                "-Ptag",
                "-p2222",
                "-R9090:localhost:90",
                "example.com",
            ]
        )

        self.assertEqual(
            args.ssh_options,
            [
                "-B",
                "en0",
                "-b",
                "192.0.2.10",
                "-c",
                "aes128-ctr",
                "-D",
                "1080",
                "-E",
                "ssh.log",
                "-e",
                "none",
                "-F",
                "ssh_config",
                "-I",
                "pkcs11.so",
                "-i",
                "id_ed25519",
                "-J",
                "jump.example.com",
                "-L",
                "8080:localhost:80",
                "-l",
                "alice",
                "-m",
                "hmac-sha2-256",
                "-o",
                "StrictHostKeyChecking=no",
                "-P",
                "tag",
                "-p",
                "2222",
                "-R",
                "9090:localhost:90",
            ],
        )
        self.assertEqual(args.host, "example.com")

    def test_incompatible_ssh_options_are_rejected(self):
        for option in ["-T", "-n", "-f", "-N", "-W", "-s"]:
            with self.subTest(option=option):
                with self.assertRaises(SystemExit):
                    parse_args([option, "example.com"])

    def test_attach_picker(self):
        args = parse_args(["example.com", "attach"])

        self.assertEqual(args.command, "attach")
        self.assertIsNone(args.resume_id)

    def test_attach_id(self):
        args = parse_args(["example.com", "attach", "k7m4q2"])

        self.assertEqual(args.command, "attach")
        self.assertEqual(args.resume_id, "k7m4q2")

    def test_resume_is_attach_synonym(self):
        args = parse_args(["example.com", "resume", "k7m4q2"])

        self.assertEqual(args.command, "attach")
        self.assertEqual(args.resume_id, "k7m4q2")

    def test_resume_picker_is_attach_picker_synonym(self):
        args = parse_args(["example.com", "resume"])

        self.assertEqual(args.command, "attach")
        self.assertIsNone(args.resume_id)

    def test_list(self):
        args = parse_args(["example.com", "list"])

        self.assertEqual(args.command, "list")

    def test_run_keeps_all_remaining_args(self):
        args = parse_args(["--eval-args", "-t", "example.com", "run", "--flag", "hello world"])

        self.assertTrue(args.eval_args)
        self.assertEqual(args.ssh_options, ["-t"])
        self.assertEqual(args.command, "run")
        self.assertEqual(args.remote_argv, ["--flag", "hello world"])

    def test_verbose_option_before_host(self):
        args = parse_args(["--verbose", "-p", "2222", "example.com"])

        self.assertTrue(args.verbose)
        self.assertFalse(args.quiet)
        self.assertEqual(args.ssh_options, ["-p", "2222"])
        self.assertEqual(args.host, "example.com")

    def test_quiet_option_before_host(self):
        args = parse_args(["--quiet", "-p", "2222", "example.com"])

        self.assertTrue(args.quiet)
        self.assertFalse(args.verbose)
        self.assertEqual(args.ssh_options, ["-p", "2222"])
        self.assertEqual(args.host, "example.com")

    def test_verbose_and_quiet_conflict(self):
        with self.assertRaises(SystemExit):
            parse_args(["--verbose", "--quiet", "example.com"])

    def test_verbose_after_run_is_remote_argv(self):
        args = parse_args(["example.com", "run", "--verbose", "echo"])

        self.assertFalse(args.verbose)
        self.assertEqual(args.remote_argv, ["--verbose", "echo"])

    def test_options_after_host_are_not_parsed_as_ssh_options(self):
        with self.assertRaises(SystemExit):
            parse_args(["example.com", "-p", "2222"])

    def test_eval_args_after_run_is_remote_argv(self):
        args = parse_args(["example.com", "run", "--eval-args", "echo $HOME"])

        self.assertFalse(args.eval_args)
        self.assertEqual(args.remote_argv, ["--eval-args", "echo $HOME"])


if __name__ == "__main__":
    unittest.main()
