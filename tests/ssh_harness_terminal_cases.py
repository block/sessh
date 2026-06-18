from ssh_harness_common import *
from ssh_harness_transport_cases import *
from ssh_harness_proxy_cases import *

def test_ssh_remote_command_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "hello\n":
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "sessh-proxy" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_sessh_host_list_is_remote_command(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_bin = tmp / "remote-bin"
    remote_list = remote_bin / "list"
    write_fake_ssh(fake_bin / "ssh")
    remote_bin.mkdir()
    remote_list.write_text("#!/bin/sh\nprintf 'REMOTE_LIST\\n'\n")
    remote_list.chmod(remote_list.stat().st_mode | stat.S_IXUSR)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_PATH"] = str(remote_bin)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "list"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "REMOTE_LIST\n":
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_remote_command=list" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_remote_command_option_after_host_is_remote_arg(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_bin = tmp / "remote-bin"
    remote_rsync = remote_bin / "rsync"
    write_fake_ssh(fake_bin / "ssh")
    remote_bin.mkdir()
    remote_rsync.write_text(
        "#!/bin/sh\n"
        "if [ \"${1:-}\" = \"--version\" ]; then\n"
        "  printf 'REMOTE_RSYNC_VERSION\\n'\n"
        "else\n"
        "  printf 'REMOTE_RSYNC_ARGS:%s\\n' \"$*\"\n"
        "fi\n"
    )
    remote_rsync.chmod(remote_rsync.stat().st_mode | stat.S_IXUSR)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_PATH"] = str(remote_bin)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "rsync", "--version"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "REMOTE_RSYNC_VERSION\n":
        raise AssertionError(result)
    if "sessh " in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_remote_command_stream_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "printf 'EXIT_STATUS_STDOUT\\n'; exit 7"], env, timeout=5.0)

    if result.returncode != 7:
        raise AssertionError(result)
    if result.stdout != "EXIT_STATUS_STDOUT\n":
        raise AssertionError(result)


def test_ssh_remote_command_stream_waits_for_exit_status_after_output_eof(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["test-host", "exec >/dev/null 2>/dev/null; sleep 0.2; exit 9"], env, timeout=5.0)

    if result.returncode != 9:
        raise AssertionError(result)
    if result.stdout or result.stderr:
        raise AssertionError(result)


def test_ssh_remote_command_stream_preserves_stderr_channel(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(
        ["test-host", "printf 'STDOUT\\n'; printf 'STDERR\\n' >&2"],
        env,
        timeout=5.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "STDOUT\n":
        raise AssertionError(result)
    if result.stderr != "STDERR\n":
        raise AssertionError(result)


def test_ssh_tty_stdin_remote_command_does_not_allocate_tty_without_t(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["test-host", "tty"],
        env,
        ((b"not a tty", None),),
        timeout=10.0,
    )

    if result.returncode != 1:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_tty_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["-t", "test-host", "exit 67"],
        env,
        (),
        timeout=10.0,
    )

    if result.returncode != 67:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_tty_propagates_resize(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = "printf 'READY:%s\\n' \"$(stty size)\"; IFS= read -r _; printf 'RESIZED:%s\\n' \"$(stty size)\""
    result = run_sessh_in_pty(
        ["-t", "test-host", command],
        env,
        (
            (b"READY:24 100", resize_pty_then_send(31, 120, b"\n")),
            (b"RESIZED:31 120", None),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_remote_command_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["--no-terminal-emulator", "test-host", "echo", "hello"], env, timeout=5.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if result.stdout != "hello\n":
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_remote_command_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["--no-terminal-emulator", "test-host", "exit 11"], env, timeout=5.0)

    if result.returncode != 11:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", "exit 13"],
        env,
        (),
        timeout=10.0,
    )

    if result.returncode != 13:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_propagates_resize(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = "printf 'READY:%s\\n' \"$(stty size)\"; IFS= read -r _; printf 'RESIZED:%s\\n' \"$(stty size)\""
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
        env,
        (
            (b"READY:24 100", resize_pty_then_send(32, 121, b"\n")),
            (b"RESIZED:32 121", None),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_forced_tty_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "/dev/" not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_requested_tty_uses_stream_path(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_interleaved_tty_and_no_terminal_emulator_preserves_exit_status(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["-t", "--no-terminal-emulator", "test-host", "exit 3"],
        env,
        (),
        timeout=10.0,
    )

    if result.returncode != 3:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_false_config_uses_stream_path(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "terminal-emulator=false\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_cli_overrides_disabled_config(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "terminal-emulator=no\n")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--terminal-emulator", "-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_command_in_tty_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "test-host", "echo", "hello"],
        env,
        ((b"hello", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_tty_uses_emulated_term_not_outer_term(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["TERM"] = "ansi"
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["-tt", "test-host", "printf '%s\\n' \"$TERM\""],
        env,
        ((b"xterm-256color", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "ansi" in result.stdout:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_copies_outer_term(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["TERM"] = "ansi"
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", "printf '%s\\n' \"$TERM\""],
        env,
        ((b"ansi", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_copies_local_tty_modes(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = (
        "tokens=$(stty -a | tr ' ;' '\\n\\n'); "
        "printf '%s\\n' \"$tokens\" | grep -x -- -echo >/dev/null && "
        "printf '%s\\n' \"$tokens\" | grep -x -- -icanon >/dev/null && "
        "printf '%s\\n' \"$tokens\" | grep -x -- -icrnl >/dev/null && "
        "printf 'REMOTE_TTY_MODES\\r\\n' || { stty -a; exit 7; }"
    )
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
        env,
        ((b"REMOTE_TTY_MODES", None),),
        timeout=10.0,
        child_tty_setup=set_no_terminal_emulator_tty_mode_probe,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_copies_local_output_modes(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = (
        "tokens=$(stty -a | tr ' ;' '\\n\\n'); "
        "printf '%s\\n' \"$tokens\" | grep -x -- -opost >/dev/null && "
        "printf 'REMOTE_OUTPUT_MODES\\r\\n' || { stty -a; exit 7; }"
    )
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
        env,
        ((b"REMOTE_OUTPUT_MODES", None),),
        timeout=10.0,
        child_tty_setup=set_no_terminal_emulator_output_mode_probe,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_tty_sets_ssh_tty(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = "test -n \"${SSH_TTY:-}\" && test -c \"$SSH_TTY\" && printf 'SSH_TTY_OK\\r\\n'"
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
        env,
        ((b"SSH_TTY_OK", None),),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_interactive_shell_keeps_prompt_aligned(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_shell = tmp / "fake-remote-shell"
    write_fake_ssh(fake_bin / "ssh")
    fake_shell.write_text(
        "#!/bin/sh\n"
        "printf 'REMOTE_PROMPT\\n%% '\n"
        "while IFS= read -r line; do\n"
        "  case \"$line\" in\n"
        "    'echo hello') printf 'hello\\nREMOTE_PROMPT\\n%% ' ;;\n"
        "    exit) exit 0 ;;\n"
        "    *) printf 'UNKNOWN:%s\\nREMOTE_PROMPT\\n%% ' \"$line\" ;;\n"
        "  esac\n"
        "done\n"
    )
    fake_shell.chmod(fake_shell.stat().st_mode | stat.S_IXUSR)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_SHELL"] = str(fake_shell)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "test-host"],
        env,
        (
            (b"REMOTE_PROMPT\r\n% ", b"echo hello\n"),
            (b"hello\r\nREMOTE_PROMPT\r\n% ", b"exit\n"),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "REMOTE_PROMPT\n% " in result.stdout:
        raise AssertionError(result)


def test_ssh_no_terminal_emulator_release_artifact_restores_local_tty_on_exit(tmp):
    artifact = local_artifact()
    if not artifact.exists():
        print(f"SKIP release artifact tty restore test; missing {artifact}", file=sys.stderr)
        return

    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_shell = tmp / "fake-remote-shell"
    write_fake_ssh(fake_bin / "ssh")
    fake_shell.write_text(
        "#!/bin/sh\n"
        "printf 'REMOTE_READY\\n%% '\n"
        "while IFS= read -r line; do\n"
        "  case \"$line\" in\n"
        "    exit) exit 0 ;;\n"
        "    *) printf 'REMOTE_READY\\n%% ' ;;\n"
        "  esac\n"
        "done\n"
    )
    fake_shell.chmod(fake_shell.stat().st_mode | stat.S_IXUSR)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_REMOTE_SHELL"] = str(fake_shell)
    seed_remote_artifact_cache(env, artifact)

    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "test-host"],
        env,
        ((b"REMOTE_READY\r\n% ", b"exit\n"),),
        timeout=10.0,
        binary=artifact,
        capture_tty_attrs=True,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if result.tty_attrs_before != result.tty_attrs_after:
        raise AssertionError(
            "no-terminal-emulator release artifact did not restore local tty modes\n"
            f"before: {tty_attr_summary(result.tty_attrs_before)}\n"
            f"after:  {tty_attr_summary(result.tty_attrs_after)}\n"
            f"output: {result.stdout!r}"
        )


def test_ssh_terminal_emulator_release_artifact_restores_local_tty_on_exit(tmp):
    artifact = local_artifact()
    if not artifact.exists():
        print(f"SKIP release artifact tty restore test; missing {artifact}", file=sys.stderr)
        return

    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env, artifact)

    result = run_sessh_in_pty(
        ["-t", "test-host", "printf 'TERMINAL_EMULATOR_READY\\n'; exit 0"],
        env,
        ((b"TERMINAL_EMULATOR_READY", None),),
        timeout=10.0,
        binary=artifact,
        capture_tty_attrs=True,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if result.tty_attrs_before != result.tty_attrs_after:
        raise AssertionError(
            "terminal-emulator release artifact did not restore local tty modes\n"
            f"before: {tty_attr_summary(result.tty_attrs_before)}\n"
            f"after:  {tty_attr_summary(result.tty_attrs_after)}\n"
            f"output: {result.stdout!r}"
        )


def test_ssh_requested_tty_with_piped_stdout_does_not_emit_local_cleanup(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = "/bin/sh"

    result = run_sessh_with_tty_stdin_and_piped_stdout(
        ["-t", "test-host", "printf 'remote-sessh\\n'"],
        env,
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "remote-sessh" not in result.stdout:
        raise AssertionError(result)
    for leaked in ("\x1b]2;", str(ROOT)):
        if leaked in result.stdout:
            raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)
    if "--filter-level" not in log_text or "unhygienic" not in log_text:
        raise AssertionError(log_text)


def test_ssh_no_terminal_emulator_tty_uses_proxy_with_hygienic_diagnostics(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    command = "printf 'NO_TERMINAL_EMULATOR_READY\\r\\n'; exit 255"
    result = run_sessh_in_pty(
        ["--no-terminal-emulator", "-tt", "test-host", command],
        env,
        (
            (b"NO_TERMINAL_EMULATOR_READY", None),
        ),
        timeout=30.0,
    )

    if result.returncode != 255:
        raise AssertionError(result)
    combined = result.stdout + result.stderr
    if "sessh: disconnected:" in combined:
        raise AssertionError(result)
    if "CTRL-C" in combined:
        raise AssertionError(result)
    if "CTRL-R" in combined:
        raise AssertionError(result)
    if title_sequence("10sec retry CTRL-R") in combined:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)
    if "--filter-level" not in log_text or "hygienic" not in log_text:
        raise AssertionError(log_text)
    if "--diagnostics-guid" not in log_text or "p-" not in log_text:
        raise AssertionError(log_text)
    if "--client-ctrl-r" not in log_text or ("'1'" not in log_text and " 1" not in log_text):
        raise AssertionError(log_text)


def test_ssh_terminal_emulator_tty_escape_doubled_tilde(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh_in_pty(
        ["-tt", "test-host", "printf 'TILDE_READY\\n'; IFS= read -r line; printf 'LINE:%s\\n' \"$line\""],
        env,
        (
            (b"TILDE_READY", b"~~hello\n"),
            (b"LINE:~hello", None),
        ),
        timeout=10.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "LINE:~~hello" in result.stdout:
        raise AssertionError(result)


def test_ssh_terminal_emulator_tty_escape_help_modal_repaints(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    argv = [
        str(BIN),
        "-tt",
        "test-host",
        "printf 'HELP_READY\\n'; while IFS= read -r line; do printf 'REMOTE:%s\\n' \"$line\"; done",
    ]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execvpe(argv[0], argv, env)

    output = b""
    waited = False
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        output = read_pty_until(fd, output, b"HELP_READY", 10.0)
        os.write(fd, b"\r~?")
        output = read_pty_until(fd, output, b"Any key to dismiss", 10.0)
        output = read_pty_until(fd, output, b"~.  disconnect", 10.0)
        output = read_pty_until(fd, output, b"~p  repaint", 10.0)
        os.write(fd, b"ignored\n")
        output = read_pty_until_count(fd, output, b"HELP_READY", 2, 10.0)
        os.write(fd, b"after\n")
        output = read_pty_until(fd, output, b"REMOTE:after", 10.0)
        os.write(fd, b"~.")

        deadline = time.monotonic() + 10.0
        while True:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                waited = True
                returncode = wait_status_to_returncode(status)
                output += read_available_pty(fd)
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timed out waiting for pty command to exit; got {output!r}")
            ready, _, _ = select.select([fd], [], [], min(remaining, 0.05))
            if ready:
                output += read_available_pty(fd)
    finally:
        if not waited:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        os.close(fd)

    result = subprocess.CompletedProcess(argv, returncode, output.decode("utf-8", "replace"), "")
    if result.returncode != 0:
        raise AssertionError(result)
    if "REMOTE:ignored" in result.stdout:
        raise AssertionError(result)


def test_ssh_forced_tty_remote_command_allocates_pty_with_stdin_null(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)

    result = run_sessh(["-tt", "test-host", "tty"], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if "/dev/" not in result.stdout:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text or "plain_ssh=1" in log_text:
        raise AssertionError(log_text)
    trace_text = fake_trace.read_text()
    runtime_invocation = re.search(r"event=parsed .*config_query=0 .*request_tty=1", trace_text)
    if runtime_invocation is None:
        raise AssertionError(trace_text)


def test_ssh_requested_tty_remote_command_allocates_pty_with_tty_stdin(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    result = run_sessh_in_pty(
        ["-t", "test-host", "tty"],
        env,
        ((b"/dev/", None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "/dev/" not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)

def test_ssh_single_requested_tty_remote_command_with_stdin_null_uses_proxy_stream(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    seed_remote_artifact_cache(env)

    result = run_sessh(["-t", "test-host", "tty"], env, timeout=5.0)

    if result.returncode != 1:
        raise AssertionError(result)
    if "not a tty" not in result.stdout:
        raise AssertionError(result)
    if "fallback to plain-ssh" in result.stderr:
        raise AssertionError(result.stderr)
    log_text = fake_log.read_text()
    if "proxy_ssh=1" not in log_text:
        raise AssertionError(log_text)
    if "plain_ssh=1" in log_text:
        raise AssertionError(log_text)


def test_ssh_tty_empty_remote_command_starts_interactive_session(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "INTERACTIVE_EMPTY_COMMAND_READY"
    remote_shell.write_text(
        "#!/bin/sh\n"
        "if [ \"${1-}\" = -c ]; then\n"
        "  printf 'UNEXPECTED_SHELL_COMMAND:%s\\n' \"${2-}\"\n"
        "  exit 9\n"
        "fi\n"
        f"printf '{marker}\\n'\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)
    env["SESSH_FAKE_SSH_REMOTE_SHELL"] = str(remote_shell)

    result = run_sessh(["-tt", "test-host", ""], env, timeout=30.0)

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout or "UNEXPECTED_SHELL_COMMAND" in result.stdout:
        raise AssertionError(result)


def test_ssh_tty_quoted_empty_remote_command_uses_shell_eval(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    remote_shell.write_text(
        "#!/bin/sh\n"
        "if [ \"${1-}\" = -c ]; then\n"
        "  printf 'SHELL_COMMAND:%s\\n' \"${2-}\"\n"
        "  exit 7\n"
        "fi\n"
        "printf 'UNEXPECTED_INTERACTIVE\\n'\n"
    )
    remote_shell.chmod(0o700)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh(["-tt", "test-host", '""'], env, timeout=30.0)

    if result.returncode != 7:
        raise AssertionError(result)
    if 'SHELL_COMMAND:""' not in result.stdout or "UNEXPECTED_INTERACTIVE" in result.stdout:
        raise AssertionError(result)


def test_ssh_config_only_cli_options_are_rejected(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)

    for args in (
        ["--scrollback-limit", "100", "test-host"],
        ["--bootstrap", "test-host"],
        ["--no-bootstrap", "test-host"],
        ["--ssh-options", "-F cfg", "test-host"],
    ):
        result = run_sessh(args, env, timeout=5.0)
        if result.returncode != 64:
            raise AssertionError((args, result))
        if "unsupported sessh option" not in result.stderr:
            raise AssertionError((args, result.stderr))
    if fake_log.exists():
        raise AssertionError(fake_log.read_text())


def test_ssh_bootstrap_false_config_uses_remote_path_sessh(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    remote_shell = tmp / "remote-shell"
    marker = "SSH_NO_BOOTSTRAP_CONFIG_READY"
    remote_shell.write_text(f"#!/bin/sh\nprintf '{marker}\\n'\n")
    remote_shell.chmod(0o700)
    config_dir = Path(env["XDG_CONFIG_HOME"]) / "sessh"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "sessh.env").write_text("bootstrap=false\n")
    write_fake_ssh(fake_bin / "ssh")
    (fake_bin / "sessh").write_text(
        "#!/bin/sh\n"
        "printf 'direct_broker=1\\n' >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "printf 'direct_broker_argc=%s\\n' \"$#\" >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "i=1\n"
        "for arg in \"$@\"; do\n"
        "  printf 'direct_broker_arg%s=%s\\n' \"$i\" \"$arg\" >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "  i=$((i + 1))\n"
        "done\n"
        f"exec {shlex.quote(str(BIN))} \"$@\"\n"
    )
    (fake_bin / "sessh").chmod(0o700)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SHELL"] = str(remote_shell)

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        ((marker.encode("utf-8"), None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if marker not in result.stdout:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "direct_broker=1" not in log_text:
        raise AssertionError(log_text)
    if "direct_broker_argc=1" not in log_text or "direct_broker_arg1=:broker:" not in log_text:
        raise AssertionError(log_text)
    if "bootstrapper=1" in log_text:
        raise AssertionError(log_text)
    cached = artifact_cache_path(env, remote_path_artifact())
    if cached.exists():
        raise AssertionError(f"bootstrap=false: cached artifact should not be created at {cached}")


def test_ssh_version_mismatch_fallback_message_is_precise(tmp):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    write_fake_ssh(fake_bin / "ssh")
    write_sessh_config(env, "bootstrap=false\n")
    (fake_bin / "sessh").write_text(
        "#!/bin/sh\n"
        "printf 'direct_broker=1\\n' >>\"$SESSH_FAKE_SSH_LOG\"\n"
        "python3 - <<'PY'\n"
        "import struct, sys\n"
        "\n"
        "def varint(value):\n"
        "    out = bytearray()\n"
        "    while value >= 0x80:\n"
        "        out.append((value & 0x7f) | 0x80)\n"
        "        value >>= 7\n"
        "    out.append(value)\n"
        "    return bytes(out)\n"
        "\n"
        "def bytes_field(number, data):\n"
        "    return varint((number << 3) | 2) + varint(len(data)) + data\n"
        "\n"
        "error = bytes_field(1, b'VERSION_MISMATCH') + bytes_field(2, b'sesshd is incompatible with this client')\n"
        "frame = bytes_field(3, error)\n"
        "sys.stdout.buffer.write(struct.pack('>I', len(frame)) + frame)\n"
        "sys.stdout.buffer.flush()\n"
        "PY\n"
    )
    (fake_bin / "sessh").chmod(0o700)
    env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_ALLOW_PLAIN"] = "1"

    result = run_sessh_in_pty(
        ["test-host"],
        env,
        ((b"PLAIN_SSH host=test-host", None),),
        timeout=30.0,
    )

    if result.returncode != 0:
        raise AssertionError(result)
    if "PLAIN_SSH host=test-host" not in result.stdout:
        raise AssertionError(result)
    combined_output = result.stdout + result.stderr
    if "existing remote sessh is incompatible" not in combined_output:
        raise AssertionError(result)
    if "falling back to plain ssh without persistence" not in combined_output:
        raise AssertionError(result)
    if "no matching sessh binary" in combined_output or "unsupported" in combined_output:
        raise AssertionError(result)
    log_text = fake_log.read_text()
    if "direct_broker=1" not in log_text or "plain_ssh=1" not in log_text:
        raise AssertionError(log_text)

