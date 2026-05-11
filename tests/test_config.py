import os
import tempfile
import unittest
from pathlib import Path

from sessh.config import Config, load_config
from sessh.remote_rc import default_remote_rc


class ConfigTests(unittest.TestCase):
    def test_builtin_shell_defaults_from_supported_current_shell(self):
        self.assertEqual(Config.built_in(current_shell="/bin/zsh").shell, "zsh")
        self.assertEqual(
            Config.built_in(current_shell="/usr/local/bin/bash").shell, "bash"
        )

    def test_builtin_shell_defaults_to_bash_for_other_shells(self):
        self.assertEqual(Config.built_in(current_shell="/bin/fish").shell, "bash")
        self.assertEqual(Config.built_in(current_shell="").shell, "bash")

    def test_load_config_reads_defaults_table(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.yaml"
            path.write_text(
                "defaults:\n"
                "  shell: zsh\n"
                "  history-limit: 1234\n"
                "  auto-reattach: true\n",
                encoding="utf-8",
            )

            config = load_config(path, current_shell="/bin/bash")

        self.assertEqual(config.shell, "zsh")
        self.assertEqual(config.history_limit, 1234)
        self.assertTrue(config.auto_reattach)
        self.assertEqual(config.remote_rc, default_remote_rc("zsh"))

    def test_cli_overrides_config_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.yaml"
            path.write_text(
                "defaults:\n  shell: zsh\n  history-limit: 1234\n", encoding="utf-8"
            )

            config = load_config(
                path, current_shell="/bin/bash", shell="bash", history_limit=99
            )

        self.assertEqual(config.shell, "bash")
        self.assertEqual(config.history_limit, 99)
        self.assertEqual(config.remote_rc, default_remote_rc("bash"))

    def test_load_config_reads_inline_remote_init(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.yaml"
            path.write_text(
                """defaults:
  shell: bash
remote-init: |
  export PATH="/custom/bin:$PATH"
  printf 'remote init\\n' >&2
""",
                encoding="utf-8",
            )

            config = load_config(path, current_shell="/bin/bash")

        self.assertEqual(
            config.remote_init,
            "export PATH=\"/custom/bin:$PATH\"\nprintf 'remote init\\n' >&2\n",
        )

    def test_load_config_reads_inline_remote_rc(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.yaml"
            path.write_text(
                """defaults:
  shell: bash
remote-rc: |
  export SESSH_TEST_RC=from-config
""",
                encoding="utf-8",
            )

            config = load_config(path, current_shell="/bin/bash")

        self.assertEqual(config.remote_rc, "export SESSH_TEST_RC=from-config\n")

    def test_rejects_invalid_shell(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.yaml"
            path.write_text("defaults:\n  shell: fish\n", encoding="utf-8")

            with self.assertRaises(ValueError):
                load_config(path, current_shell="/bin/bash")

    def test_rejects_non_string_remote_init(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.yaml"
            path.write_text("remote-init:\n  script: echo no\n", encoding="utf-8")

            with self.assertRaises(ValueError):
                load_config(path, current_shell="/bin/bash")

    def test_rejects_non_string_remote_rc(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.yaml"
            path.write_text("remote-rc:\n  script: echo no\n", encoding="utf-8")

            with self.assertRaises(ValueError):
                load_config(path, current_shell="/bin/bash")

    def test_rejects_boolean_history_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.yaml"
            path.write_text("defaults:\n  history-limit: true\n", encoding="utf-8")

            with self.assertRaises(ValueError):
                load_config(path, current_shell="/bin/bash")

    def test_rejects_non_boolean_auto_reattach(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.yaml"
            path.write_text(
                "defaults:\n  auto-reattach: yes please\n", encoding="utf-8"
            )

            with self.assertRaises(ValueError):
                load_config(path, current_shell="/bin/bash")

    def test_xdg_config_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = os.environ.get("XDG_CONFIG_HOME")
            os.environ["XDG_CONFIG_HOME"] = tmp
            try:
                self.assertEqual(
                    Config.default_path(), Path(tmp) / "sessh" / "config.yaml"
                )
            finally:
                if old is None:
                    os.environ.pop("XDG_CONFIG_HOME", None)
                else:
                    os.environ["XDG_CONFIG_HOME"] = old


if __name__ == "__main__":
    unittest.main()
