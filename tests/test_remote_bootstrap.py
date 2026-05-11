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
                        "sessh run exited with status 0",
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
                        "sessh run exited with status 7",
                        "--- sessh exited abc123 ---",
                    ]
                )
                + "\n",
            )
            self.assertFalse(remote.has_session("abc123"))
            self.assertFalse((remote.sessions_dir / "abc123").exists())


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

    def outer_tmux(self):
        return LocalOuterTmuxDriver(self.testcase, self)

    def has_session(self, resume_id):
        result = subprocess.run(
            [
                "tmux",
                "-S",
                str(self.sessh_state / "sockets" / "tmux.sock"),
                "-f",
                str(self.sessh_state / "tmux.conf"),
                "has-session",
                "-t",
                f"sessh-{resume_id}",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return result.returncode == 0

    def wait_for_status(self, resume_id, *, timeout=10):
        status_file = self.sessions_dir / resume_id / "exit-status"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if status_file.exists():
                return int(status_file.read_text(encoding="utf-8").strip())
            time.sleep(0.05)
        self.testcase.fail(f"timed out waiting for {status_file}")


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
                    "export HOME XDG_STATE_HOME",
                    f'{shlex.quote(str(self.transaction))} "$@"',
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
        command = " ".join(
            [shlex.quote(str(self.driver)), *[shlex.quote(arg) for arg in remote_argv]]
        )
        self._tmux(
            "new-session",
            "-d",
            "-x",
            str(self.width),
            "-y",
            str(self.height),
            "-s",
            self.session,
            command,
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
