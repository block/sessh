# shellcheck shell=sh
set -eu

sessh_main() {
  sessh_mode=${1:?}; shift
  sessh_config_shell=${1:?}; shift
  sessh_config_history_limit=${1:?}; shift
  sessh_config_remote_init=${1-}; shift
  sessh_config_remote_rc=${1-}; shift
  sessh_config_event_nonce=${1-}; shift

  sessh_bootstrap "$sessh_config_shell" "$sessh_config_history_limit" "$sessh_config_remote_init" "$sessh_config_remote_rc" "$sessh_config_event_nonce"

  case "$sessh_mode" in
    list)
      sessh_print_session_rows
      ;;
    new-interactive)
      sessh_resume_id=${1:?}; shift
      sessh_host=${1:?}; shift
      sessh_scrollback=${1:-0}
      if [ "$#" -gt 0 ]; then
        shift
      fi
      sessh_print_unattached_hint "$sessh_host"
      sessh_create_interactive_session "$sessh_resume_id"
      sessh_attach_interactive_session "$sessh_resume_id" "$sessh_host" 'sessh created' "$sessh_scrollback"
      ;;
    attach-interactive)
      sessh_resume_id=${1:?}; shift
      sessh_host=${1:?}; shift
      sessh_scrollback=${1:-0}
      if [ "$#" -gt 0 ]; then
        shift
      fi
      sessh_attach_interactive_session "$sessh_resume_id" "$sessh_host" 'sessh attached' "$sessh_scrollback"
      ;;
    attach-picker)
      sessh_host=${1:?}; shift
      sessh_scrollback=${1:-0}
      if [ "$#" -gt 0 ]; then
        shift
      fi
      sessh_resume_id=$(sessh_pick_session_id "$sessh_host")
      sessh_attach_interactive_session "$sessh_resume_id" "$sessh_host" 'sessh attached' "$sessh_scrollback"
      ;;
    run)
      sessh_resume_id=${1:?}; shift
      sessh_host=${1:?}; shift
      sessh_eval_args=${1:?}; shift
      sessh_command_name=${1-}; shift
      sessh_create_run_session "$sessh_resume_id" "$sessh_command_name" "$sessh_eval_args" "$@"
      sessh_attach_run_session "$sessh_resume_id" 'sessh created' 1
      ;;
    *)
      printf 'sessh: unknown remote transaction mode: %s\n' "$sessh_mode" >&2
      exit 64
      ;;
  esac
}

sessh_bootstrap() {
  SESSH_CONFIGURED_SHELL=$1
  SESSH_HISTORY_LIMIT=$2
  sessh_remote_init=$3
  sessh_remote_rc=$4
  SESSH_EVENT_NONCE=$5

  case "$SESSH_CONFIGURED_SHELL" in
    bash|zsh) ;;
    *)
      printf 'sessh: unsupported shell: %s\n' "$SESSH_CONFIGURED_SHELL" >&2
      exit 64
      ;;
  esac
  case "$SESSH_HISTORY_LIMIT" in
    ''|*[!0-9]*|0)
      printf 'sessh: history-limit must be positive\n' >&2
      exit 64
      ;;
  esac

  umask 077

  SESSH_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/sessh"
  SESSH_REMOTE_RC="$SESSH_STATE/remote-rc"
  SESSH_REMOTE_ZDOTDIR="$SESSH_STATE/zsh"
  SESSH_SOCKET="$SESSH_STATE/sockets/tmux.sock"
  SESSH_TMUX_CONF="$SESSH_STATE/tmux.conf"
  SESSH_SESSIONS="$SESSH_STATE/sessions"

  export SESSH_CONFIGURED_SHELL SESSH_HISTORY_LIMIT SESSH_STATE SESSH_REMOTE_RC SESSH_EVENT_NONCE
  export SESSH_REMOTE_ZDOTDIR SESSH_SOCKET SESSH_TMUX_CONF SESSH_SESSIONS

  mkdir -p "$SESSH_STATE/sockets" "$SESSH_SESSIONS" "$SESSH_REMOTE_ZDOTDIR"
  printf '%s' "$sessh_remote_rc" > "$SESSH_REMOTE_RC"
  printf '%s' "$sessh_remote_rc" > "$SESSH_REMOTE_ZDOTDIR/.zshrc"

  if [ -n "$sessh_remote_init" ]; then
    set +u
    eval "$sessh_remote_init" >&2
    set -u
  fi

  sessh_require_tool tmux
  sessh_require_tool "$SESSH_CONFIGURED_SHELL"
  SESSH_TMUX=$(command -v tmux)
  SESSH_SHELL=$(command -v "$SESSH_CONFIGURED_SHELL")
  export SESSH_TMUX SESSH_SHELL

  sessh_write_tmux_config > "$SESSH_TMUX_CONF"
}

sessh_require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "sessh: required remote tool not found: $1" >&2
    printf '%s\n' "sessh: install $1 on the remote host or make it available in PATH" >&2
    exit 127
  fi
}

sessh_write_tmux_config() {
  cat <<SESSH_TMUX_CONF
set-option -g status off
set-option -g mouse off
set-option -g prefix None
set-option -g prefix2 None
set-option -g escape-time 0
set-option -ga terminal-overrides ',*:smcup@:rmcup@'
set-option -g exit-empty on
set-option -g exit-unattached off
set-option -g destroy-unattached off
set-window-option -g history-limit $SESSH_HISTORY_LIMIT
set-window-option -g alternate-screen off
set-window-option -g pane-border-status off
SESSH_TMUX_CONF
}

sessh_quote() {
  printf '%s\n' "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

sessh_write_assignment() {
  printf '%s=' "$1"
  sessh_quote "$2"
  printf '\n'
}

sessh_emit_event() {
  [ -n "$SESSH_EVENT_NONCE" ] || return 0
  printf '\033]sessh;%s' "$SESSH_EVENT_NONCE" >&2
  for sessh_event_field do
    printf '\t%s' "$sessh_event_field" >&2
  done
  printf '\007' >&2
}

sessh_tmux() {
  "$SESSH_TMUX" -S "$SESSH_SOCKET" -f "$SESSH_TMUX_CONF" "$@"
}

sessh_session_name() {
  printf 'sessh-%s' "$1"
}

sessh_session_dir() {
  printf '%s/sessions/%s' "$SESSH_STATE" "$1"
}

sessh_session_command_name() {
  sessh_command_name_file="$SESSH_SESSIONS/$1/command-name"
  [ -r "$sessh_command_name_file" ] || return 1
  sed -n '1p' "$sessh_command_name_file"
}

sessh_validate_non_negative_integer() {
  sessh_name=$1
  sessh_value=$2
  case "$sessh_value" in
    ''|*[!0-9]*)
      printf 'sessh: %s must be a non-negative integer\n' "$sessh_name" >&2
      exit 64
      ;;
  esac
}

sessh_run_transcript_file() {
  printf '%s/transcript' "$(sessh_session_dir "$1")"
}

sessh_run_status_file() {
  printf '%s/exit-status' "$(sessh_session_dir "$1")"
}

sessh_run_start_channel() {
  printf 'sessh-start-%s' "$1"
}

sessh_file_size() {
  if [ ! -e "$1" ]; then
    printf '0\n'
    return 0
  fi
  wc -c < "$1" | tr -d ' '
}

sessh_stream_file_range() {
  sessh_stream_file=$1
  sessh_stream_offset=$2
  sessh_stream_count=$3
  [ "$sessh_stream_count" -gt 0 ] || return 0
  dd if="$sessh_stream_file" bs=1 skip="$sessh_stream_offset" count="$sessh_stream_count" >&2 2>/dev/null
}

sessh_drain_run_transcript_available() {
  sessh_transcript_file=$1
  sessh_transcript_offset=$2
  sessh_transcript_size=$(sessh_file_size "$sessh_transcript_file")
  if [ "$sessh_transcript_size" -gt "$sessh_transcript_offset" ]; then
    sessh_stream_file_range "$sessh_transcript_file" "$sessh_transcript_offset" "$((sessh_transcript_size - sessh_transcript_offset))"
    sessh_transcript_offset=$sessh_transcript_size
  fi
  printf '%s\n' "$sessh_transcript_offset"
}

sessh_record_run_pane_status_if_dead() {
  sessh_resume_id=$1
  sessh_status_file=$(sessh_run_status_file "$sessh_resume_id")
  [ ! -r "$sessh_status_file" ] || return 0
  sessh_session_name=$(sessh_session_name "$sessh_resume_id")
  sessh_pane_state=$(sessh_tmux display-message -p -t "$sessh_session_name:0.0" '#{pane_dead}	#{pane_dead_status}	#{pane_dead_signal}' 2>/dev/null || printf '0		')
  sessh_pane_dead=$(printf '%s\n' "$sessh_pane_state" | cut -f1)
  [ "$sessh_pane_dead" = 1 ] || return 0
  sessh_exit_status=$(printf '%s\n' "$sessh_pane_state" | cut -f2)
  sessh_exit_signal=$(printf '%s\n' "$sessh_pane_state" | cut -f3)
  case "$sessh_exit_status" in
    ''|*[!0-9]*)
      case "$sessh_exit_signal" in
        ''|*[!0-9]*) sessh_exit_status=1 ;;
        *) sessh_exit_status=$((128 + sessh_exit_signal)) ;;
      esac
      ;;
  esac
  sessh_status_tmp="${sessh_status_file}.pane.tmp"
  printf '%s\n' "$sessh_exit_status" > "$sessh_status_tmp"
  mv "$sessh_status_tmp" "$sessh_status_file"
}

sessh_stream_run_transcript() {
  sessh_resume_id=$1
  sessh_transcript_file=$(sessh_run_transcript_file "$sessh_resume_id")
  sessh_status_file=$(sessh_run_status_file "$sessh_resume_id")
  sessh_transcript_offset=0
  while :; do
    sessh_transcript_offset=$(sessh_drain_run_transcript_available "$sessh_transcript_file" "$sessh_transcript_offset")
    sessh_record_run_pane_status_if_dead "$sessh_resume_id"
    if [ -r "$sessh_status_file" ]; then
      sessh_stable_passes=0
      while [ "$sessh_stable_passes" -lt 2 ]; do
        sleep 0.05
        sessh_previous_offset=$sessh_transcript_offset
        sessh_transcript_offset=$(sessh_drain_run_transcript_available "$sessh_transcript_file" "$sessh_transcript_offset")
        if [ "$sessh_transcript_offset" = "$sessh_previous_offset" ]; then
          sessh_stable_passes=$((sessh_stable_passes + 1))
        else
          sessh_stable_passes=0
        fi
      done
      return 0
    fi
    sleep 0.05
  done
}

sessh_read_run_exit_status() {
  sessh_status_file=$(sessh_run_status_file "$1")
  if [ ! -r "$sessh_status_file" ]; then
    printf '1\n'
    return 0
  fi
  sessh_exit_status=$(sed -n '1p' "$sessh_status_file")
  case "$sessh_exit_status" in
    ''|*[!0-9]*) printf '1\n' ;;
    *) printf '%s\n' "$sessh_exit_status" ;;
  esac
}

sessh_cleanup_session() {
  sessh_resume_id=$1
  sessh_session_name=$(sessh_session_name "$sessh_resume_id")
  sessh_session_dir=$(sessh_session_dir "$sessh_resume_id")
  sessh_tmux kill-session -t "$sessh_session_name" >/dev/null 2>&1 || true
  rm -rf "$sessh_session_dir"
}

sessh_session_rows_unsorted() {
  sessh_panes=$(sessh_tmux list-panes -a -F '#{session_name}	#{session_attached}	#{session_created}	#{window_active}	#{pane_active}	#{pane_current_path}	#{pane_current_command}	#{window_name}' 2>/dev/null || true)
  [ -n "$sessh_panes" ] || return 0
  printf '%s\n' "$sessh_panes" | while IFS='	' read -r sessh_name sessh_attached sessh_created sessh_window_active sessh_pane_active sessh_cwd sessh_command sessh_title; do
    case "$sessh_name" in
      sessh-*) ;;
      *) continue ;;
    esac
    [ "$sessh_window_active" = 1 ] || continue
    [ "$sessh_pane_active" = 1 ] || continue
    sessh_resume_id=${sessh_name#sessh-}
    sessh_session_command_name_value=$(sessh_session_command_name "$sessh_resume_id" || true)
    if [ -n "$sessh_session_command_name_value" ]; then
      sessh_command=$sessh_session_command_name_value
    fi
    if [ "$sessh_attached" = 0 ]; then
      sessh_sort_attached=0
    else
      sessh_sort_attached=1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sessh_sort_attached" "$sessh_created" "$sessh_resume_id" "$sessh_attached" "$sessh_created" "$sessh_cwd" "$sessh_command" "$sessh_title"
  done
}

sessh_print_session_rows() {
  sessh_session_rows_unsorted | sort -n -k1,1 -k2,2 | cut -f3-
}

sessh_print_unattached_hint() {
  sessh_host=$1
  sessh_rows=$(sessh_print_session_rows | awk -F '\t' '$2 == "0" { print }')
  [ -n "$sessh_rows" ] || return 0
  printf '\nUnattached sessh sessions on %s:\n' "$sessh_host" >&2
  printf '%s\n' "$sessh_rows" | awk -F '\t' '{ printf "  %s  %s  %s  created %s\n", $1, $4, $5, $3 }' >&2
  sessh_first_id=$(printf '%s\n' "$sessh_rows" | awk -F '\t' 'NR == 1 { print $1 }')
  printf '\nTo attach to one, exit this session and run:\n  sessh %s --attach %s\n\n' "$sessh_host" "$sessh_first_id" >&2
}

sessh_pick_session_id() {
  sessh_host=$1
  sessh_pick_file="$SESSH_STATE/picker-$$"
  sessh_print_session_rows > "$sessh_pick_file"
  if [ ! -s "$sessh_pick_file" ]; then
    rm -f "$sessh_pick_file"
    printf 'sessh: no sessions found on %s\n' "$sessh_host" >&2
    exit 1
  fi

  printf '\nSessions on %s:\n\n' "$sessh_host" >&2
  awk -F '\t' '{
    attached = ($2 == "0" ? "no" : "yes")
    printf "  %d) %s  attached=%s  created=%s  cwd=%s  command=%s  title=%s\n", NR, $1, attached, $3, $4, $5, $6
  }' "$sessh_pick_file" >&2
  sessh_pick_count=$(wc -l < "$sessh_pick_file" | tr -d ' ')

  while :; do
    printf '\nAttach session [1-%s, default 1, q to cancel]: ' "$sessh_pick_count" >&2
    if ! IFS= read -r sessh_pick_choice; then
      rm -f "$sessh_pick_file"
      exit 130
    fi
    case "$sessh_pick_choice" in
      '') sessh_pick_choice=1 ;;
      q|Q)
        rm -f "$sessh_pick_file"
        exit 130
        ;;
      *[!0-9]*)
        printf 'sessh: enter a number from 1 to %s, or q to cancel\n' "$sessh_pick_count" >&2
        continue
        ;;
    esac
    if [ "$sessh_pick_choice" -lt 1 ] || [ "$sessh_pick_choice" -gt "$sessh_pick_count" ]; then
      printf 'sessh: enter a number from 1 to %s, or q to cancel\n' "$sessh_pick_count" >&2
      continue
    fi
    sessh_pick_id=$(sed -n "${sessh_pick_choice}p" "$sessh_pick_file" | cut -f1)
    rm -f "$sessh_pick_file"
    printf '%s\n' "$sessh_pick_id"
    return 0
  done
}

sessh_apply_options() {
  sessh_target=$1
  sessh_remain_on_exit=$2
  sessh_tmux set-option -t "$sessh_target" status off
  sessh_tmux set-option -t "$sessh_target" mouse off
  sessh_tmux set-option -t "$sessh_target" prefix None
  sessh_tmux set-option -t "$sessh_target" prefix2 None
  sessh_tmux set-option -t "$sessh_target" escape-time 0
  sessh_tmux set-window-option -t "$sessh_target" history-limit "$SESSH_HISTORY_LIMIT"
  sessh_tmux set-window-option -t "$sessh_target" alternate-screen off
  sessh_tmux set-window-option -t "$sessh_target" pane-border-status off
  sessh_tmux set-window-option -t "$sessh_target" remain-on-exit "$sessh_remain_on_exit"
  if [ "$sessh_remain_on_exit" = on ]; then
    sessh_tmux set-window-option -t "$sessh_target" remain-on-exit-format ''
  fi
}

sessh_terminal_lines() {
  sessh_lines=${LINES:-}
  case "$sessh_lines" in
    ''|*[!0-9]*|0)
      sessh_stty_size=$(stty size 2>/dev/null || true)
      sessh_lines=${sessh_stty_size%% *}
      ;;
  esac
  case "$sessh_lines" in
    ''|*[!0-9]*|0) sessh_lines=$(tput lines 2>/dev/null || true) ;;
  esac
  case "$sessh_lines" in
    ''|*[!0-9]*|0)
      printf '%s\n' 'sessh: unable to determine terminal height' >&2
      exit 64
      ;;
  esac
  printf '%s\n' "$sessh_lines"
}

sessh_terminal_padding_lines() {
  sessh_lines=$(sessh_terminal_lines)
  sessh_padding_lines=$((sessh_lines * 2 - 1))
  if [ "$sessh_padding_lines" -lt 0 ]; then
    sessh_padding_lines=0
  fi
  printf '%s\n' "$sessh_padding_lines"
}

sessh_terminal_padding_lf() {
  sessh_padding_lines=$(sessh_terminal_padding_lines)
  sessh_i=0
  while [ "$sessh_i" -lt "$sessh_padding_lines" ]; do
    printf '\n' >&2
    sessh_i=$((sessh_i + 1))
  done
}

sessh_terminal_boundary() {
  sessh_label=$1
  sessh_resume_id=$2
  sessh_note=${3:-}
  printf '%s%s%s%s%s\n' '--- ' "$sessh_label " "$sessh_resume_id" "$sessh_note" ' ---' >&2
}

sessh_terminal_scroll_after_boundary() {
  sessh_lines=$(sessh_terminal_lines)
  # Scroll the current screen plus the just-written boundary into history before tmux repaints.
  sessh_preserve_lines=$((sessh_lines - 1))
  if [ "$sessh_preserve_lines" -lt 0 ]; then
    sessh_preserve_lines=0
  fi
  sessh_i=0
  while [ "$sessh_i" -lt "$sessh_preserve_lines" ]; do
    printf '\n' >&2
    sessh_i=$((sessh_i + 1))
  done
}

sessh_capture_pane_line_count() {
  sessh_target=$1
  sessh_start=$2
  sessh_end=$3
  sessh_count=$(
    sessh_tmux capture-pane -p -S "$sessh_start" -E "$sessh_end" -t "$sessh_target" 2>/dev/null |
      wc -l |
      tr -d '[:space:]'
  )
  case "$sessh_count" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$sessh_count"
}

sessh_capture_pane_history_size() {
  sessh_target=$1
  sessh_all_lines=$(sessh_capture_pane_line_count "$sessh_target" - -) || return 1
  sessh_visible_lines=$(sessh_capture_pane_line_count "$sessh_target" 0 -) || return 1
  sessh_history_size=$((sessh_all_lines - sessh_visible_lines))
  if [ "$sessh_history_size" -lt 0 ]; then
    sessh_history_size=0
  fi
  printf '%s\n' "$sessh_history_size"
}

sessh_pane_height() {
  sessh_target=$1
  sessh_pane_height=$(sessh_tmux display-message -p -t "$sessh_target" '#{pane_height}' 2>/dev/null || true)
  case "$sessh_pane_height" in
    ''|*[!0-9]*|0)
      sessh_pane_height=$(sessh_capture_pane_line_count "$sessh_target" 0 -) || return 1
      ;;
  esac
  case "$sessh_pane_height" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  printf '%s\n' "$sessh_pane_height"
}

sessh_scrollback_note() {
  sessh_target=$1
  sessh_scrollback=$2
  sessh_history_size=$(
    sessh_capture_pane_history_size "$sessh_target" ||
      sessh_tmux display-message -p -t "$sessh_target" '#{history_size}' 2>/dev/null ||
      printf '0'
  )
  case "$sessh_history_size" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$sessh_history_size" -le "$sessh_scrollback" ]; then
    return 0
  fi
  sessh_visible_history_after_resize=0
  sessh_terminal_lines=$(sessh_terminal_lines 2>/dev/null || printf '0\n')
  sessh_pane_height=$(sessh_pane_height "$sessh_target" || printf '%s\n' "$sessh_terminal_lines")
  if [ "$sessh_terminal_lines" -gt "$sessh_pane_height" ]; then
    sessh_visible_history_after_resize=$((sessh_terminal_lines - sessh_pane_height))
  fi
  sessh_covered_history=$sessh_scrollback
  if [ "$sessh_visible_history_after_resize" -gt "$sessh_covered_history" ]; then
    sessh_covered_history=$sessh_visible_history_after_resize
  fi
  if [ "$sessh_history_size" -le "$sessh_covered_history" ]; then
    return 0
  fi
  sessh_skipped=$((sessh_history_size - sessh_covered_history))
  if [ "$sessh_skipped" -eq 1 ]; then
    printf '%s' '; skipped 1 line of scrollback'
  else
    printf '%s%s%s' '; skipped ' "$sessh_skipped" ' lines of scrollback'
  fi
}

sessh_clear_tmux_exit_message() {
  printf '\033[1A\r\033[2K' >&2
}

sessh_create_interactive_session() {
  sessh_resume_id=$1
  sessh_session_name=$(sessh_session_name "$sessh_resume_id")
  sessh_session_dir=$(sessh_session_dir "$sessh_resume_id")
  if sessh_tmux has-session -t "$sessh_session_name" >/dev/null 2>&1; then
    printf 'sessh: generated session id already exists: %s\n' "$sessh_resume_id" >&2
    exit 70
  fi
  mkdir -p "$sessh_session_dir"
  rm -f "$sessh_session_dir/command-name"
  sessh_write_interactive_entrypoint "$sessh_resume_id"
  sessh_entrypoint="$sessh_session_dir/interactive.sh"
  sessh_entrypoint_command="sh $(sessh_quote "$sessh_entrypoint")"
  sessh_width=${COLUMNS:-80}
  sessh_height=${LINES:-24}
  sessh_tmux new-session -d -s "$sessh_session_name" -x "$sessh_width" -y "$sessh_height" "$sessh_entrypoint_command"
  sessh_apply_options "$sessh_session_name" off
  sessh_emit_event created "$sessh_resume_id"
}

sessh_write_interactive_entrypoint() {
  sessh_resume_id=$1
  sessh_session_name=$(sessh_session_name "$sessh_resume_id")
  sessh_entrypoint="$(sessh_session_dir "$sessh_resume_id")/interactive.sh"
  {
    printf '%s\n' '#!/bin/sh'
    sessh_write_assignment SESSH_REMOTE_RC "$SESSH_REMOTE_RC"
    sessh_write_assignment SESSH_REMOTE_ZDOTDIR "$SESSH_REMOTE_ZDOTDIR"
    sessh_write_assignment SESSH_RESUME_ID "$sessh_resume_id"
    sessh_write_assignment SESSH_TMUX_BIN "$SESSH_TMUX"
    sessh_write_assignment SESSH_TMUX_SOCKET "$SESSH_SOCKET"
    sessh_write_assignment SESSH_TMUX_TARGET "$sessh_session_name"
    sessh_write_assignment SESSH_SHELL "$SESSH_SHELL"
    cat <<'SESSH_INTERACTIVE_ENTRYPOINT'
_sessh_pad_exit_screen() {
  sessh_lines=${LINES:-}
  sessh_output=

  if [ -n "${SESSH_TMUX_BIN:-}" ] &&
     [ -n "${SESSH_TMUX_SOCKET:-}" ] &&
     [ -n "${SESSH_TMUX_TARGET:-}" ]; then
    sessh_client_info=$(
      "$SESSH_TMUX_BIN" -S "$SESSH_TMUX_SOCKET" display-message -p \
        -t "$SESSH_TMUX_TARGET" '#{client_tty} #{client_height}' 2>/dev/null || true
    )
    sessh_client_tty=${sessh_client_info%% *}
    sessh_client_height=${sessh_client_info#* }
    case "$sessh_client_height" in
      ''|*[!0-9]*|0) ;;
      *) sessh_lines=$sessh_client_height ;;
    esac
    if [ -n "$sessh_client_tty" ] && [ -w "$sessh_client_tty" ]; then
      sessh_output=$sessh_client_tty
    fi
  fi

  case "$sessh_lines" in
    ''|*[!0-9]*|0)
      sessh_stty_size=$(stty size 2>/dev/null || true)
      sessh_lines=${sessh_stty_size%% *}
      ;;
  esac
  case "$sessh_lines" in
    ''|*[!0-9]*|0) sessh_lines=$(tput lines 2>/dev/null || true) ;;
  esac
  case "$sessh_lines" in
    ''|*[!0-9]*|0) sessh_padding_lines=0 ;;
    *)
      sessh_padding_lines=$((sessh_lines - 1))
      if [ "$sessh_padding_lines" -lt 0 ]; then
        sessh_padding_lines=0
      fi
      ;;
  esac

  _sessh_write_exit_boundary_lf() {
    if [ -n "${SESSH_RESUME_ID:-}" ]; then
      printf '%s%s%s\n' '--- sessh exited ' "$SESSH_RESUME_ID" ' ---'
    else
      printf '%s\n' '--- sessh exited ---'
    fi
    sessh_i=0
    while [ "$sessh_i" -lt "$sessh_padding_lines" ]; do
      printf '\n'
      sessh_i=$((sessh_i + 1))
    done
  }

  _sessh_write_exit_boundary_crlf() {
    if [ -n "${SESSH_RESUME_ID:-}" ]; then
      printf '%s%s%s\r\n' '--- sessh exited ' "$SESSH_RESUME_ID" ' ---'
    else
      printf '%s\r\n' '--- sessh exited ---'
    fi
    sessh_i=0
    while [ "$sessh_i" -lt "$sessh_padding_lines" ]; do
      printf '\r\n'
      sessh_i=$((sessh_i + 1))
    done
  }

  if [ -n "$sessh_output" ]; then
    _sessh_write_exit_boundary_crlf >> "$sessh_output"
  else
    _sessh_write_exit_boundary_lf
  fi
}

export SESSH_RESUME_ID SESSH_REMOTE_RC SESSH_TMUX_BIN SESSH_TMUX_SOCKET SESSH_TMUX_TARGET
SESSH_INTERACTIVE_ENTRYPOINT
    case "$SESSH_CONFIGURED_SHELL" in
      bash)
        cat <<'SESSH_INTERACTIVE_BASH_ENTRYPOINT'
"$SESSH_SHELL" --rcfile "$SESSH_REMOTE_RC" -i
SESSH_INTERACTIVE_BASH_ENTRYPOINT
        ;;
      zsh)
        cat <<'SESSH_INTERACTIVE_ZSH_ENTRYPOINT'
ZDOTDIR="$SESSH_REMOTE_ZDOTDIR"; export ZDOTDIR
"$SESSH_SHELL" -i
SESSH_INTERACTIVE_ZSH_ENTRYPOINT
        ;;
    esac
    cat <<'SESSH_INTERACTIVE_ENTRYPOINT'
sessh_shell_status=$?
_sessh_pad_exit_screen
exit "$sessh_shell_status"
SESSH_INTERACTIVE_ENTRYPOINT
  } > "$sessh_entrypoint"
  chmod 700 "$sessh_entrypoint"
}

sessh_attach_existing_session() {
  sessh_resume_id=$1
  sessh_attach_label=$2
  sessh_scrollback=$3
  sessh_session_name=$(sessh_session_name "$sessh_resume_id")
  sessh_validate_non_negative_integer scrollback "$sessh_scrollback"
  if ! sessh_tmux has-session -t "$sessh_session_name" >/dev/null 2>&1; then
    printf 'sessh: session not found: %s\n' "$sessh_resume_id" >&2
    exit 1
  fi
  sessh_target="$sessh_session_name:0.0"
  sessh_attach_note=$(sessh_scrollback_note "$sessh_target" "$sessh_scrollback")
  sessh_emit_event attached "$sessh_resume_id"
  if [ "$sessh_scrollback" -gt 0 ]; then
    sessh_terminal_boundary "$sessh_attach_label" "$sessh_resume_id" "$sessh_attach_note"
  else
    sessh_terminal_boundary "$sessh_attach_label" "$sessh_resume_id" "$sessh_attach_note"
    sessh_terminal_scroll_after_boundary
  fi
  set +e
  if [ "$sessh_scrollback" -gt 0 ]; then
    sessh_tmux capture-pane -p -S "-$sessh_scrollback" -E -1 -t "$sessh_target"
    printf '%s\n' '--- sessh live boundary ---' >&2
    sessh_terminal_padding_lf
    sessh_tmux attach-session -d -t "$sessh_session_name"
  else
    sessh_tmux attach-session -d -t "$sessh_session_name"
  fi
  SESSH_ATTACH_STATUS=$?
  set -e
  sessh_clear_tmux_exit_message
}

sessh_exit_detached_session() {
  sessh_resume_id=$1
  sessh_host=$2
  sessh_message=$3
  sessh_clean_attach_status=$4
  sessh_emit_event detached "$sessh_resume_id"
  sessh_terminal_boundary 'sessh detached' "$sessh_resume_id"
  printf '\n%s\n  sessh %s --attach %s\n' "$sessh_message" "$sessh_host" "$sessh_resume_id" >&2
  if [ "$SESSH_ATTACH_STATUS" -eq 0 ]; then
    exit "$sessh_clean_attach_status"
  fi
  exit "$SESSH_ATTACH_STATUS"
}

sessh_attach_interactive_session() {
  sessh_resume_id=$1
  sessh_host=$2
  sessh_attach_label=$3
  sessh_scrollback=$4
  sessh_session_name=$(sessh_session_name "$sessh_resume_id")
  sessh_session_dir=$(sessh_session_dir "$sessh_resume_id")
  if [ -r "$(sessh_run_transcript_file "$sessh_resume_id")" ]; then
    sessh_attach_run_session "$sessh_resume_id" "$sessh_attach_label" 0
  fi
  sessh_attach_existing_session "$sessh_resume_id" "$sessh_attach_label" "$sessh_scrollback"
  if sessh_tmux has-session -t "$sessh_session_name" >/dev/null 2>&1; then
    sessh_exit_detached_session "$sessh_resume_id" "$sessh_host" 'To attach to this session, run:' 0
  else
    sessh_emit_event exited "$sessh_resume_id" 0
    rm -rf "$sessh_session_dir"
    exit 0
  fi
}

sessh_create_run_session() {
  sessh_resume_id=$1
  sessh_command_name=$2
  sessh_eval_args=$3
  shift 3
  sessh_session_name=$(sessh_session_name "$sessh_resume_id")
  sessh_session_dir=$(sessh_session_dir "$sessh_resume_id")
  if sessh_tmux has-session -t "$sessh_session_name" >/dev/null 2>&1; then
    printf 'sessh: generated session id already exists: %s\n' "$sessh_resume_id" >&2
    exit 70
  fi
  mkdir -p "$sessh_session_dir"
  if [ -n "$sessh_command_name" ]; then
    printf '%s\n' "$sessh_command_name" > "$sessh_session_dir/command-name"
  else
    rm -f "$sessh_session_dir/command-name"
  fi
  sessh_transcript_file=$(sessh_run_transcript_file "$sessh_resume_id")
  sessh_status_file=$(sessh_run_status_file "$sessh_resume_id")
  : > "$sessh_transcript_file"
  rm -f "$sessh_status_file" "$sessh_status_file.tmp" "$sessh_status_file.pane.tmp"
  sessh_write_run_entrypoint "$sessh_resume_id" "$sessh_eval_args" "$@"
  sessh_entrypoint="$sessh_session_dir/run.sh"
  sessh_start_channel=$(sessh_run_start_channel "$sessh_resume_id")
  sessh_start_command="$(sessh_quote "$SESSH_TMUX") -S $(sessh_quote "$SESSH_SOCKET") wait-for $(sessh_quote "$sessh_start_channel"); sh $(sessh_quote "$sessh_entrypoint")"
  sessh_width=${COLUMNS:-80}
  sessh_height=${LINES:-24}
  sessh_tmux new-session -d -s "$sessh_session_name" -x "$sessh_width" -y "$sessh_height" "$sessh_start_command"
  sessh_apply_options "$sessh_session_name" on
  sessh_pipe_command="cat >> $(sessh_quote "$sessh_transcript_file")"
  sessh_tmux pipe-pane -o -t "$sessh_session_name:0.0" "$sessh_pipe_command"
  sessh_emit_event created "$sessh_resume_id"
}

sessh_write_run_entrypoint() {
  sessh_resume_id=$1
  sessh_eval_args=$2
  shift 2
  sessh_session_dir=$(sessh_session_dir "$sessh_resume_id")
  sessh_entrypoint="$sessh_session_dir/run.sh"
  {
    printf '%s\n' '#!/bin/sh'
    sessh_write_assignment SESSH_REMOTE_RC "$SESSH_REMOTE_RC"
    sessh_write_assignment SESSH_SHELL "$SESSH_SHELL"
    sessh_write_assignment SESSH_EVAL_ARGS "$sessh_eval_args"
    sessh_write_assignment SESSH_STATUS_FILE "$(sessh_run_status_file "$sessh_resume_id")"
    printf '%s' 'set --'
    for sessh_arg do
      printf ' %s' "$(sessh_quote "$sessh_arg")"
    done
    printf '\n'
    cat <<'SESSH_RUN_ENTRYPOINT'
export SESSH_REMOTE_RC SESSH_EVAL_ARGS SESSH_STATUS_FILE
"$SESSH_SHELL" -c '
SESSH_REMOTE_RC=${SESSH_REMOTE_RC:?}; export SESSH_REMOTE_RC
if [ -r "$SESSH_REMOTE_RC" ]; then
  . "$SESSH_REMOTE_RC"
fi
if [ "$SESSH_EVAL_ARGS" = 1 ]; then
  ( eval "$*" )
else
  ( "$@" )
fi
sessh_run_status=$?
sessh_status_tmp="${SESSH_STATUS_FILE}.tmp"
printf "%s\n" "$sessh_run_status" > "$sessh_status_tmp"
mv "$sessh_status_tmp" "$SESSH_STATUS_FILE"
exit "$sessh_run_status"
' -- "$@"
sessh_run_status=$?
if [ ! -r "$SESSH_STATUS_FILE" ]; then
  sessh_status_tmp="${SESSH_STATUS_FILE}.tmp"
  printf '%s\n' "$sessh_run_status" > "$sessh_status_tmp"
  mv "$sessh_status_tmp" "$SESSH_STATUS_FILE"
fi
exit "$sessh_run_status"
SESSH_RUN_ENTRYPOINT
  } > "$sessh_entrypoint"
  chmod 700 "$sessh_entrypoint"
}

sessh_attach_run_session() {
  sessh_resume_id=$1
  sessh_attach_label=$2
  sessh_start_run=$3
  sessh_session_name=$(sessh_session_name "$sessh_resume_id")
  sessh_transcript_file=$(sessh_run_transcript_file "$sessh_resume_id")
  sessh_status_file=$(sessh_run_status_file "$sessh_resume_id")
  if [ ! -r "$sessh_transcript_file" ]; then
    printf 'sessh: session not found: %s\n' "$sessh_resume_id" >&2
    exit 1
  fi
  if [ ! -r "$sessh_status_file" ] && ! sessh_tmux has-session -t "$sessh_session_name" >/dev/null 2>&1; then
    printf 'sessh: session not found: %s\n' "$sessh_resume_id" >&2
    exit 1
  fi
  sessh_emit_event attached "$sessh_resume_id"
  sessh_terminal_boundary "$sessh_attach_label" "$sessh_resume_id"
  if [ "$sessh_start_run" = 1 ]; then
    sessh_tmux wait-for -S "$(sessh_run_start_channel "$sessh_resume_id")"
  fi
  sessh_stream_run_transcript "$sessh_resume_id"
  sessh_exit_status=$(sessh_read_run_exit_status "$sessh_resume_id")
  sessh_emit_event exited "$sessh_resume_id" "$sessh_exit_status"
  sessh_terminal_boundary 'sessh exited' "$sessh_resume_id"
  sessh_cleanup_session "$sessh_resume_id"
  exit "$sessh_exit_status"
}
