import os
import shutil
import subprocess
import tempfile
import unittest
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
            script = files("sessh").joinpath("remote.sh").read_text(encoding="utf-8") + '\nsessh_main "$@"\n'

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
            self.assertEqual((state_home / "sessh" / "remote-rc").read_text(encoding="utf-8"), default_remote_rc("bash"))
            self.assertEqual((state_home / "sessh" / "zsh" / ".zshrc").read_text(encoding="utf-8"), default_remote_rc("bash"))
            self.assertEqual(
                (state_home / "sessh" / "tmux.conf").read_text(encoding="utf-8").splitlines(),
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


if __name__ == "__main__":
    unittest.main()
