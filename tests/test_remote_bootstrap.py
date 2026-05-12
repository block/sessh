import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from importlib.resources import files
from pathlib import Path

from sessh.remote_rc import default_remote_rc


class RemoteBootstrapTests(unittest.TestCase):
    def test_remote_shell_syntax_is_valid(self):
        script = files("sessh").joinpath("remote.sh").read_text(encoding="utf-8")

        subprocess.run(
            ["/bin/sh", "-n"],
            input=script,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    def test_terminal_height_detection_fails_without_rows(self):
        script = files("sessh").joinpath("remote.sh").read_text(encoding="utf-8")

        with tempfile.TemporaryDirectory() as tmp:
            fakebin = Path(tmp) / "bin"
            fakebin.mkdir()
            for tool in ("stty", "tput"):
                path = fakebin / tool
                path.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
                path.chmod(0o700)

            result = subprocess.run(
                [
                    "/bin/sh",
                    "-c",
                    script + "\nsessh_terminal_lines\n",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    **os.environ,
                    "LINES": "0",
                    "PATH": str(fakebin),
                },
            )

        self.assertEqual(result.returncode, 64)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "sessh: unable to determine terminal height\n")

    def test_scrollback_note_uses_captured_pane_history_when_format_is_unavailable(
        self,
    ):
        script = files("sessh").joinpath("remote.sh").read_text(encoding="utf-8")

        result = subprocess.run(
            [
                "/bin/sh",
                "-c",
                script
                + """
sessh_tmux() {
  case "$1" in
    capture-pane)
      sessh_start=
      sessh_end=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -S) sessh_start=$2; shift 2 ;;
          -E) sessh_end=$2; shift 2 ;;
          *) shift ;;
        esac
      done
      case "$sessh_start:$sessh_end" in
        "-:-") printf '%s\\n' hist-1 hist-2 hist-3 visible-1 visible-2 ;;
        "0:-") printf '%s\\n' visible-1 visible-2 ;;
        *) return 1 ;;
      esac
      ;;
    display-message)
      printf '%s\\n' '#{history_size}'
      ;;
    *)
      return 1
      ;;
  esac
}
sessh_scrollback_note ignored-target 1
""",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={**os.environ, "LINES": "2"},
            check=True,
        )

        self.assertEqual(result.stdout, "; skipped 2 lines of scrollback")
        self.assertEqual(result.stderr, "")

    def test_remote_shell_bootstraps_state_with_real_tools(self):
        if shutil.which("tmux") is None:
            raise unittest.SkipTest("tmux is not installed")
        if shutil.which("bash") is None:
            raise unittest.SkipTest("bash is not installed")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state_home = root / "state"
            marker = root / "remote-init-marker"
            remote_init = f"printf 'init\\n' > {marker}\n"
            script = (
                files("sessh").joinpath("remote.sh").read_text(encoding="utf-8")
                + '\nsessh_main "$@"\n'
            )

            result = subprocess.run(
                [
                    "/bin/sh",
                    "-c",
                    script,
                    "sessh",
                    "list",
                    "bash",
                    "77",
                    remote_init,
                    default_remote_rc("bash"),
                    "",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    **os.environ,
                    "HOME": str(root),
                    "XDG_STATE_HOME": str(state_home),
                },
                check=True,
            )

            self.assertEqual(result.stdout, "")
            self.assertEqual(marker.read_text(encoding="utf-8"), "init\n")
            self.assertFalse((state_home / "sessh" / "remote-init.sh").exists())
            self.assertEqual(
                (state_home / "sessh" / "remote-rc").read_text(encoding="utf-8"),
                default_remote_rc("bash"),
            )
            self.assertEqual(
                (state_home / "sessh" / "zsh" / ".zshrc").read_text(encoding="utf-8"),
                default_remote_rc("bash"),
            )
            self.assertEqual(
                (state_home / "sessh" / "tmux.conf")
                .read_text(encoding="utf-8")
                .splitlines(),
                [
                    "set-option -g status off",
                    "set-option -g mouse off",
                    "set-option -g prefix None",
                    "set-option -g prefix2 None",
                    "set-option -g escape-time 0",
                    "set-option -ga terminal-overrides ',*:smcup@:rmcup@'",
                    "set-option -g exit-empty on",
                    "set-option -g exit-unattached off",
                    "set-option -g destroy-unattached off",
                    "set-window-option -g history-limit 77",
                    "set-window-option -g alternate-screen off",
                    "set-window-option -g pane-border-status off",
                ],
            )

    def test_remote_shell_reports_missing_tmux_cleanly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state_home = root / "state"
            empty_path = root / "empty-path"
            empty_path.mkdir()
            script = (
                files("sessh").joinpath("remote.sh").read_text(encoding="utf-8")
                + '\nsessh_main "$@"\n'
            )

            result = subprocess.run(
                [
                    "/bin/sh",
                    "-c",
                    script,
                    "sessh",
                    "list",
                    "bash",
                    "77",
                    f"PATH={empty_path}; export PATH",
                    default_remote_rc("bash"),
                    "",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={
                    **os.environ,
                    "HOME": str(root),
                    "XDG_STATE_HOME": str(state_home),
                },
                check=False,
            )

            self.assertEqual(result.returncode, 127)
            self.assertEqual(result.stdout, "")
            self.assertEqual(
                result.stderr,
                "\n".join(
                    [
                        "sessh: required remote tool not found: tmux",
                        "sessh: install tmux on the remote host or make it available in PATH",
                    ]
                )
                + "\n",
            )

    def test_run_streams_exact_outer_terminal_state_from_transcript(self):
        require_tool("tmux")
        require_tool("bash")

        with LocalRemoteHarness(self) as remote:
            with remote.outer_tmux() as outer:
                outer.start_driver(
                    [
                        "run",
                        "bash",
                        "200",
                        "",
                        "",
                        "",
                        "abc123",
                        "localhost",
                        "0",
                        "printf",
                        "printf",
                        "%s\ngoodbye\n",
                        "hello world",
                    ]
                )
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

            self.assertEqual(
                terminal_payload,
                "\n".join(
                    [
                        "--- sessh created abc123 ---",
                        "hello world",
                        "goodbye",
                        "--- sessh exited abc123 ---",
                    ]
                )
                + "\n",
            )
            self.assertFalse(remote.has_session("abc123"))
            self.assertFalse((remote.sessions_dir / "abc123").exists())

    def test_run_attach_replays_transcript_after_stream_disconnect(self):
        require_tool("tmux")
        require_tool("bash")

        with LocalRemoteHarness(self) as remote:
            with remote.outer_tmux() as first:
                first.start_driver(
                    [
                        "run",
                        "bash",
                        "200",
                        "",
                        "",
                        "",
                        "abc123",
                        "localhost",
                        "1",
                        "cmd",
                        "printf 'before\\n'; sleep 0.5; printf 'after\\n'; exit 7",
                    ]
                )
                first.wait_for_text("before")
                first.close()

            remote.wait_for_status("abc123")
            self.assertTrue(remote.has_session("abc123"))

            with remote.outer_tmux() as second:
                second.start_driver(
                    [
                        "attach-interactive",
                        "bash",
                        "200",
                        "",
                        "",
                        "",
                        "abc123",
                        "localhost",
                    ]
                )
                self.assertEqual(second.wait_for_exit(), 7)
                terminal_payload = second.terminal_payload()

            self.assertEqual(
                terminal_payload,
                "\n".join(
                    [
                        "--- sessh attached abc123 ---",
                        "before",
                        "after",
                        "--- sessh exited abc123 ---",
                    ]
                )
                + "\n",
            )
            self.assertFalse(remote.has_session("abc123"))
            self.assertFalse((remote.sessions_dir / "abc123").exists())

    def test_new_interactive_attach_does_not_insert_blank_padding(self):
        require_tool("tmux")
        require_tool("bash")

        before_lines = bottom_terminal_lines(12)
        with LocalRemoteHarness(self) as remote:
            with remote.outer_tmux(height=12, history_limit=200) as outer:
                outer.start_driver(
                    [
                        "new-interactive",
                        "bash",
                        "200",
                        "",
                        "PS1='PROMPT> '\n",
                        "",
                        "abc123",
                        "localhost",
                        "0",
                    ],
                    before_transaction=before_lines,
                )
                outer.wait_for_text("PROMPT>")
                live_terminal = outer.capture()
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

            self.assertEqual(
                live_terminal,
                "\n".join(
                    [
                        *before_lines,
                        "--- sessh created abc123 ---",
                        "PROMPT>",
                        *[""] * 11,
                    ]
                )
                + "\n",
            )
            self.assertEqual(
                terminal_payload,
                "\n".join(
                    [
                        *before_lines,
                        "--- sessh created abc123 ---",
                        "PROMPT>",
                    ]
                )
                + "\n",
            )

    def test_new_interactive_attach_preserves_previous_terminal_lines(self):
        require_tool("tmux")
        require_tool("bash")

        before_lines = numbered_terminal_lines(100)
        with LocalRemoteHarness(self) as remote:
            with remote.outer_tmux(height=8, history_limit=200) as outer:
                outer.start_driver(
                    [
                        "new-interactive",
                        "bash",
                        "200",
                        "",
                        "PS1='PROMPT> '\n",
                        "",
                        "abc123",
                        "localhost",
                        "0",
                    ],
                    before_transaction=before_lines,
                )
                outer.wait_for_text("PROMPT>")
                live_terminal = outer.capture()
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

            self.assertEqual(
                live_terminal,
                "\n".join(
                    [
                        *before_lines,
                        "--- sessh created abc123 ---",
                        "PROMPT>",
                        *[""] * 7,
                    ]
                )
                + "\n",
            )
            self.assertEqual(
                terminal_payload,
                "\n".join(
                    [
                        *before_lines,
                        "--- sessh created abc123 ---",
                        "PROMPT>",
                    ]
                )
                + "\n",
            )

    def test_cli_new_interactive_banner_survives_pty_relay(self):
        require_tool("tmux")
        require_tool("bash")

        before_lines = numbered_terminal_lines(100)
        with LocalRemoteHarness(self) as remote:
            remote.write_fake_ssh()
            remote.write_cli_config()
            (remote.home / ".bashrc").write_text("PS1='PROMPT> '\n", encoding="utf-8")

            with remote.outer_tmux(height=8, history_limit=200) as outer:
                outer.start_cli_driver(
                    ["--config", str(remote.cli_config), "fakehost"],
                    fixed_resume_id="abc123",
                    before_transaction=before_lines,
                )
                outer.wait_for_text("PROMPT>")
                live_terminal = outer.capture()
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

            self.assertEqual(
                live_terminal,
                "\n".join(
                    [
                        *before_lines,
                        "--- sessh created abc123 ---",
                        "PROMPT>",
                        *[""] * 7,
                    ]
                )
                + "\n",
            )
            self.assertEqual(
                terminal_payload,
                "\n".join(
                    [
                        *before_lines,
                        "--- sessh created abc123 ---",
                        "PROMPT>",
                    ]
                )
                + "\n",
            )

    def test_cli_attach_interactive_banner_survives_pty_relay(self):
        require_tool("tmux")
        require_tool("bash")

        before_lines = numbered_terminal_lines(100)
        with LocalRemoteHarness(self) as remote:
            remote.bootstrap(history_limit=200)
            remote.write_fake_ssh()
            remote.write_cli_config()
            rc = remote.root / "prompt.bashrc"
            rc.write_text("PS1='PROMPT> '\n", encoding="utf-8")
            remote.tmux(
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "8",
                "-s",
                "sessh-abc123",
                f"bash --rcfile {shlex.quote(str(rc))} -i",
            )
            remote.wait_for_pane_text("sessh-abc123:0.0", "PROMPT>")

            with remote.outer_tmux(height=8, history_limit=200) as outer:
                outer.start_cli_driver(
                    [
                        "--config",
                        str(remote.cli_config),
                        "fakehost",
                        "--attach",
                        "abc123",
                    ],
                    before_transaction=before_lines,
                )
                outer.wait_for_text("PROMPT>")
                live_terminal = outer.capture()
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

            self.assertEqual(
                live_terminal,
                "\n".join(
                    [
                        *before_lines,
                        "--- sessh attached abc123 ---",
                        "PROMPT>",
                        *[""] * 7,
                    ]
                )
                + "\n",
            )
            self.assertEqual(
                terminal_payload,
                "\n".join(
                    [
                        *before_lines,
                        "--- sessh attached abc123 ---",
                        "PROMPT>",
                    ]
                )
                + "\n",
            )

    def test_cli_attach_interactive_reports_skipped_scrollback(self):
        require_tool("tmux")
        require_tool("bash")

        with LocalRemoteHarness(self) as remote:
            remote.bootstrap(history_limit=300)
            remote.write_fake_ssh()
            remote.write_cli_config(history_limit=300)
            remote.tmux(
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "12",
                "-s",
                "sessh-abc123",
                "seq 500; sleep 3600",
            )
            remote.wait_for_pane_text("sessh-abc123:0.0", "500")
            history_size = int(
                remote.tmux(
                    "display-message",
                    "-p",
                    "-t",
                    "sessh-abc123:0.0",
                    "#{history_size}",
                ).stdout.strip()
            )
            self.assertGreater(history_size, 200)
            expected_banner = (
                f"--- sessh attached abc123; skipped {history_size - 200} "
                "lines of scrollback ---"
            )

            with remote.outer_tmux(width=100, height=12, history_limit=1000) as outer:
                outer.start_cli_driver(
                    [
                        "--config",
                        str(remote.cli_config),
                        "fakehost",
                        "--scrollback",
                        "200",
                        "--attach",
                        "abc123",
                    ]
                )
                outer.wait_for_text(expected_banner)
                outer.wait_for_text("500")
                remote.wait_for_session_attached("sessh-abc123")
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

        self.assertEqual(
            terminal_payload.splitlines(),
            [
                expected_banner,
                *[str(number) for number in range(290, 490)],
                "--- sessh live boundary ---",
                *[str(number) for number in range(490, 501)],
                *[str(number) for number in range(490, 501)],
            ],
        )

    def test_cli_attach_interactive_small_scrollback_has_no_padding_gap(self):
        require_tool("tmux")
        require_tool("bash")

        with LocalRemoteHarness(self) as remote:
            remote.bootstrap(history_limit=300)
            remote.write_fake_ssh()
            remote.write_cli_config(history_limit=300)
            remote.tmux(
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "54",
                "-s",
                "sessh-abc123",
                "seq 150; sleep 3600",
            )
            remote.wait_for_pane_text("sessh-abc123:0.0", "150")
            history_size = int(
                remote.tmux(
                    "display-message",
                    "-p",
                    "-t",
                    "sessh-abc123:0.0",
                    "#{history_size}",
                ).stdout.strip()
            )
            self.assertEqual(history_size, 97)
            expected_banner = (
                f"--- sessh attached abc123; skipped {history_size - 10} "
                "lines of scrollback ---"
            )

            with remote.outer_tmux(width=100, height=54, history_limit=1000) as outer:
                outer.start_cli_driver(
                    [
                        "--config",
                        str(remote.cli_config),
                        "fakehost",
                        "--attach",
                        "abc123",
                        "--scrollback",
                        "10",
                    ]
                )
                outer.wait_for_text(expected_banner)
                outer.wait_for_text("150")
                remote.wait_for_session_attached("sessh-abc123")
                live_terminal_lines = outer.capture().splitlines()
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_lines = outer.terminal_payload().splitlines()

        expected_lines = [
            expected_banner,
            *[str(number) for number in range(88, 98)],
            "--- sessh live boundary ---",
            *[str(number) for number in range(98, 151)],
            *[str(number) for number in range(98, 151)],
        ]
        live_boundary_index = live_terminal_lines.index("--- sessh live boundary ---")
        self.assertEqual(live_terminal_lines[live_boundary_index + 1], "98")
        self.assertEqual(terminal_lines, expected_lines)
        self.assertEqual(terminal_lines, live_terminal_lines[:-1])

    def test_cli_attach_interactive_without_scrollback_reports_skipped_history(self):
        require_tool("tmux")
        require_tool("bash")

        with LocalRemoteHarness(self) as remote:
            remote.bootstrap(history_limit=300)
            remote.write_fake_ssh()
            remote.write_cli_config(history_limit=300)
            remote.tmux(
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "12",
                "-s",
                "sessh-abc123",
                "seq 200; sleep 3600",
            )
            remote.wait_for_pane_text("sessh-abc123:0.0", "200")
            history_size = int(
                remote.tmux(
                    "display-message",
                    "-p",
                    "-t",
                    "sessh-abc123:0.0",
                    "#{history_size}",
                ).stdout.strip()
            )
            self.assertEqual(history_size, 189)
            expected_banner = (
                f"--- sessh attached abc123; skipped {history_size} "
                "lines of scrollback ---"
            )

            with remote.outer_tmux(width=100, height=12, history_limit=1000) as outer:
                outer.start_cli_driver(
                    [
                        "--config",
                        str(remote.cli_config),
                        "fakehost",
                        "--attach",
                        "abc123",
                    ]
                )
                outer.wait_for_text(expected_banner)
                outer.wait_for_text("200")
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

        self.assertEqual(
            terminal_payload.splitlines(),
            [
                expected_banner,
                *[str(number) for number in range(190, 201)],
            ],
        )

    def test_interactive_attach_without_scrollback_reports_skipped_lines(self):
        require_tool("tmux")
        require_tool("bash")

        before_lines = numbered_terminal_lines(10)
        with LocalRemoteHarness(self) as remote:
            remote.bootstrap(history_limit=200)
            rc = remote.root / "prompt.bashrc"
            rc.write_text("PS1='PROMPT> '\n", encoding="utf-8")
            remote.tmux(
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "5",
                "-s",
                "sessh-abc123",
                (
                    "i=0; while [ $i -lt 8 ]; do "
                    "echo hist-$i; i=$((i + 1)); done; "
                    f"bash --rcfile {shlex.quote(str(rc))} -i"
                ),
            )
            remote.wait_for_pane_text("sessh-abc123:0.0", "PROMPT>")
            history_size = int(
                remote.tmux(
                    "display-message",
                    "-p",
                    "-t",
                    "sessh-abc123:0.0",
                    "#{history_size}",
                ).stdout.strip()
            )
            self.assertGreater(history_size, 0)

            with remote.outer_tmux(height=8, history_limit=200) as outer:
                outer.start_driver(
                    [
                        "attach-interactive",
                        "bash",
                        "200",
                        "",
                        "",
                        "",
                        "abc123",
                        "localhost",
                        "0",
                    ],
                    before_transaction=before_lines,
                )
                outer.wait_for_text("PROMPT>")
                live_terminal = outer.capture()
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

        expected_lines = [
            *before_lines,
            "--- sessh attached abc123; skipped 1 line of scrollback ---",
            "hist-1",
            "hist-2",
            "hist-3",
            "hist-4",
            "hist-5",
            "hist-6",
            "hist-7",
            "PROMPT>",
        ]
        self.assertEqual(live_terminal, "\n".join(expected_lines) + "\n")
        self.assertEqual(terminal_payload, "\n".join(expected_lines) + "\n")

    def test_interactive_attach_without_scrollback_omits_note_when_attach_covers_history(
        self,
    ):
        require_tool("tmux")
        require_tool("bash")

        before_lines = numbered_terminal_lines(10)
        with LocalRemoteHarness(self) as remote:
            remote.bootstrap(history_limit=200)
            rc = remote.root / "prompt.bashrc"
            rc.write_text("PS1='PROMPT> '\n", encoding="utf-8")
            remote.tmux(
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "5",
                "-s",
                "sessh-abc123",
                (
                    "i=0; while [ $i -lt 8 ]; do "
                    "echo hist-$i; i=$((i + 1)); done; "
                    f"bash --rcfile {shlex.quote(str(rc))} -i"
                ),
            )
            remote.wait_for_pane_text("sessh-abc123:0.0", "PROMPT>")
            history_size = int(
                remote.tmux(
                    "display-message",
                    "-p",
                    "-t",
                    "sessh-abc123:0.0",
                    "#{history_size}",
                ).stdout.strip()
            )
            self.assertGreater(history_size, 0)

            with remote.outer_tmux(height=9, history_limit=200) as outer:
                outer.start_driver(
                    [
                        "attach-interactive",
                        "bash",
                        "200",
                        "",
                        "",
                        "",
                        "abc123",
                        "localhost",
                        "0",
                    ],
                    before_transaction=before_lines,
                )
                outer.wait_for_text("PROMPT>")
                live_terminal = outer.capture()
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

        expected_lines = [
            *before_lines,
            "--- sessh attached abc123 ---",
            "hist-0",
            "hist-1",
            "hist-2",
            "hist-3",
            "hist-4",
            "hist-5",
            "hist-6",
            "hist-7",
            "PROMPT>",
        ]
        self.assertEqual(live_terminal, "\n".join(expected_lines) + "\n")
        self.assertEqual(terminal_payload, "\n".join(expected_lines) + "\n")

    def test_interactive_attach_replays_configured_scrollback_before_attach(self):
        require_tool("tmux")
        require_tool("bash")

        with LocalRemoteHarness(self) as remote:
            remote.bootstrap(history_limit=200)
            remote.tmux(
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "5",
                "-s",
                "sessh-abc123",
                "i=0; while [ $i -lt 8 ]; do echo hist-$i; i=$((i + 1)); done; sleep 3600",
            )

            with remote.outer_tmux(height=10) as outer:
                outer.start_driver(
                    [
                        "attach-interactive",
                        "bash",
                        "200",
                        "",
                        "",
                        "",
                        "abc123",
                        "localhost",
                        "4",
                    ]
                )
                outer.wait_for_text("hist-2")
                outer.wait_for_text("hist-7")
                remote.wait_for_session_attached("sessh-abc123")
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

            self.assertEqual(
                terminal_payload.splitlines(),
                [
                    "--- sessh attached abc123 ---",
                    "hist-0",
                    "hist-1",
                    "hist-2",
                    "hist-3",
                    "--- sessh live boundary ---",
                    "hist-4",
                    "hist-5",
                    "hist-6",
                    "hist-7",
                    "",
                    "hist-4",
                    "hist-5",
                    "hist-6",
                    "hist-7",
                    "hist-0",
                    "hist-1",
                    "hist-2",
                    "hist-3",
                    "hist-4",
                    "hist-5",
                    "hist-6",
                    "hist-7",
                ],
            )

    def test_interactive_reattach_replays_long_scrollback_before_live_screen(self):
        require_tool("tmux")
        require_tool("bash")

        with LocalRemoteHarness(self) as remote:
            remote.bootstrap(history_limit=300)
            remote.tmux(
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "12",
                "-s",
                "sessh-abc123",
                "seq 200; sleep 3600",
            )
            remote.wait_for_pane_text("sessh-abc123:0.0", "200")

            with remote.outer_tmux(width=100, height=12, history_limit=1000) as outer:
                outer.start_driver(
                    [
                        "attach-interactive",
                        "bash",
                        "300",
                        "",
                        "",
                        "",
                        "abc123",
                        "localhost",
                        "200",
                    ]
                )
                outer.wait_for_text("--- sessh live boundary ---")
                outer.wait_for_text("200")
                remote.wait_for_session_attached("sessh-abc123")
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

        self.assertEqual(
            terminal_payload.splitlines(),
            [
                "--- sessh attached abc123 ---",
                *[str(number) for number in range(1, 190)],
                "--- sessh live boundary ---",
                *[str(number) for number in range(190, 201)],
                *[str(number) for number in range(190, 201)],
            ],
        )

    def test_interactive_reattach_banner_reports_skipped_scrollback(self):
        require_tool("tmux")
        require_tool("bash")

        with LocalRemoteHarness(self) as remote:
            remote.bootstrap(history_limit=300)
            remote.tmux(
                "new-session",
                "-d",
                "-x",
                "80",
                "-y",
                "12",
                "-s",
                "sessh-abc123",
                "seq 500; sleep 3600",
            )
            remote.wait_for_pane_text("sessh-abc123:0.0", "500")
            history_size = int(
                remote.tmux(
                    "display-message",
                    "-p",
                    "-t",
                    "sessh-abc123:0.0",
                    "#{history_size}",
                ).stdout.strip()
            )
            self.assertGreater(history_size, 200)
            expected_banner = (
                f"--- sessh attached abc123; skipped {history_size - 200} "
                "lines of scrollback ---"
            )

            with remote.outer_tmux(width=100, height=12, history_limit=1000) as outer:
                outer.start_driver(
                    [
                        "attach-interactive",
                        "bash",
                        "300",
                        "",
                        "",
                        "",
                        "abc123",
                        "localhost",
                        "200",
                    ]
                )
                outer.wait_for_text(expected_banner)
                outer.wait_for_text("500")
                remote.wait_for_session_attached("sessh-abc123")
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

        self.assertEqual(
            terminal_payload.splitlines(),
            [
                expected_banner,
                *[str(number) for number in range(290, 490)],
                "--- sessh live boundary ---",
                *[str(number) for number in range(490, 501)],
                *[str(number) for number in range(490, 501)],
            ],
        )


def require_tool(tool):
    if shutil.which(tool) is None:
        raise unittest.SkipTest(f"{tool} is not installed")


def bottom_terminal_lines(height):
    return [f"before-{index}" for index in range(1, height + 2)]


def numbered_terminal_lines(count):
    return [str(index) for index in range(1, count + 1)]


class LocalRemoteHarness:
    def __init__(self, testcase):
        self.testcase = testcase
        self.tmp = tempfile.TemporaryDirectory(prefix="sessh-", dir="/tmp")
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.state_home = self.root / "state"
        self.sessh_state = self.state_home / "sessh"
        self.sessions_dir = self.sessh_state / "sessions"
        self.fakebin = self.root / "fakebin"
        self.cli_config = self.root / "config.yaml"
        self.home.mkdir()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        subprocess.run(
            [
                "tmux",
                "-S",
                str(self.sessh_state / "sockets" / "tmux.sock"),
                "kill-server",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.tmp.cleanup()

    def outer_tmux(self, *, width=100, height=20, history_limit=2000):
        return LocalOuterTmuxDriver(
            self.testcase,
            self,
            width=width,
            height=height,
            history_limit=history_limit,
        )

    def write_cli_config(self, *, shell="bash", history_limit=200):
        self.cli_config.write_text(
            "\n".join(
                [
                    "defaults:",
                    f"  shell: {shell}",
                    f"  history-limit: {history_limit}",
                    "",
                ]
            ),
            encoding="utf-8",
        )

    def write_fake_ssh(self):
        self.fakebin.mkdir(exist_ok=True)
        fake_ssh = self.fakebin / "ssh"
        fake_ssh.write_text(
            "\n".join(
                [
                    "#!/bin/sh",
                    'while [ "$#" -gt 0 ]; do',
                    '  case "$1" in',
                    "    -t|-tt|-T) shift ;;",
                    "    -o) shift 2 ;;",
                    "    -*) shift ;;",
                    "    *) shift; break ;;",
                    "  esac",
                    "done",
                    f"HOME={shlex.quote(str(self.home))}",
                    f"XDG_STATE_HOME={shlex.quote(str(self.state_home))}",
                    "export HOME XDG_STATE_HOME",
                    'exec /bin/sh -c "$1"',
                    "",
                ]
            ),
            encoding="utf-8",
        )
        fake_ssh.chmod(0o700)

    def bootstrap(self, *, shell="bash", history_limit=200):
        script = files("sessh").joinpath("remote.sh").read_text(encoding="utf-8")
        subprocess.run(
            [
                "/bin/sh",
                "-c",
                script + '\nsessh_main "$@"\n',
                "sessh",
                "list",
                shell,
                str(history_limit),
                "",
                default_remote_rc(shell),
                "",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.env(),
            check=True,
        )

    def env(self):
        return {
            **os.environ,
            "HOME": str(self.home),
            "XDG_STATE_HOME": str(self.state_home),
        }

    def tmux(self, *args, check=True):
        result = subprocess.run(
            [
                "tmux",
                "-S",
                str(self.sessh_state / "sockets" / "tmux.sock"),
                "-f",
                str(self.sessh_state / "tmux.conf"),
                *args,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if check and result.returncode != 0:
            self.testcase.fail(
                f"tmux command failed: {args!r}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        return result

    def has_session(self, resume_id):
        result = self.tmux("has-session", "-t", f"sessh-{resume_id}", check=False)
        return result.returncode == 0

    def wait_for_status(self, resume_id, *, timeout=10):
        status_file = self.sessions_dir / resume_id / "exit-status"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if status_file.exists():
                return int(status_file.read_text(encoding="utf-8").strip())
            time.sleep(0.05)
        self.testcase.fail(f"timed out waiting for {status_file}")

    def wait_for_pane_text(self, target, text, *, history_limit=1000, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            capture = self.tmux(
                "capture-pane",
                "-p",
                "-S",
                f"-{history_limit}",
                "-E",
                "-",
                "-t",
                target,
            ).stdout
            if text in capture:
                return
            time.sleep(0.05)
        self.testcase.fail(f"timed out waiting for {text!r} in {target}:\n{capture}")

    def wait_for_session_attached(self, session_name, *, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.tmux(
                "display-message",
                "-p",
                "-t",
                session_name,
                "#{session_attached}",
                check=False,
            )
            if result.returncode == 0 and result.stdout.strip() not in {"", "0"}:
                return
            time.sleep(0.05)
        self.testcase.fail(f"timed out waiting for {session_name} to be attached")


class LocalOuterTmuxDriver:
    def __init__(self, testcase, remote, *, width=100, height=20, history_limit=2000):
        self.testcase = testcase
        self.remote = remote
        self.width = width
        self.height = height
        self.history_limit = history_limit
        self.root = remote.root / f"o-{uuid.uuid4().hex[:8]}"
        self.root.mkdir()
        self.socket = self.root / "s"
        self.config = self.root / "c"
        self.driver = self.root / "d.sh"
        self.transaction = self.root / "r.sh"
        self.status_file = self.root / "status"
        self.session = f"sessh-outer-{uuid.uuid4().hex[:10]}"
        self.target = f"{self.session}:0.0"
        self.closed = False
        self.config.write_text(
            "\n".join(
                [
                    "set-option -g status off",
                    "set-option -g mouse off",
                    "set-option -g exit-empty off",
                    "set-option -g destroy-unattached off",
                    f"set-window-option -g history-limit {history_limit}",
                    "",
                ]
            ),
            encoding="utf-8",
        )

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()

    def start_driver(self, remote_argv, *, before_transaction=()):
        script = files("sessh").joinpath("remote.sh").read_text(encoding="utf-8")
        self.transaction.write_text(script + '\nsessh_main "$@"\n', encoding="utf-8")
        self.transaction.chmod(0o700)
        before_transaction_lines = [
            f"printf '%s\\n' {shlex.quote(line)}" for line in before_transaction
        ]
        self.driver.write_text(
            "\n".join(
                [
                    "#!/bin/sh",
                    "set +e",
                    f"HOME={shlex.quote(str(self.remote.home))}",
                    f"XDG_STATE_HOME={shlex.quote(str(self.remote.state_home))}",
                    f"LINES={self.height}",
                    f"COLUMNS={self.width}",
                    "export HOME XDG_STATE_HOME LINES COLUMNS",
                    *before_transaction_lines,
                    " ".join(
                        [
                            shlex.quote(str(self.transaction)),
                            *[shlex.quote(arg) for arg in remote_argv],
                        ]
                    ),
                    "sessh_driver_status=$?",
                    f"printf '%s\\n' \"$sessh_driver_status\" > {shlex.quote(str(self.status_file))}",
                    "printf '__SESSH_DRIVER_DONE__=%s\\n' \"$sessh_driver_status\"",
                    "sleep 3600",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        self.driver.chmod(0o700)
        self._tmux(
            "new-session",
            "-d",
            "-x",
            str(self.width),
            "-y",
            str(self.height),
            "-s",
            self.session,
            shlex.quote(str(self.driver)),
        )

    def start_cli_driver(
        self,
        argv,
        *,
        fixed_resume_id=None,
        before_transaction=(),
    ):
        if fixed_resume_id is None:
            python_code = (
                "import sys; from sessh.cli import main; sys.exit(main(sys.argv[1:]))"
            )
        else:
            python_code = (
                "import sys; "
                "from sessh.cli import execute, parse_args; "
                f"sys.exit(execute(parse_args(sys.argv[1:]), "
                f"id_generator=lambda existing: {fixed_resume_id!r}))"
            )
        before_transaction_lines = [
            f"printf '%s\\n' {shlex.quote(line)}" for line in before_transaction
        ]
        self.driver.write_text(
            "\n".join(
                [
                    "#!/bin/sh",
                    "set +e",
                    f"PATH={shlex.quote(str(self.remote.fakebin))}:$PATH",
                    "export PATH",
                    *before_transaction_lines,
                    " ".join(
                        [
                            shlex.quote(sys.executable),
                            "-c",
                            shlex.quote(python_code),
                            *[shlex.quote(arg) for arg in argv],
                        ]
                    ),
                    "sessh_driver_status=$?",
                    f"printf '%s\\n' \"$sessh_driver_status\" > {shlex.quote(str(self.status_file))}",
                    "printf '__SESSH_DRIVER_DONE__=%s\\n' \"$sessh_driver_status\"",
                    "sleep 3600",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        self.driver.chmod(0o700)
        self._tmux(
            "new-session",
            "-d",
            "-x",
            str(self.width),
            "-y",
            str(self.height),
            "-s",
            self.session,
            shlex.quote(str(self.driver)),
        )

    def close(self):
        if self.closed:
            return
        self._tmux("kill-server", check=False)
        self.closed = True

    def wait_for_text(self, text, *, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            capture = self.capture()
            if text in capture:
                return
            time.sleep(0.05)
        self.testcase.fail(
            f"timed out waiting for {text!r} in outer tmux pane:\n{self.capture()}"
        )

    def wait_for_exit(self, *, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.status_file.exists():
                return int(self.status_file.read_text(encoding="utf-8").strip())
            time.sleep(0.05)
        self.testcase.fail(
            f"timed out waiting for sessh driver to exit:\n{self.capture()}"
        )

    def terminal_payload(self):
        capture = self.capture()
        marker = "__SESSH_DRIVER_DONE__="
        marker_index = capture.find(marker)
        self.testcase.assertNotEqual(marker_index, -1, capture)
        return capture[:marker_index]

    def capture(self):
        return self._tmux(
            "capture-pane",
            "-p",
            "-S",
            f"-{self.history_limit}",
            "-E",
            "-",
            "-t",
            self.target,
        ).stdout

    def _tmux(self, *args, check=True):
        result = subprocess.run(
            ["tmux", "-S", str(self.socket), "-f", str(self.config), *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if check and result.returncode != 0:
            self.testcase.fail(
                f"tmux command failed: {args!r}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        return result


if __name__ == "__main__":
    unittest.main()
