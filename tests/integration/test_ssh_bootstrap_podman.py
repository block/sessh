import io
import os
import signal
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path

from sessh.cli import execute, parse_args
from sessh.remote import SshClient
from sessh.remote_rc import default_remote_rc


REPO_ROOT = Path(__file__).resolve().parents[2]
SRC_DIR = REPO_ROOT / "src"
REMOTE_STATE = "/home/sessh/.local/state/sessh"


def podman_tests_enabled() -> bool:
    return os.environ.get("SESSH_RUN_PODMAN_TESTS") == "1"


@unittest.skipUnless(
    podman_tests_enabled(),
    "set SESSH_RUN_PODMAN_TESTS=1 to run Podman SSH integration tests",
)
class PodmanSshBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which("podman") is None:
            raise unittest.SkipTest("podman is not installed")
        if shutil.which("tmux") is None:
            raise unittest.SkipTest("tmux is not installed")
        if shutil.which("ssh-keygen") is None:
            raise unittest.SkipTest("ssh-keygen is not installed")
        podman_info = subprocess.run(
            ["podman", "info"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if podman_info.returncode != 0:
            raise unittest.SkipTest(
                podman_info.stderr.strip() or "podman is not usable"
            )

        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.image = f"sessh-test-ssh:{uuid.uuid4().hex}"
        cls.container = None

        cls.key = cls.root / "id_ed25519"
        subprocess.run(
            ["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(cls.key)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        context = cls.root / "context"
        context.mkdir()
        (context / "authorized_keys").write_text(
            cls.key.with_suffix(".pub").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        (context / "Containerfile").write_text(
            """FROM docker.io/library/debian:bookworm-slim
RUN apt-get -o Acquire::Check-Date=false update \\
 && apt-get install -y --no-install-recommends openssh-server openssh-client tmux bash zsh git python3 \\
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash sessh && mkdir -p /run/sshd /home/sessh/.ssh
COPY authorized_keys /home/sessh/.ssh/authorized_keys
RUN chown -R sessh:sessh /home/sessh/.ssh && chmod 700 /home/sessh/.ssh && chmod 600 /home/sessh/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
""",
            encoding="utf-8",
        )

        subprocess.run(["podman", "build", "-t", cls.image, str(context)], check=True)
        run = subprocess.run(
            ["podman", "run", "-d", "--rm", "-p", "127.0.0.1::22", cls.image],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        )
        cls.container = run.stdout.strip()
        cls.port = cls._container_port()
        cls.ssh_options = [
            "-p",
            cls.port,
            "-i",
            str(cls.key),
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "LogLevel=ERROR",
        ]
        cls.host = "sessh@127.0.0.1"
        cls._wait_for_ssh()

    @classmethod
    def tearDownClass(cls):
        try:
            if getattr(cls, "container", None):
                subprocess.run(
                    ["podman", "rm", "-f", cls.container],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            if getattr(cls, "image", None):
                subprocess.run(
                    ["podman", "rmi", "-f", cls.image],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
        finally:
            if getattr(cls, "tmp", None):
                cls.tmp.cleanup()

    def setUp(self):
        self._reset_remote_state()

    def tearDown(self):
        self._reset_remote_state()

    def test_cli_list_bootstraps_remote_state(self):
        config = self._write_cli_config("bootstrap", history_limit=4321)
        stdout = io.StringIO()

        exit_status = execute(
            parse_args(
                [
                    "--quiet",
                    "--config",
                    str(config),
                    *self.ssh_options,
                    self.host,
                    "list",
                ]
            ),
            stdout=stdout,
        )

        self.assertEqual(exit_status, 0)
        self.assertEqual(
            stdout.getvalue(), "ID\tATTACHED\tCREATED\tCWD\tCOMMAND\tTITLE\n"
        )
        self.assertEqual(
            self.client().run(["cat", f"{REMOTE_STATE}/tmux.conf"]).stdout.splitlines(),
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
                "set-window-option -g history-limit 4321",
                "set-window-option -g alternate-screen off",
                "set-window-option -g pane-border-status off",
            ],
        )
        self.assertEqual(
            self.client().run(["cat", f"{REMOTE_STATE}/remote-rc"]).stdout,
            default_remote_rc("bash"),
        )
        self.assertEqual(
            self.client().run(["cat", f"{REMOTE_STATE}/zsh/.zshrc"]).stdout,
            default_remote_rc("bash"),
        )

    def test_cli_uses_inline_yaml_remote_init(self):
        marker = f"/home/sessh/yaml-remote-init-{uuid.uuid4().hex}"
        config = self._write_cli_config(
            "inline-remote-init",
            remote_init=f"printf 'yaml-init\\n' > {marker}\n",
        )
        stdout = io.StringIO()

        exit_status = execute(
            parse_args(
                [
                    "--quiet",
                    "--config",
                    str(config),
                    *self.ssh_options,
                    self.host,
                    "list",
                ]
            ),
            stdout=stdout,
        )

        self.assertEqual(exit_status, 0)
        self.assertEqual(self.client().run(["cat", marker]).stdout, "yaml-init\n")
        self.client().run(["test", "!", "-e", f"{REMOTE_STATE}/remote-init.sh"])

    def test_cli_run_over_real_ssh_preserves_argv_and_returns_exit_status(self):
        config = self._write_cli_config("cli-run-argv")
        with OuterTmuxSession(self) as outer:
            outer.start_driver(
                [
                    "--config",
                    str(config),
                    *self.ssh_options,
                    self.host,
                    "run",
                    "python3",
                    "-c",
                    "import sys; [print(arg) for arg in sys.argv[1:]]; sys.exit(3)",
                    "hello world",
                    "$HOME",
                    "*.log",
                    "semi;colon",
                ],
            )
            exit_status = outer.wait_for_exit()
            lines = outer.terminal_lines()

        self.assertEqual(exit_status, 3)
        resume_id = parse_boundary_resume_id(self, lines[0], "sessh created")
        self.assertEqual(
            lines,
            [
                f"--- sessh created {resume_id} ---",
                "hello world",
                "$HOME",
                "*.log",
                "semi;colon",
                "sessh run exited with status 3",
                f"--- sessh exited {resume_id} ---",
                "hello world",
                "$HOME",
                "*.log",
                "semi;colon",
                "sessh run exited with status 3",
            ],
        )
        self.assertTrue(self._has_session(resume_id))
        self.client().run(
            ["test", "!", "-e", f"{REMOTE_STATE}/sessions/{resume_id}/completion.json"]
        )
        self.client().run(
            [
                "test",
                "!",
                "-e",
                f"{REMOTE_STATE}/sessions/{resume_id}/completion.json.tmp",
            ]
        )

    def test_cli_run_exit_255_is_not_reported_as_transport_disconnect(self):
        config = self._write_cli_config("cli-run-255")
        with OuterTmuxSession(self) as outer:
            outer.start_driver(
                [
                    "--config",
                    str(config),
                    *self.ssh_options,
                    self.host,
                    "run",
                    "sh",
                    "-c",
                    "printf 'status-255\\n'; exit 255",
                ],
            )
            exit_status = outer.wait_for_exit()
            lines = outer.terminal_lines()

        self.assertEqual(exit_status, 255)
        resume_id = parse_boundary_resume_id(self, lines[0], "sessh created")
        self.assertEqual(
            lines,
            [
                f"--- sessh created {resume_id} ---",
                "status-255",
                "sessh run exited with status 255",
                f"--- sessh exited {resume_id} ---",
                "status-255",
                "sessh run exited with status 255",
            ],
        )

    def test_cli_run_over_real_ssh_applies_remote_rc_and_eval_mode(self):
        config = self._write_cli_config(
            "cli-run-eval",
            remote_rc="export SESSH_TEST_RC='from remote rc; $HOME'\n",
        )
        with OuterTmuxSession(self) as outer:
            outer.start_driver(
                [
                    "--eval-args",
                    "--config",
                    str(config),
                    *self.ssh_options,
                    self.host,
                    "run",
                    'printf \'eval:%s\\nrc:%s\\nremote_rc:%s\\n\' "$HOME" "$SESSH_TEST_RC" "$SESSH_REMOTE_RC"',
                ],
            )
            exit_status = outer.wait_for_exit()
            lines = outer.terminal_lines()

        self.assertEqual(exit_status, 0)
        resume_id = parse_boundary_resume_id(self, lines[0], "sessh created")
        self.assertEqual(
            lines,
            [
                f"--- sessh created {resume_id} ---",
                "eval:/home/sessh",
                "rc:from remote rc; $HOME",
                f"remote_rc:{REMOTE_STATE}/remote-rc",
                "sessh run exited with status 0",
                f"--- sessh exited {resume_id} ---",
                "eval:/home/sessh",
                "rc:from remote rc; $HOME",
                f"remote_rc:{REMOTE_STATE}/remote-rc",
                "sessh run exited with status 0",
            ],
        )

    def test_cli_list_shows_completed_run_session(self):
        config = self._write_cli_config("cli-list-run")
        with OuterTmuxSession(self) as outer:
            outer.start_driver(
                [
                    "--config",
                    str(config),
                    *self.ssh_options,
                    self.host,
                    "run",
                    "printf",
                    "listed",
                ]
            )
            self.assertEqual(outer.wait_for_exit(), 0)
            run_lines = outer.terminal_lines()
        resume_id = parse_boundary_resume_id(self, run_lines[0], "sessh created")
        stdout = io.StringIO()

        exit_status = execute(
            parse_args(
                [
                    "--quiet",
                    "--config",
                    str(config),
                    *self.ssh_options,
                    self.host,
                    "list",
                ]
            ),
            stdout=stdout,
        )

        self.assertEqual(exit_status, 0)
        rows = [line.split("\t") for line in stdout.getvalue().splitlines()[1:]]
        matching_rows = [row for row in rows if row[0] == resume_id]
        self.assertEqual(len(matching_rows), 1)
        self.assertEqual(matching_rows[0][1], "no")
        self.assertEqual(matching_rows[0][4], "printf")

    def test_cli_list_sorts_unattached_before_attached_sessions(self):
        run_config = self._write_cli_config("cli-list-sort-run")
        with OuterTmuxSession(self) as outer:
            outer.start_driver(
                [
                    "--config",
                    str(run_config),
                    *self.ssh_options,
                    self.host,
                    "run",
                    "printf",
                    "listed",
                ]
            )
            self.assertEqual(outer.wait_for_exit(), 0)
            run_lines = outer.terminal_lines()
        run_id = parse_boundary_resume_id(self, run_lines[0], "sessh created")

        attached_config = self._write_cli_config(
            "cli-list-sort-attached",
            remote_rc="""printf 'attached-ready\\n'
while :; do
  sleep 1
done
""",
        )
        with OuterTmuxSession(self) as outer:
            outer.start_driver(
                ["--config", str(attached_config), *self.ssh_options, self.host]
            )
            outer.wait_for_text("attached-ready")
            attached_lines = outer.terminal_lines()
            attached_id = find_boundary_resume_id(self, attached_lines, "sessh created")
            stdout = io.StringIO()

            exit_status = execute(
                parse_args(
                    [
                        "--quiet",
                        "--config",
                        str(attached_config),
                        *self.ssh_options,
                        self.host,
                        "list",
                    ]
                ),
                stdout=stdout,
            )

            outer.send_ssh_disconnect()
            self.assertEqual(outer.wait_for_exit(), 255)

        self.assertEqual(exit_status, 0)
        rows = [line.split("\t") for line in stdout.getvalue().splitlines()[1:]]
        row_by_id = {row[0]: row for row in rows}
        self.assertEqual(row_by_id[run_id][1], "no")
        self.assertEqual(row_by_id[run_id][4], "printf")
        self.assertEqual(row_by_id[attached_id][1], "yes")
        self.assertLess(
            rows.index(row_by_id[run_id]), rows.index(row_by_id[attached_id])
        )

    def test_cli_new_interactive_over_real_ssh_attaches_and_cleans_state(self):
        remote_output = f"{REMOTE_STATE}/new-output"
        remote_rc = f"""printf 'new-ready\\n'
IFS= read -r sessh_test_continue
printf 'new:%s\\n' "$SESSH_REMOTE_RC"
printf 'new:%s\\n' "$SESSH_REMOTE_RC" > {remote_output}
exit 0
"""
        config = self._write_cli_config("cli-new", remote_rc=remote_rc)

        with OuterTmuxSession(self) as outer:
            outer.start_driver(["--config", str(config), *self.ssh_options, self.host])
            initial_tty_state = outer.wait_for_initial_tty_state()
            outer.wait_for_text("new-ready")
            outer.send_line("continue")
            exit_status = outer.wait_for_exit()
            final_tty_state = outer.wait_for_final_tty_state()
            lines = outer.terminal_lines()

        self.assertEqual(exit_status, 0)
        self.assertEqual(final_tty_state, initial_tty_state)
        resume_id = parse_boundary_resume_id(self, lines[0], "sessh created")
        self.assertEqual(
            lines,
            [
                f"--- sessh created {resume_id} ---",
                "new-ready",
                "continue",
                f"new:{REMOTE_STATE}/remote-rc",
                f"--- sessh exited {resume_id} ---",
            ],
        )
        self.assertEqual(
            self.client().run(["cat", remote_output]).stdout,
            f"new:{REMOTE_STATE}/remote-rc\n",
        )
        self.assertFalse(self._has_session(resume_id))
        self.client().run(["test", "!", "-d", f"{REMOTE_STATE}/sessions/{resume_id}"])

    def test_cli_attach_interactive_over_real_ssh_attaches_existing_session(self):
        remote_output = f"{REMOTE_STATE}/attach-output"
        continue_file = f"{REMOTE_STATE}/attach-continue"
        remote_rc = f"""printf 'attach-ready\\n'
while [ ! -f {continue_file} ]; do
  sleep 0.05
done
printf 'attach:%s\\n' "$SESSH_REMOTE_RC"
printf 'attach:%s\\n' "$SESSH_REMOTE_RC" > {remote_output}
exit 0
"""
        config = self._write_cli_config("cli-attach", remote_rc=remote_rc)

        with OuterTmuxSession(self) as outer:
            outer.start_driver(["--config", str(config), *self.ssh_options, self.host])
            outer.wait_for_text("attach-ready")
            outer.send_ssh_disconnect()
            self.assertEqual(outer.wait_for_exit(), 255)
            detached_lines = outer.terminal_lines()
        resume_id = parse_boundary_resume_id(self, detached_lines[0], "sessh created")
        self.assertTrue(self._has_session(resume_id))

        with OuterTmuxSession(self) as outer:
            outer.start_driver(
                [
                    "--config",
                    str(config),
                    *self.ssh_options,
                    self.host,
                    "attach",
                    resume_id,
                ]
            )
            outer.wait_for_text("attach-ready")
            self.client().run(["touch", continue_file])
            exit_status = outer.wait_for_exit()
            attached_lines = outer.terminal_lines()

        self.assertEqual(exit_status, 0)
        self.assertEqual(
            attached_lines,
            [
                f"--- sessh attached {resume_id} ---",
                "attach-ready",
                f"attach:{REMOTE_STATE}/remote-rc",
                f"--- sessh exited {resume_id} ---",
            ],
        )
        self.assertEqual(
            self.client().run(["cat", remote_output]).stdout,
            f"attach:{REMOTE_STATE}/remote-rc\n",
        )
        self.assertFalse(self._has_session(resume_id))
        self.client().run(["test", "!", "-d", f"{REMOTE_STATE}/sessions/{resume_id}"])

    def test_cli_attach_without_id_prompts_and_attaches_selected_session(self):
        remote_output = f"{REMOTE_STATE}/attach-picker-output"
        continue_file = f"{REMOTE_STATE}/attach-picker-continue"
        remote_rc = f"""printf 'picker-ready\\n'
while [ ! -f {continue_file} ]; do
  sleep 0.05
done
printf 'picker:%s\\n' "$SESSH_REMOTE_RC"
printf 'picker:%s\\n' "$SESSH_REMOTE_RC" > {remote_output}
exit 0
"""
        config = self._write_cli_config("cli-attach-picker", remote_rc=remote_rc)

        with OuterTmuxSession(self) as outer:
            outer.start_driver(["--config", str(config), *self.ssh_options, self.host])
            outer.wait_for_text("picker-ready")
            outer.send_ssh_disconnect()
            self.assertEqual(outer.wait_for_exit(), 255)
            detached_lines = outer.terminal_lines()
        resume_id = parse_boundary_resume_id(self, detached_lines[0], "sessh created")
        self.assertTrue(self._has_session(resume_id))

        with OuterTmuxSession(self) as outer:
            outer.start_driver(
                ["--config", str(config), *self.ssh_options, self.host, "attach"]
            )
            outer.wait_for_text("Attach session [1-1, default 1, q to cancel]:")
            outer.send_line("1")
            outer.wait_for_text("picker-ready")
            self.client().run(["touch", continue_file])
            exit_status = outer.wait_for_exit()
            attached_lines = outer.terminal_lines()
            raw_capture = outer.capture()

        self.assertEqual(exit_status, 0)
        self.assertEqual(raw_capture.find("\x1b]sessh;"), -1)
        attached_boundary_index = attached_lines.index(
            f"--- sessh attached {resume_id} ---"
        )
        self.assertEqual(
            attached_lines[attached_boundary_index:],
            [
                f"--- sessh attached {resume_id} ---",
                "picker-ready",
                f"picker:{REMOTE_STATE}/remote-rc",
                f"--- sessh exited {resume_id} ---",
            ],
        )
        self.assertEqual(
            self.client().run(["cat", remote_output]).stdout,
            f"picker:{REMOTE_STATE}/remote-rc\n",
        )
        self.assertFalse(self._has_session(resume_id))
        self.client().run(["test", "!", "-d", f"{REMOTE_STATE}/sessions/{resume_id}"])

    def test_cli_transport_disconnect_prints_detached_boundary_and_attach_command(self):
        remote_rc = """printf 'detach-ready\\n'
while :; do
  sleep 1
done
"""
        config = self._write_cli_config("cli-detach", remote_rc=remote_rc)

        with OuterTmuxSession(self) as outer:
            outer.start_driver(["--config", str(config), *self.ssh_options, self.host])
            outer.wait_for_text("detach-ready")
            outer.send_ssh_disconnect()
            exit_status = outer.wait_for_exit()
            lines = outer.terminal_lines()

        self.assertEqual(exit_status, 255)
        resume_id = parse_boundary_resume_id(self, lines[0], "sessh created")
        self.assertEqual(
            lines,
            [
                f"--- sessh created {resume_id} ---",
                "detach-ready",
                f"--- sessh detached {resume_id} ---",
                "To attach to this session, run:",
                f"  sessh {self.host} attach {resume_id}",
            ],
        )

    def test_cli_restores_local_tty_when_ssh_process_is_killed(self):
        remote_rc = """printf 'tty-restore-ready\\n'
while :; do
  sleep 1
done
"""
        config = self._write_cli_config("cli-tty-restore", remote_rc=remote_rc)

        with OuterTmuxSession(self) as outer:
            outer.start_driver(["--config", str(config), *self.ssh_options, self.host])
            initial_tty_state = outer.wait_for_initial_tty_state()
            outer.wait_for_text("tty-restore-ready")
            driver_pid = outer.wait_for_driver_pid()
            ssh_pid = wait_for_child_process(self, driver_pid, "ssh")
            attached_tty_state = outer.current_tty_state()
            self.assertNotEqual(attached_tty_state, initial_tty_state)

            os.kill(ssh_pid, signal.SIGKILL)
            exit_status = outer.wait_for_exit()
            final_tty_state = outer.wait_for_final_tty_state()

        self.assertNotEqual(exit_status, 0)
        self.assertEqual(final_tty_state, initial_tty_state)

    def test_cli_run_clean_detach_prints_run_detached_boundary_and_attach_command(self):
        config = self._write_cli_config("cli-run-detach")

        with OuterTmuxSession(self) as outer:
            outer.start_driver(
                [
                    "--config",
                    str(config),
                    *self.ssh_options,
                    self.host,
                    "run",
                    "sh",
                    "-c",
                    "printf 'run-detach-ready\\n'; while :; do sleep 1; done",
                ]
            )
            initial_tty_state = outer.wait_for_initial_tty_state()
            outer.wait_for_text("run-detach-ready")
            resume_id = find_boundary_resume_id(
                self, outer.terminal_lines(), "sessh created"
            )
            self.client().run(
                [
                    "tmux",
                    "-S",
                    f"{REMOTE_STATE}/sockets/tmux.sock",
                    "detach-client",
                    "-s",
                    f"sessh-{resume_id}",
                ]
            )
            exit_status = outer.wait_for_exit()
            final_tty_state = outer.wait_for_final_tty_state()
            lines = outer.terminal_lines()

        self.assertEqual(exit_status, 1)
        self.assertEqual(final_tty_state, initial_tty_state)
        self.assertEqual(
            lines,
            [
                f"--- sessh created {resume_id} ---",
                "run-detach-ready",
                f"--- sessh detached {resume_id} ---",
                "Run session is still active. To inspect it, run:",
                f"  sessh {self.host} attach {resume_id}",
            ],
        )
        self.assertTrue(self._has_session(resume_id))

    @classmethod
    def _container_port(cls) -> str:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = subprocess.run(
                ["podman", "port", cls.container, "22/tcp"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip().rsplit(":", 1)[1]
            time.sleep(0.1)
        raise RuntimeError("timed out waiting for podman port")

    @classmethod
    def _wait_for_ssh(cls) -> None:
        command = ["ssh", *cls.ssh_options, cls.host, "true"]
        deadline = time.monotonic() + 30
        last_stderr = ""
        while time.monotonic() < deadline:
            result = subprocess.run(
                command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            if result.returncode == 0:
                return
            last_stderr = result.stderr
            time.sleep(0.25)
        raise RuntimeError(f"timed out waiting for ssh: {last_stderr}")

    def client(self):
        return SshClient(host=self.host, ssh_options=self.ssh_options)

    def _reset_remote_state(self):
        client = self.client()
        client.run(
            ["tmux", "-S", f"{REMOTE_STATE}/sockets/tmux.sock", "kill-server"],
            check=False,
            stderr=subprocess.PIPE,
        )
        client.run(["rm", "-rf", REMOTE_STATE], check=False, stderr=subprocess.PIPE)

    def _has_session(self, resume_id):
        result = self.client().run(
            [
                "tmux",
                "-S",
                f"{REMOTE_STATE}/sockets/tmux.sock",
                "-f",
                f"{REMOTE_STATE}/tmux.conf",
                "has-session",
                "-t",
                f"sessh-{resume_id}",
            ],
            check=False,
            stderr=subprocess.PIPE,
        )
        return result.returncode == 0

    def _write_cli_config(
        self, name, *, remote_init="", remote_rc=None, history_limit=200
    ):
        config = self.root / f"{name}.yaml"
        content = f"defaults:\n  shell: bash\n  history-limit: {history_limit}\n"
        content += yaml_literal("remote-init", remote_init)
        if remote_rc is not None:
            content += yaml_literal("remote-rc", remote_rc)
        config.write_text(content, encoding="utf-8")
        return config


def yaml_literal(key, value):
    lines = value.splitlines()
    if not lines:
        return f'{key}: ""\n'
    return f"{key}: |\n" + "".join(f"  {line}\n" for line in lines)


def parse_boundary_resume_id(testcase, line, label):
    prefix = f"--- {label} "
    suffix = " ---"
    testcase.assertTrue(line.startswith(prefix), line)
    testcase.assertTrue(line.endswith(suffix), line)
    return line[len(prefix) : -len(suffix)]


def find_boundary_resume_id(testcase, lines, label):
    prefix = f"--- {label} "
    matching_lines = [line for line in lines if line.startswith(prefix)]
    testcase.assertEqual(len(matching_lines), 1, lines)
    return parse_boundary_resume_id(testcase, matching_lines[0], label)


def wait_for_child_process(testcase, parent_pid, command_basename, *, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        matching_pids = [
            pid
            for pid, ppid, command in local_processes()
            if ppid == parent_pid and Path(command).name == command_basename
        ]
        if matching_pids:
            return matching_pids[0]
        time.sleep(0.05)
    testcase.fail(
        f"timed out waiting for child process {command_basename!r} of pid {parent_pid}"
    )


def local_processes():
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,comm="],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    processes = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        pid, ppid, command = fields
        processes.append((int(pid), int(ppid), command))
    return processes


class OuterTmuxSession:
    def __init__(self, testcase, *, width=120, height=24, history_limit=4000):
        self.testcase = testcase
        self.width = width
        self.height = height
        self.history_limit = history_limit
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.socket = self.root / "tmux.sock"
        self.config = self.root / "tmux.conf"
        self.status_file = self.root / "driver-status"
        self.driver_pid_file = self.root / "driver-pid"
        self.initial_tty_state_file = self.root / "initial-tty-state"
        self.final_tty_state_file = self.root / "final-tty-state"
        self.session = f"sessh-outer-{uuid.uuid4().hex[:10]}"
        self.target = f"{self.session}:0.0"
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

    def close(self):
        self._tmux("kill-server", check=False)
        self.tmp.cleanup()

    def start_driver(self, argv):
        driver = self.root / "driver.py"
        driver.write_text(
            f"""import os
import sys
from pathlib import Path

from sessh.cli import main

Path({str(self.driver_pid_file)!r}).write_text(str(os.getpid()), encoding="utf-8")
sys.exit(main({list(argv)!r}))
""",
            encoding="utf-8",
        )
        python_command = (
            f"PYTHONPATH={shlex.quote(str(SRC_DIR))}${{PYTHONPATH:+:$PYTHONPATH}} "
            f"{shlex.quote(sys.executable)} {shlex.quote(str(driver))}"
        )
        command = (
            f"stty -g > {shlex.quote(str(self.initial_tty_state_file))}; "
            f"{python_command}; "
            "sessh_driver_status=$?; "
            f"stty -g > {shlex.quote(str(self.final_tty_state_file))}; "
            f"printf '%s\\n' \"$sessh_driver_status\" > {shlex.quote(str(self.status_file))}; "
            "printf '\\n__SESSH_DRIVER_DONE__=%s\\n' \"$sessh_driver_status\"; "
            "sleep 3600"
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
            "-c",
            str(REPO_ROOT),
            command,
        )

    def wait_for_driver_pid(self, *, timeout=30):
        return int(self._wait_for_file(self.driver_pid_file, timeout=timeout))

    def wait_for_initial_tty_state(self, *, timeout=30):
        return self._wait_for_file(self.initial_tty_state_file, timeout=timeout)

    def wait_for_final_tty_state(self, *, timeout=30):
        return self._wait_for_file(self.final_tty_state_file, timeout=timeout)

    def current_tty_state(self):
        tty = self._tmux(
            "display-message", "-p", "-t", self.target, "#{pane_tty}"
        ).stdout.strip()
        return stty_state_for_tty(tty)

    def _wait_for_file(self, path, *, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists():
                return path.read_text(encoding="utf-8").strip()
            time.sleep(0.05)
        self.testcase.fail(f"timed out waiting for {path}:\n{self.capture()}")

    def wait_for_text(self, text, *, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            capture = self.capture()
            if text in capture:
                return
            time.sleep(0.05)
        self.testcase.fail(
            f"timed out waiting for {text!r} in outer tmux pane:\n{self.capture()}"
        )

    def wait_for_exit(self, *, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.status_file.exists():
                return int(self.status_file.read_text(encoding="utf-8").strip())
            time.sleep(0.05)
        self.testcase.fail(
            f"timed out waiting for sessh driver to exit:\n{self.capture()}"
        )

    def send_line(self, text):
        self._tmux("send-keys", "-t", self.target, "-l", text)
        self._tmux("send-keys", "-t", self.target, "Enter")

    def send_ssh_disconnect(self):
        self._tmux("send-keys", "-t", self.target, "Enter")
        self._tmux("send-keys", "-t", self.target, "-l", "~.")

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

    def terminal_lines(self):
        return terminal_lines(self.capture())

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


def stty_state_for_tty(tty):
    commands = [
        ["stty", "-g", "-f", tty],
        ["stty", "-g", "-F", tty],
        ["sh", "-c", f"stty -g < {shlex.quote(tty)}"],
    ]
    errors = []
    for command in commands:
        result = subprocess.run(
            command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        if result.returncode == 0:
            return result.stdout.strip()
        errors.append(f"{command!r}: {result.stderr.strip()}")
    raise RuntimeError("failed to read tty state:\n" + "\n".join(errors))


def terminal_lines(text):
    lines = []
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if not line.strip():
            continue
        if line.startswith("__SESSH_DRIVER_DONE__="):
            continue
        if line.startswith("sessh: connecting to "):
            continue
        if line.startswith("sessh: starting session "):
            continue
        if line.startswith("sessh: starting run session "):
            continue
        if line.startswith("sessh: attaching session "):
            continue
        if line.startswith("sessh: selecting session"):
            continue
        lines.append(line)
    return lines


if __name__ == "__main__":
    unittest.main()
