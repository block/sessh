#!/usr/bin/env python3
from ssh_harness_common import *
from ssh_harness_transport_cases import *
from ssh_harness_diagnostics_cases import *
from ssh_harness_proxy_cases import *
from ssh_harness_terminal_cases import *
from ssh_harness_reconnect_cases import *


def run_test(name, fn):
    with tempfile.TemporaryDirectory(prefix="sessh-ssh-", dir="/tmp") as tmp:
        root = Path(tmp)
        env = isolated_env(root)
        try:
            fn(root)
        finally:
            cleanup_runtime(env)
    print(f"ok {name}")


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]

    tests = (
        ("fake ssh exports host to remote command", test_fake_ssh_exports_host_to_remote_command),
        (
            "ssh clean completion deletes cleanup records",
            test_ssh_clean_completion_deletes_cleanup_records,
        ),
        (
            "ssh transport uploads artifact and reaches broker",
            test_ssh_transport_uploads_artifact_and_reaches_broker,
        ),
        (
            "ssh daemon log records client hangup cleanup",
            test_ssh_daemon_log_records_client_hangup_cleanup,
        ),
        (
            "ssh killed client cleans up terminal resource",
            test_ssh_killed_client_cleans_up_terminal_resource,
        ),
        (
            "ssh killed proxy client cleans up proxy resource",
            test_ssh_killed_proxy_client_cleans_up_proxy_resource,
        ),
        (
            "ssh transports pool terminal tcp connection",
            test_ssh_transports_pool_terminal_tcp_connection,
        ),
        (
            "ssh transport pool key ignores agent socket identity",
            test_ssh_transport_pool_key_ignores_agent_socket_identity,
        ),
        (
            "ssh transport pool key includes ipqos",
            test_ssh_transport_pool_key_includes_ipqos,
        ),
        (
            "ssh proxy streams pool tcp connection",
            test_ssh_proxy_streams_pool_tcp_connection,
        ),
        (
            "ssh proxy fd-pass process exits and raw fd streams",
            test_ssh_proxy_fd_pass_process_exits_and_raw_fd_streams,
        ),
        (
            "ssh isolation-mode process proxy recovers after local daemon death",
            test_ssh_isolation_mode_process_proxy_recovers_after_local_daemon_death,
        ),
        (
            "ssh isolation-mode process proxy recovers after remote daemon death",
            test_ssh_isolation_mode_process_proxy_recovers_after_remote_daemon_death,
        ),
        (
            "ssh proxy process diagnostics fall back to stderr lines",
            test_ssh_proxy_process_diagnostics_fall_back_to_stderr_lines,
        ),
        (
            "ssh proxy process diagnostics file gets sparse lines",
            test_ssh_proxy_process_diagnostics_file_gets_sparse_lines,
        ),
        (
            "ssh proxy process diagnostics file gets jsonl when forced",
            test_ssh_proxy_process_diagnostics_file_gets_jsonl_when_forced,
        ),
        (
            "ssh terminal and proxy streams share tcp connection",
            test_ssh_terminal_and_proxy_streams_share_tcp_connection,
        ),
        (
            "ssh local daemon death tty error starts on new line",
            test_ssh_local_daemon_death_tty_error_starts_on_new_line,
        ),
        (
            "ssh transport cache hit suppresses bootstrap status",
            test_ssh_transport_cache_hit_suppresses_bootstrap_status,
        ),
        (
            "ssh clean remote exit preserves status",
            test_ssh_clean_remote_exit_preserves_status,
        ),
        (
            "ssh pre-attach stderr forwards immediately",
            test_ssh_pre_attach_stderr_forwards_immediately,
        ),
        (
            "ssh transport pins ipqos to interactive config value",
            test_ssh_transport_pins_ipqos_to_interactive_config_value,
        ),
        (
            "ssh transport respects explicit user ipqos",
            test_ssh_transport_respects_explicit_user_ipqos,
        ),
        (
            "ssh transport pins explicit two-value ipqos to interactive value",
            test_ssh_transport_pins_explicit_two_value_ipqos_to_interactive_value,
        ),
        (
            "ssh transport preserves config when ipqos query fails",
            test_ssh_transport_preserves_config_when_ipqos_query_fails,
        ),
        (
            "ssh session uses remote shell, not local client shell",
            test_ssh_session_uses_remote_shell_not_local_client_shell,
        ),
        (
            "ssh session does not forward local zsh function path",
            test_ssh_session_does_not_forward_local_zsh_function_path,
        ),
        (
            "ssh verbose flags are passed to ssh",
            test_ssh_verbose_flags_are_passed_to_ssh,
        ),
        (
            "ssh failure uses ssh exit status and visible args",
            test_ssh_failure_uses_ssh_exit_status_and_visible_args,
        ),
        (
            "ssh stdin-null option uses proxy stream",
            test_ssh_stdin_null_option_uses_proxy_stream,
        ),
        (
            "ssh x11 uses proxy stream",
            test_ssh_x11_uses_proxy_stream,
        ),
        (
            "ssh forwarding uses proxy stream",
            test_ssh_forwarding_uses_proxy_stream,
        ),
        (
            "ssh filter-level unhygienic uses proxy stream",
            test_ssh_filter_level_unhygienic_uses_proxy_stream,
        ),
        (
            "ssh filter-level config uses proxy stream",
            test_ssh_filter_level_config_uses_proxy_stream,
        ),
        (
            "ssh filter-level cli overrides config",
            test_ssh_filter_level_cli_overrides_config,
        ),
        (
            "ssh proxy command forwards explicit diagnostics file",
            test_ssh_proxy_command_forwards_explicit_diagnostics_file,
        ),
        (
            "ssh proxy command auto forwards same tty diagnostics file",
            test_ssh_proxy_command_auto_forwards_same_tty_diagnostics_file,
        ),
        (
            "ssh proxy command does not auto forward without same tty",
            test_ssh_proxy_command_does_not_auto_forward_without_same_tty,
        ),
        (
            "ssh isolation-mode full uses private proxy namespace",
            test_ssh_isolation_mode_full_uses_private_proxy_namespace,
        ),
        (
            "ssh isolation-mode none uses proxy fd-pass",
            test_ssh_isolation_mode_none_uses_proxy_fd_pass,
        ),
        (
            "ssh isolation-mode process uses proxy process",
            test_ssh_isolation_mode_process_uses_proxy_process,
        ),
        (
            "ssh remote command uses proxy stream",
            test_ssh_remote_command_uses_proxy_stream,
        ),
        (
            "ssh remote command option after host is remote arg",
            test_ssh_remote_command_option_after_host_is_remote_arg,
        ),
        (
            "ssh remote command stream preserves exit status",
            test_ssh_remote_command_stream_preserves_exit_status,
        ),
        (
            "ssh remote command stream waits for exit status after output eof",
            test_ssh_remote_command_stream_waits_for_exit_status_after_output_eof,
        ),
        (
            "ssh remote command stream preserves stderr channel",
            test_ssh_remote_command_stream_preserves_stderr_channel,
        ),
        (
            "ssh tty stdin remote command does not allocate tty without -t",
            test_ssh_tty_stdin_remote_command_does_not_allocate_tty_without_t,
        ),
        (
            "ssh terminal-emulator tty preserves exit status",
            test_ssh_terminal_emulator_tty_preserves_exit_status,
        ),
        (
            "ssh terminal-emulator tty propagates resize",
            test_ssh_terminal_emulator_tty_propagates_resize,
        ),
        (
            "ssh filter-level hygienic remote command uses proxy stream",
            test_ssh_filter_level_hygienic_remote_command_uses_proxy_stream,
        ),
        (
            "ssh filter-level hygienic remote command preserves exit status",
            test_ssh_filter_level_hygienic_remote_command_preserves_exit_status,
        ),
        (
            "ssh filter-level hygienic tty preserves exit status",
            test_ssh_filter_level_hygienic_tty_preserves_exit_status,
        ),
        (
            "ssh filter-level hygienic tty propagates resize",
            test_ssh_filter_level_hygienic_tty_propagates_resize,
        ),
        (
            "ssh filter-level hygienic forced tty uses proxy stream",
            test_ssh_filter_level_hygienic_forced_tty_uses_proxy_stream,
        ),
        (
            "ssh filter-level hygienic requested tty uses proxy stream",
            test_ssh_filter_level_hygienic_requested_tty_uses_proxy_stream,
        ),
        (
            "ssh interleaved tty and filter-level hygienic preserves exit status",
            test_ssh_interleaved_tty_and_filter_level_hygienic_preserves_exit_status,
        ),
        (
            "ssh filter-level hygienic config uses proxy stream",
            test_ssh_filter_level_hygienic_config_uses_proxy_stream,
        ),
        (
            "ssh filter-level emulated cli overrides hygienic config",
            test_ssh_filter_level_emulated_cli_overrides_hygienic_config,
        ),
        (
            "ssh filter-level hygienic command in tty uses proxy stream",
            test_ssh_filter_level_hygienic_command_in_tty_uses_proxy_stream,
        ),
        (
            "ssh filter-level hygienic tty uses proxy with hygienic diagnostics",
            test_ssh_filter_level_hygienic_tty_uses_proxy_with_hygienic_diagnostics,
        ),
        (
            "ssh terminal-emulator tty escape doubled tilde",
            test_ssh_terminal_emulator_tty_escape_doubled_tilde,
        ),
        (
            "ssh terminal-emulator tty escape help modal repaints",
            test_ssh_terminal_emulator_tty_escape_help_modal_repaints,
        ),
        (
            "ssh tty uses emulated TERM not outer TERM",
            test_ssh_tty_uses_emulated_term_not_outer_term,
        ),
        (
            "ssh filter-level hygienic tty copies outer TERM",
            test_ssh_filter_level_hygienic_tty_copies_outer_term,
        ),
        (
            "ssh filter-level hygienic tty copies local tty modes",
            test_ssh_filter_level_hygienic_tty_copies_local_tty_modes,
        ),
        (
            "ssh filter-level hygienic tty copies local output modes",
            test_ssh_filter_level_hygienic_tty_copies_local_output_modes,
        ),
        (
            "ssh filter-level hygienic tty sets SSH_TTY",
            test_ssh_filter_level_hygienic_tty_sets_ssh_tty,
        ),
        (
            "ssh filter-level hygienic interactive shell keeps prompt aligned",
            test_ssh_filter_level_hygienic_interactive_shell_keeps_prompt_aligned,
        ),
        (
            "ssh filter-level hygienic release artifact restores local tty on exit",
            test_ssh_filter_level_hygienic_release_artifact_restores_local_tty_on_exit,
        ),
        (
            "ssh terminal-emulator release artifact restores local tty on exit",
            test_ssh_terminal_emulator_release_artifact_restores_local_tty_on_exit,
        ),
        (
            "ssh requested tty with piped stdout does not emit local cleanup",
            test_ssh_requested_tty_with_piped_stdout_does_not_emit_local_cleanup,
        ),
        (
            "ssh forced tty remote command allocates pty with stdin null",
            test_ssh_forced_tty_remote_command_allocates_pty_with_stdin_null,
        ),
        (
            "ssh requested tty remote command allocates pty with tty stdin",
            test_ssh_requested_tty_remote_command_allocates_pty_with_tty_stdin,
        ),
        (
            "ssh single requested tty remote command with stdin null uses proxy stream",
            test_ssh_single_requested_tty_remote_command_with_stdin_null_uses_proxy_stream,
        ),
        (
            "ssh tty empty remote command starts interactive session",
            test_ssh_tty_empty_remote_command_starts_interactive_session,
        ),
        (
            "ssh tty quoted empty remote command uses shell eval",
            test_ssh_tty_quoted_empty_remote_command_uses_shell_eval,
        ),
        (
            "ssh host list is remote command",
            test_sessh_host_list_is_remote_command,
        ),
        (
            "ssh config-only cli options are rejected",
            test_ssh_config_only_cli_options_are_rejected,
        ),
        (
            "ssh bootstrap false config uses remote path sessh",
            test_ssh_bootstrap_false_config_uses_remote_path_sessh,
        ),
        (
            "ssh version mismatch fallback message is precise",
            test_ssh_version_mismatch_fallback_message_is_precise,
        ),
        (
            "ssh retry elapsed with input waits before switch",
            test_ssh_retry_elapsed_with_input_waits_before_switch,
        ),
        (
            "ssh retry elapsed without input switches automatically",
            test_ssh_retry_elapsed_without_input_switches_automatically,
        ),
        (
            "ssh no-echo input ack prevents false unresponsive",
            test_ssh_no_echo_input_ack_prevents_false_unresponsive,
        ),
        (
            "ssh reconnect displays live ssh stderr in overlay",
            test_ssh_reconnect_displays_live_ssh_stderr_in_overlay,
        ),
        (
            "ssh remote transport close reconnects in tty",
            test_ssh_remote_transport_close_reconnects_in_tty,
        ),
        (
            "ssh ssh transport process death reconnects in tty",
            test_ssh_transport_process_ssh_death_reconnects_in_tty,
        ),
        (
            "ssh remote daemon death reports remote error",
            test_ssh_remote_daemon_death_reports_remote_error,
        ),
        (
            "ssh log level quiet suppresses buffered stderr display",
            test_ssh_log_level_quiet_suppresses_buffered_stderr_display,
        ),
        (
            "ssh session buffers and displays stderr after attach",
            test_ssh_session_buffers_and_displays_stderr_after_attach,
        ),
        (
            "ssh reconnect does not apply active screen cleanup",
            test_ssh_reconnect_does_not_apply_active_screen_cleanup,
        ),
        (
            "ssh reconnect can close while bootstrapping",
            test_ssh_reconnect_can_close_while_bootstrapping,
        ),
        (
            "ssh escape disconnect exits while remote output is flowing",
            test_ssh_escape_disconnect_exits_while_remote_output_is_flowing,
        ),
        (
            "ssh unsupported remote platform without matching binary uses plain ssh",
            test_ssh_unsupported_remote_platform_falls_back_to_plain_ssh,
        ),
    )

    selected_name = None
    if argv:
        if len(argv) != 2 or argv[0] != "--case":
            print("usage: tests/ssh_harness.py [--case NAME]", file=sys.stderr)
            return 64
        selected_name = argv[1]

    if selected_name is not None:
        tests = tuple((name, fn) for name, fn in tests if name == selected_name)
        if not tests:
            print(f"unknown ssh harness case: {selected_name}", file=sys.stderr)
            return 64

    for name, fn in tests:
        run_test(name, fn)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
