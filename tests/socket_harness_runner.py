#!/usr/bin/env python3
from socket_harness_common import *
from socket_harness_daemon_cases import *
from socket_harness_protocol_cases import *
from socket_harness_reconnect_cases import *

def main():
    if not BIN.exists():
        raise SystemExit(f"missing binary: {BIN}")

    with tempfile.TemporaryDirectory(prefix="sessh-harness-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        env["SHELL"] = "/bin/sh"
        cleanup_runtime(env)

        try:
            help_text = run(["--help"], env, timeout=5.0)
            if help_text.returncode != 0 or "sessh [ssh-option" not in help_text.stdout:
                raise AssertionError(help_text)
            version_text = run(["--version"], env, timeout=5.0)
            if version_text.returncode != 0 or version_text.stdout != f"sessh {sessh_version()}\n":
                raise AssertionError(version_text)
            short_help_text = run(["-h"], env, timeout=5.0)
            if short_help_text.returncode != 0 or short_help_text.stdout != help_text.stdout:
                raise AssertionError(short_help_text)
            sessh_wrapper = ROOT / "zig-out" / "bin" / "sessh"
            release_artifact_dir = ROOT / "zig-out" / "libexec" / "sessh"
            if sessh_wrapper.exists() and release_artifact_dir.exists() and any(release_artifact_dir.glob("*/sessh")):
                sessh_help = subprocess.run(
                    [str(sessh_wrapper), "--help"],
                    cwd=ROOT,
                    env=env,
                    text=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                    check=False,
                )
                if sessh_help.returncode != 0 or "sessh [ssh-option" not in sessh_help.stdout:
                    raise AssertionError(sessh_help)
                sessh_version_text = subprocess.run(
                    [str(sessh_wrapper), "--version"],
                    cwd=ROOT,
                    env=env,
                    text=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                    check=False,
                )
                if sessh_version_text.returncode != 0 or sessh_version_text.stdout != f"sessh {sessh_version()}\n":
                    raise AssertionError(sessh_version_text)
                sessh_short_version_text = subprocess.run(
                    [str(sessh_wrapper), "-V"],
                    cwd=ROOT,
                    env=env,
                    text=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                    check=False,
                )
                if sessh_short_version_text.returncode != 0 or sessh_short_version_text.stdout != f"sessh {sessh_version()}\n":
                    raise AssertionError(sessh_short_version_text)
                sessh_artifact = platform_wrapper_executable(sessh_wrapper, "sessh").resolve(strict=False)
                expected_socket = runtime_root(env) / daemon_socket_dir_name_for_executable(sessh_artifact) / "sesshd.sock"
                cleanup_runtime(env)
                proc = subprocess.Popen(
                    [str(sessh_wrapper), ":daemon:"],
                    cwd=ROOT,
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                try:
                    wait_file(expected_socket)
                    for role_name in (
                        "sesshd",
                        "sessh-bridge",
                        "sessh-proxy",
                        "sessh-terminal-remote",
                        "sessh-proxy-remote",
                    ):
                        role_path = runtime_root(env) / daemon_socket_dir_name_for_executable(sessh_artifact) / role_name
                        if not role_path.is_symlink() or Path(os.readlink(role_path)) != sessh_artifact:
                            raise AssertionError(f"{role_path} is not a symlink to {sessh_artifact}")
                    actual_name = process_command_basename(proc.pid)
                    if actual_name != "sesshd":
                        raise AssertionError(f"{sessh_wrapper} daemon exec name was {actual_name!r}, expected 'sesshd'")
                    proc.wait(timeout=5.0)
                    if proc.returncode != 0:
                        raise AssertionError(proc.stderr.read().decode("utf-8", "replace"))
                finally:
                    if proc.poll() is None:
                        proc.terminate()
                        try:
                            proc.wait(timeout=2.0)
                        except subprocess.TimeoutExpired:
                            proc.kill()
                            proc.wait(timeout=2.0)
                    cleanup_runtime(env)
                cleanup_runtime(env)
                log_proc = subprocess.Popen(
                    [str(sessh_wrapper), "--daemon-log"],
                    cwd=ROOT,
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                try:
                    read_until_pipe(log_proc.stdout, b"daemon log subscribed")
                    daemon_path = runtime_root(env) / daemon_socket_dir_name_for_executable(sessh_artifact) / "sesshd"
                    daemon_command = wait_process_command_containing(str(daemon_path))
                    if Path(daemon_command.split()[0]).name != "sesshd":
                        raise AssertionError(f"auto-started daemon command was {daemon_command!r}")
                    for role_name in (
                        "sessh-bridge",
                        "sessh-proxy",
                        "sessh-terminal-remote",
                        "sessh-proxy-remote",
                    ):
                        role_path = runtime_root(env) / daemon_socket_dir_name_for_executable(sessh_artifact) / role_name
                        if not role_path.is_symlink() or Path(os.readlink(role_path)) != sessh_artifact:
                            raise AssertionError(f"{role_path} is not a symlink to {sessh_artifact}")
                finally:
                    if log_proc.poll() is None:
                        log_proc.terminate()
                        try:
                            log_proc.wait(timeout=2.0)
                        except subprocess.TimeoutExpired:
                            log_proc.kill()
                            log_proc.wait(timeout=2.0)
                    cleanup_runtime(env)

            run_login_shell_profile_test(env)
            run_daemon_ping_test(env)
            run_daemon_concurrent_start_test(env)
            run_daemon_exits_after_stale_cleanup_record_test(env)
            run_daemon_log_stale_cleanup_record_test(env)
            run_daemon_log_test(env)
            run_daemon_log_namespace_env_test(env)
            run_daemon_log_session_lifecycle_test(env)
            run_daemon_log_mux_session_lifecycle_test(env)
            run_daemon_log_mux_session_in_daemon_worker_test(env)
            run_session_create_command_argv_test(env)
            run_session_create_shell_command_test(env)
            run_session_create_tty_settings_test(env)
            run_bridge_starts_daemon_session_test(env)
            run_minor_version_compatibility_test(env)
            run_live_draw_protocol_test(env)
            run_synchronized_output_protocol_test(env)
            run_input_ack_protocol_test(env)
            run_session_ended_payload_protocol_test(env)
            run_mux_terminal_session_end_uses_eof_not_reset_test(env)
            run_plain_scroll_protocol_test(env)
            run_plain_screen_protocol_test(env)
            run_split_escape_tail_is_not_replayed_as_text_test(env)
            run_active_screen_protocol_test(env)
            run_active_screen_barrier_protocol_test(env)
            run_terminal_modes_protocol_test(env)
            run_cursor_shape_protocol_test(env)
            run_complete_display_clear_protocol_test(env)
            run_title_protocol_test(env)
            run_default_colors_protocol_test(env)
            run_seeded_default_color_query_protocol_test(env)
            run_complex_ui_query_protocol_test(env)
            run_scrollback_open_draw_protocol_test(env)
            run_scrollback_clear_protocol_test(env)
            run_reconnect_scrollback_gap_protocol_test(env)
            run_resize_epoch_does_not_clear_reconnect_scrollback_test(env)
            run_screen_repaint_after_presentation_reset_clears_rows_test(env)
        finally:
            cleanup_runtime(env)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"socket_harness: {exc}", file=sys.stderr)
        raise
