import os
import shlex
import shutil
import subprocess
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
                    *[""] * 10,
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
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

        self.assertEqual(
            terminal_payload.splitlines(),
            [
                "--- sessh attached abc123 ---",
                *[str(number) for number in range(1, 190)],
                "--- sessh live boundary ---",
                *[""] * 12,
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
                remote.tmux("kill-session", "-t", "sessh-abc123")
                self.assertEqual(outer.wait_for_exit(), 0)
                terminal_payload = outer.terminal_payload()

        self.assertEqual(
            terminal_payload.splitlines(),
            [
                expected_banner,
                *[str(number) for number in range(290, 490)],
                "--- sessh live boundary ---",
                *[""] * 12,
                *[str(number) for number in range(490, 501)],
            ],
        )


def require_tool(tool):
    if shutil.which(tool) is None:
        raise unittest.SkipTest(f"{tool} is not installed")


class LocalRemoteHarness:
    def __init__(self, testcase):
        self.testcase = testcase
        self.tmp = tempfile.TemporaryDirectory(prefix="sessh-", dir="/tmp")
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.state_home = self.root / "state"
        self.sessh_state = self.state_home / "sessh"
        self.sessions_dir = self.sessh_state / "sessions"
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

    def start_driver(self, remote_argv):
        script = files("sessh").joinpath("remote.sh").read_text(encoding="utf-8")
        self.transaction.write_text(script + '\nsessh_main "$@"\n', encoding="utf-8")
        self.transaction.chmod(0o700)
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
