import unittest

from sessh.cli import parse_args


class CliParseTests(unittest.TestCase):
    def test_new_session(self):
        args = parse_args(["-p", "2222", "user@example.com"])

        self.assertEqual(args.ssh_options, ["-p", "2222"])
        self.assertEqual(args.host, "user@example.com")
        self.assertEqual(args.command, "new")

    def test_common_ssh_flags_pass_through(self):
        args = parse_args(
            [
                "-4",
                "-6",
                "-A",
                "-a",
                "-C",
                "-g",
                "-K",
                "-k",
                "-X",
                "-x",
                "-Y",
                "example.com",
            ]
        )

        self.assertEqual(
            args.ssh_options,
            ["-4", "-6", "-A", "-a", "-C", "-g", "-K", "-k", "-X", "-x", "-Y"],
        )
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
        cases = {
            "-T": "disables remote TTY allocation",
            "-n": "redirects stdin",
            "-f": "backgrounds ssh",
            "-N": "prevents ssh from running a remote command",
            "-W": "forwards stdio",
            "-s": "requests an ssh subsystem",
            "-G": "prints resolved ssh configuration",
            "-O": "controls an existing ssh multiplex master",
            "-Q": "queries ssh capabilities",
        }
        for option, reason in cases.items():
            with self.subTest(option=option):
                with self.assertRaises(SystemExit) as raised:
                    parse_args([option, "example.com"])

                self.assertIn(
                    f"ssh option {option} is not compatible with sessh",
                    str(raised.exception),
                )
                self.assertIn(reason, str(raised.exception))

    def test_incompatible_attached_ssh_option_is_rejected_with_reason(self):
        with self.assertRaises(SystemExit) as raised:
            parse_args(["-Wexample.com:22", "example.com"])

        self.assertIn(
            "ssh option -Wexample.com:22 is not compatible with sessh",
            str(raised.exception),
        )
        self.assertIn("forwards stdio", str(raised.exception))

    def test_incompatible_ssh_config_options_are_rejected(self):
        cases = {
            "ForkAfterAuthentication=yes": "backgrounds ssh",
            "RemoteCommand=echo hello": "must supply its own remote tmux bootstrap command",
            "RequestTTY=no": "disables remote TTY allocation",
            "SessionType=none": "prevents sessh from running its remote tmux bootstrap command",
            "StdinNull=yes": "prevents ssh from reading stdin",
        }
        for option, reason in cases.items():
            with self.subTest(option=option):
                with self.assertRaises(SystemExit) as raised:
                    parse_args(["-o", option, "example.com"])

                self.assertIn("ssh option -o", str(raised.exception))
                self.assertIn("is not compatible with sessh", str(raised.exception))
                self.assertIn(reason, str(raised.exception))

    def test_attached_incompatible_ssh_config_option_is_rejected(self):
        with self.assertRaises(SystemExit) as raised:
            parse_args(["-oRequestTTY=no", "example.com"])

        self.assertIn(
            "ssh option -o RequestTTY=no is not compatible with sessh",
            str(raised.exception),
        )

    def test_attach_picker(self):
        args = parse_args(["example.com", "--attach"])

        self.assertEqual(args.command, "attach")
        self.assertIsNone(args.resume_id)

    def test_attach_id(self):
        args = parse_args(["example.com", "--attach", "k7m4q2"])

        self.assertEqual(args.command, "attach")
        self.assertEqual(args.resume_id, "k7m4q2")

    def test_attach_id_with_equals(self):
        args = parse_args(["example.com", "--attach=k7m4q2"])

        self.assertEqual(args.command, "attach")
        self.assertEqual(args.resume_id, "k7m4q2")

    def test_attach_id_with_equals_before_host(self):
        args = parse_args(["--attach=k7m4q2", "example.com"])

        self.assertEqual(args.command, "attach")
        self.assertEqual(args.resume_id, "k7m4q2")

    def test_list(self):
        args = parse_args(["example.com", "--list"])

        self.assertEqual(args.command, "list")

    def test_list_before_host(self):
        args = parse_args(["--list", "example.com"])

        self.assertEqual(args.command, "list")

    def test_remote_command_uses_evaluated_args_by_default(self):
        args = parse_args(
            ["-t", "example.com", "printf", "%s\\n", "hello world", "$HOME"]
        )

        self.assertFalse(args.preserve_args)
        self.assertEqual(args.ssh_options, ["-t"])
        self.assertEqual(args.command, "run")
        self.assertEqual(args.remote_argv, ["printf", "%s\\n", "hello world", "$HOME"])

    def test_preserve_args_is_valid_with_remote_command(self):
        args = parse_args(
            ["example.com", "--preserve-args", "printf", "%s\\n", "hello world"]
        )

        self.assertTrue(args.preserve_args)
        self.assertEqual(args.command, "run")
        self.assertEqual(args.remote_argv, ["printf", "%s\\n", "hello world"])

    def test_double_dash_allows_remote_command_starting_with_long_option(self):
        args = parse_args(["example.com", "--", "--flag", "hello world"])

        self.assertEqual(args.command, "run")
        self.assertEqual(args.remote_argv, ["--flag", "hello world"])

    def test_command_words_after_host_are_remote_argv(self):
        args = parse_args(["example.com", "list"])

        self.assertEqual(args.command, "run")
        self.assertEqual(args.remote_argv, ["list"])

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

    def test_auto_reattach_before_host(self):
        args = parse_args(["--auto-reattach", "example.com"])

        self.assertTrue(args.auto_reattach)
        self.assertEqual(args.command, "new")

    def test_scrollback_before_host(self):
        args = parse_args(["--scrollback", "50", "example.com"])

        self.assertEqual(args.scrollback, 50)
        self.assertEqual(args.command, "new")

    def test_scrollback_with_equals_before_host(self):
        args = parse_args(["--scrollback=50", "example.com"])

        self.assertEqual(args.scrollback, 50)
        self.assertEqual(args.command, "new")

    def test_no_auto_reattach_before_host(self):
        args = parse_args(["--no-auto-reattach", "example.com"])

        self.assertFalse(args.auto_reattach)
        self.assertEqual(args.command, "new")

    def test_auto_reattach_after_host(self):
        args = parse_args(["example.com", "--auto-reattach", "--attach", "k7m4q2"])

        self.assertTrue(args.auto_reattach)
        self.assertEqual(args.command, "attach")
        self.assertEqual(args.resume_id, "k7m4q2")

    def test_scrollback_after_host(self):
        args = parse_args(["example.com", "--scrollback", "50", "--attach", "k7m4q2"])

        self.assertEqual(args.scrollback, 50)
        self.assertEqual(args.command, "attach")
        self.assertEqual(args.resume_id, "k7m4q2")

    def test_invalid_scrollback_is_rejected(self):
        cases = ["wat", "-1"]
        for value in cases:
            with self.subTest(value=value):
                with self.assertRaises(SystemExit):
                    parse_args(["--scrollback", value, "example.com"])

    def test_no_auto_reattach_overrides_auto_reattach(self):
        args = parse_args(["--auto-reattach", "example.com", "--no-auto-reattach"])

        self.assertFalse(args.auto_reattach)

    def test_unknown_long_option_after_host_requires_double_dash(self):
        with self.assertRaises(SystemExit) as raised:
            parse_args(["example.com", "--verbose", "echo"])

        self.assertIn("unknown option after HOST: --verbose", str(raised.exception))
        self.assertIn(
            "use -- before remote commands that start with --", str(raised.exception)
        )

    def test_single_dash_options_after_host_are_remote_argv(self):
        args = parse_args(["example.com", "-p", "2222"])

        self.assertEqual(args.command, "run")
        self.assertEqual(args.remote_argv, ["-p", "2222"])

    def test_preserve_args_without_remote_command_is_rejected(self):
        with self.assertRaises(SystemExit) as raised:
            parse_args(["example.com", "--preserve-args"])

        self.assertEqual(
            str(raised.exception),
            "--preserve-args is only valid with a remote command",
        )

    def test_attach_rejects_remote_command_args(self):
        with self.assertRaises(SystemExit) as raised:
            parse_args(["example.com", "--attach", "k7m4q2", "echo"])

        self.assertEqual(
            str(raised.exception),
            "--attach does not accept remote command arguments",
        )

    def test_list_rejects_remote_command_args(self):
        with self.assertRaises(SystemExit) as raised:
            parse_args(["example.com", "--list", "echo"])

        self.assertEqual(
            str(raised.exception),
            "--list does not accept remote command arguments",
        )


if __name__ == "__main__":
    unittest.main()
