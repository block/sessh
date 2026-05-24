#!/usr/bin/env python3
import os
import shutil
import shlex
import stat
import subprocess
import tempfile
import time
from pathlib import Path

from harness_cleanup import cleanup_runtime
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("SESSH_BIN", str(ROOT / "zig-out" / "bin" / "sessh")))
TMUX = shutil.which("tmux")
TMUX_ARGS = [TMUX, "-L", f"sessh-ssh-reconnect-{os.getpid()}"] if TMUX else []
PROMPT = "OUTER_TEST>"


FAKE_SSH = """#!/bin/sh
set -eu

saw_t=0
config_query=0
batch_mode=0
host=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift
      [ "$#" -gt 0 ] || exit 97
      [ "$1" = "BatchMode=yes" ] && batch_mode=1
      shift
      ;;
    -o*)
      [ "${1#-o}" = "BatchMode=yes" ] && batch_mode=1
      shift
      ;;
    -G)
      config_query=1
      shift
      ;;
    -T)
      saw_t=1
      shift
      ;;
    -*)
      printf 'fake ssh: unsupported option: %s\\n' "$1" >&2
      exit 97
      ;;
    *)
      host=$1
      shift
      break
      ;;
  esac
done

if [ "$config_query" -eq 1 ]; then
  [ -n "$host" ] || exit 97
  printf 'hostname %s\\n' "$host"
  printf 'ipqos %s\\n' "${SESSH_FAKE_SSH_G_IPQOS:-af21 cs1}"
  exit 0
fi

[ "$saw_t" -eq 1 ] || exit 97
[ -n "$host" ] || exit 97
[ "$#" -eq 1 ] || exit 97

if [ "$batch_mode" -eq 1 ] && [ -n "${SESSH_FAKE_SSH_DELAY_ON_BATCH:-}" ]; then
  sleep "$SESSH_FAKE_SSH_DELAY_ON_BATCH"
fi
export SESSH_TEST_HOST=$host
exec sh -c "$1"
"""


def run(env, args, **kwargs):
    return subprocess.run(
        args,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
        **kwargs,
    )


def capture(env, session):
    return run(env, [*TMUX_ARGS, "capture-pane", "-p", "-S", "-200", "-t", session]).stdout


def capture_visible(env, session):
    return run(env, [*TMUX_ARGS, "capture-pane", "-p", "-t", session]).stdout


def wait_capture(env, session, needle, timeout=8.0):
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        last = capture(env, session)
        if needle in last:
            return last
        time.sleep(0.05)
    raise AssertionError(f"did not see {needle!r}; pane contained:\n{last}")


def wait_capture_absent(env, session, needle, timeout=8.0):
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        last = capture(env, session)
        if needle not in last:
            return last
        time.sleep(0.05)
    raise AssertionError(f"still saw {needle!r}; pane contained:\n{last}")


def wait_visible_absent(env, session, needle, timeout=8.0):
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        last = capture_visible(env, session)
        if needle not in last:
            return last
        time.sleep(0.05)
    raise AssertionError(f"still saw {needle!r}; visible pane contained:\n{last}")


def write_fake_ssh(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(FAKE_SSH)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def tmux_session_env_args(env):
    args = []
    for key in (
        "HOME",
        "HISTFILE",
        "XDG_RUNTIME_DIR",
        "SESSH_RUNTIME_DIR",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "TMPDIR",
        "PATH",
    ):
        args.extend(["-e", f"{key}={env[key]}"])
    return args


def new_tmux_session(env, session, width, height):
    run(
        env,
        [
            *TMUX_ARGS,
            "new-session",
            "-d",
            "-s",
            session,
            "-x",
            str(width),
            "-y",
            str(height),
            *tmux_session_env_args(env),
            "/bin/sh",
        ],
    )


def main():
    if TMUX is None:
        raise SystemExit("missing tmux")
    if not BIN.exists():
        raise SystemExit(f"missing binary: {BIN}")

    session = f"sessh-ssh-reconnect-{os.getpid()}"
    detach_session = f"{session}-detach"
    alt_detach_session = f"{session}-alt-detach"
    bottom_session = f"{session}-bottom"
    with tempfile.TemporaryDirectory(prefix="sessh-ssh-reconnect-tmux-", dir="/tmp") as tmp_text:
        tmp = Path(tmp_text)
        env = isolated_env(tmp)
        fake_bin = tmp / "fake-bin"
        fake_ssh = fake_bin / "ssh"
        remote_shell = Path(env["HOME"]) / "remote-shell"
        write_fake_ssh(fake_ssh)
        remote_shell.write_text(
            "#!/bin/sh\n"
            "printf 'REMOTE_TOP\\nREMOTE_PROMPT$ '\n"
            "while IFS= read -r line; do\n"
            "  if [ \"$line\" = enter-alt ]; then\n"
            "    printf 'PRIMARY_BEFORE_ALT\\n'\n"
            "    printf '\\033[?1049hALT_SCREEN_READY\\n'\n"
            "    while :; do sleep 1; done\n"
            "  fi\n"
            "  if [ \"$line\" = spam ]; then\n"
            "    i=1\n"
            "    while :; do\n"
            "      printf 'REMOTE_SPAM_%06d\\n' \"$i\"\n"
            "      i=$((i + 1))\n"
            "    done\n"
            "  fi\n"
            "  printf 'REMOTE:%s\\n' \"$line\"\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "  printf 'REMOTE_PROMPT$ '\n"
            "done\n"
        )
        remote_shell.chmod(remote_shell.stat().st_mode | stat.S_IXUSR)

        child_env = env.copy()
        child_env["PATH"] = f"{fake_bin}{os.pathsep}{child_env['PATH']}"
        child_env["SHELL"] = str(remote_shell)
        child_env["SESSH_FAKE_SSH_DELAY_ON_BATCH"] = "1"
        sessh_wrapper = tmp / "run-sessh"
        sessh_wrapper.write_text(
            "#!/bin/sh\n"
            f"export HOME={shlex.quote(env['HOME'])}\n"
            f"export XDG_RUNTIME_DIR={shlex.quote(env['XDG_RUNTIME_DIR'])}\n"
            f"export SESSH_RUNTIME_DIR={shlex.quote(env['SESSH_RUNTIME_DIR'])}\n"
            f"export XDG_CACHE_HOME={shlex.quote(env['XDG_CACHE_HOME'])}\n"
            f"export XDG_CONFIG_HOME={shlex.quote(env['XDG_CONFIG_HOME'])}\n"
            f"export XDG_DATA_HOME={shlex.quote(env['XDG_DATA_HOME'])}\n"
            f"export XDG_STATE_HOME={shlex.quote(env['XDG_STATE_HOME'])}\n"
            f"export PATH={shlex.quote(child_env['PATH'])}\n"
            f"export SHELL={shlex.quote(str(remote_shell))}\n"
            "export SESSH_FAKE_SSH_DELAY_ON_BATCH=1\n"
            "if [ \"${1-}\" = attach ]; then\n"
            "  shift\n"
            f"  exec {shlex.quote(str(BIN))} attach --leader CTRL-A --scrollback-limit 321 --host test-host \"$@\"\n"
            "fi\n"
            f"exec {shlex.quote(str(BIN))} new --leader CTRL-A --scrollback-limit 321 test-host \"$@\"\n"
        )
        sessh_wrapper.chmod(sessh_wrapper.stat().st_mode | stat.S_IXUSR)

        cleanup_runtime(env)
        try:
            new_tmux_session(env, session, 80, 24)
            run(env, [*TMUX_ARGS, "set-window-option", "-t", session, "remain-on-exit", "on"])
            run(env, [*TMUX_ARGS, "send-keys", "-t", session, f"PS1={shlex.quote(PROMPT)} exec /bin/sh", "Enter"])
            wait_capture(env, session, PROMPT)
            run(env, [*TMUX_ARGS, "send-keys", "-t", session, "printf 'OUTER_BEFORE_1\\nOUTER_BEFORE_2\\n'", "Enter"])
            wait_capture(env, session, "OUTER_BEFORE_2")

            sessh_cmd = shlex.quote(str(sessh_wrapper))
            run(env, [*TMUX_ARGS, "send-keys", "-t", session, sessh_cmd, "Enter"])
            wait_capture(env, session, "REMOTE_PROMPT$")
            before = capture_visible(env, session)
            before_lines = before.splitlines()
            if "REMOTE_TOP" not in before_lines:
                raise AssertionError(f"REMOTE_TOP not found in pane:\n{before}")
            remote_top_index = before_lines.index("REMOTE_TOP")

            run(env, [*TMUX_ARGS, "send-keys", "-t", session, "C-a", "s"])
            wait_capture(env, session, "sessh: disconnected. Retry in 5sec")
            wait_capture(env, session, "sessh: disconnected. Retry in 4sec", timeout=2.0)
            banner = capture_visible(env, session).splitlines()
            if remote_top_index + 1 >= len(banner) or "sessh: disconnected. Retry in 4sec" not in banner[remote_top_index + 1]:
                raise AssertionError(
                    "reconnect banner was not drawn one row below the sessh screen top\n"
                    f"before:\n{before}\n"
                    f"banner:\n{capture_visible(env, session)}"
                )

            run(env, [*TMUX_ARGS, "send-keys", "-t", session, "Space"])
            wait_capture(env, session, "sessh: reconnecting... CTRL-C aborts", timeout=2.0)
            success_banner = "sessh: reconnected"
            wait_capture(env, session, success_banner, timeout=10.0)
            run(env, [*TMUX_ARGS, "send-keys", "-t", session, "Space"])
            wait_visible_absent(env, session, success_banner, timeout=2.0)
            after_repaint = capture_visible(env, session)
            if "sessh: disconnected. Retry" in after_repaint:
                raise AssertionError(f"reconnect banner was still visible after repaint:\n{after_repaint}")
            if after_repaint.count("REMOTE_TOP") != 1:
                raise AssertionError(f"reconnect did not repaint the session screen before input:\n{after_repaint}")
            after_repaint_lines = after_repaint.splitlines()
            if after_repaint_lines.index("REMOTE_TOP") != remote_top_index:
                raise AssertionError(
                    "reconnect repaint shifted the sessh viewport\n"
                    f"before:\n{before}\n"
                    f"after:\n{after_repaint}"
                )
            run(env, [*TMUX_ARGS, "send-keys", "-t", session, "after-reconnect", "Enter"])
            final = wait_capture(env, session, "REMOTE:after-reconnect")
            if "sessh: disconnected. Retry" in final:
                raise AssertionError(f"reconnect banner leaked into final pane:\n{final}")
            if "sessh: reconnected" in final:
                raise AssertionError(f"reconnected banner leaked into final pane:\n{final}")
            if final.count("REMOTE_TOP") != 1:
                raise AssertionError(f"reconnect duplicated session screen content:\n{final}")
            if "OUTER_BEFORE_1" not in final or "OUTER_BEFORE_2" not in final:
                raise AssertionError(f"reconnect damaged outer scrollback:\n{final}")

            new_tmux_session(env, bottom_session, 100, 8)
            run(env, [*TMUX_ARGS, "set-window-option", "-t", bottom_session, "remain-on-exit", "on"])
            run(env, [*TMUX_ARGS, "send-keys", "-t", bottom_session, f"PS1={shlex.quote(PROMPT)} exec /bin/sh", "Enter"])
            wait_capture(env, bottom_session, PROMPT)
            run(
                env,
                [
                    *TMUX_ARGS,
                    "send-keys",
                    "-t",
                    bottom_session,
                    "i=1; while [ $i -le 16 ]; do printf 'BOTTOM_OUTER_%02d\\n' $i; i=$((i+1)); done",
                    "Enter",
                ],
            )
            wait_capture(env, bottom_session, "BOTTOM_OUTER_16")
            run(env, [*TMUX_ARGS, "send-keys", "-t", bottom_session, sessh_cmd, "Enter"])
            wait_capture(env, bottom_session, "REMOTE_PROMPT$")
            bottom_before = capture_visible(env, bottom_session)
            bottom_before_lines = bottom_before.splitlines()
            if "REMOTE_TOP" not in bottom_before_lines:
                raise AssertionError(f"REMOTE_TOP not found in bottom pane:\n{bottom_before}")
            bottom_remote_top_index = bottom_before_lines.index("REMOTE_TOP")
            if bottom_remote_top_index < len(bottom_before_lines) - 3:
                raise AssertionError(f"bottom regression did not place sessh near pane bottom:\n{bottom_before}")

            run(env, [*TMUX_ARGS, "send-keys", "-t", bottom_session, "C-a", "s"])
            wait_capture(env, bottom_session, "sessh: disconnected. Retry in 5sec")
            run(env, [*TMUX_ARGS, "send-keys", "-t", bottom_session, "Space"])
            wait_capture(env, bottom_session, "sessh: reconnecting... CTRL-C aborts", timeout=2.0)
            wait_capture(env, bottom_session, success_banner, timeout=10.0)
            run(env, [*TMUX_ARGS, "send-keys", "-t", bottom_session, "Space"])
            wait_visible_absent(env, bottom_session, success_banner, timeout=2.0)
            bottom_after = capture_visible(env, bottom_session)
            bottom_after_lines = bottom_after.splitlines()
            if "REMOTE_TOP" not in bottom_after_lines:
                raise AssertionError(f"bottom reconnect lost session screen:\n{bottom_after}")
            if bottom_after_lines.index("REMOTE_TOP") != bottom_remote_top_index:
                raise AssertionError(
                    "bottom reconnect repaint shifted the sessh viewport\n"
                    f"before:\n{bottom_before}\n"
                    f"after:\n{bottom_after}"
                )

            idle_detach_session = f"{detach_session}-idle"
            new_tmux_session(env, idle_detach_session, 140, 24)
            run(env, [*TMUX_ARGS, "set-window-option", "-t", idle_detach_session, "remain-on-exit", "on"])
            run(env, [*TMUX_ARGS, "send-keys", "-t", idle_detach_session, f"PS1={shlex.quote(PROMPT)} exec /bin/sh", "Enter"])
            wait_capture(env, idle_detach_session, PROMPT)
            run(env, [*TMUX_ARGS, "send-keys", "-t", idle_detach_session, sessh_cmd, "Enter"])
            wait_capture(env, idle_detach_session, "REMOTE_PROMPT$")
            run(env, [*TMUX_ARGS, "send-keys", "-t", idle_detach_session, "C-a", "d"])
            time.sleep(0.5)
            idle_after = capture(env, idle_detach_session)
            if "sessh: detached" not in idle_after or "sesshmux attach" not in idle_after:
                raise AssertionError(f"detach did not print a reattach banner:\n{idle_after}")
            if f"REMOTE_PROMPT$ {PROMPT}" in idle_after or f"REMOTE_PROMPT${PROMPT}" in idle_after:
                raise AssertionError(f"detach drew the outer prompt at the inner cursor:\n{idle_after}")
            run(env, [*TMUX_ARGS, "send-keys", "-t", idle_detach_session, "printf 'OUTER_IDLE_DETACHED\\n'", "Enter"])
            wait_capture(env, idle_detach_session, "OUTER_IDLE_DETACHED")

            new_tmux_session(env, detach_session, 80, 24)
            run(env, [*TMUX_ARGS, "set-window-option", "-t", detach_session, "remain-on-exit", "on"])
            run(env, [*TMUX_ARGS, "send-keys", "-t", detach_session, f"PS1={shlex.quote(PROMPT)} exec /bin/sh", "Enter"])
            wait_capture(env, detach_session, PROMPT)
            run(env, [*TMUX_ARGS, "send-keys", "-t", detach_session, f"{sessh_cmd} attach", "Enter"])
            wait_capture(env, detach_session, "REMOTE_PROMPT$")
            run(env, [*TMUX_ARGS, "send-keys", "-t", detach_session, "spam", "Enter"])
            wait_capture(env, detach_session, "REMOTE_SPAM_")
            run(env, [*TMUX_ARGS, "send-keys", "-t", detach_session, "C-a", "d"])
            time.sleep(0.5)
            immediate_after_detach = capture_visible(env, detach_session)
            if "REMOTE_SPAM_" not in immediate_after_detach:
                raise AssertionError(f"detach did not leave flowing output visible:\n{immediate_after_detach}")
            run(env, [*TMUX_ARGS, "send-keys", "-t", detach_session, "printf 'OUTER_SPAM_DETACHED\\n'", "Enter"])
            detached = wait_capture(env, detach_session, "OUTER_SPAM_DETACHED", timeout=10.0)
            visible_after_detach = capture_visible(env, detach_session)
            if not visible_after_detach.strip():
                raise AssertionError(f"detach left a blank visible pane:\n{detached}")
            if "REMOTE_SPAM_" not in detached:
                raise AssertionError(f"detach lost flowing output from scrollback:\n{detached}")

            new_tmux_session(env, alt_detach_session, 80, 24)
            run(env, [*TMUX_ARGS, "set-window-option", "-t", alt_detach_session, "remain-on-exit", "on"])
            run(env, [*TMUX_ARGS, "send-keys", "-t", alt_detach_session, f"PS1={shlex.quote(PROMPT)} exec /bin/sh", "Enter"])
            wait_capture(env, alt_detach_session, PROMPT)
            run(env, [*TMUX_ARGS, "send-keys", "-t", alt_detach_session, sessh_cmd, "Enter"])
            wait_capture(env, alt_detach_session, "REMOTE_PROMPT$")
            run(env, [*TMUX_ARGS, "send-keys", "-t", alt_detach_session, "enter-alt", "Enter"])
            wait_capture(env, alt_detach_session, "ALT_SCREEN_READY")
            run(env, [*TMUX_ARGS, "send-keys", "-t", alt_detach_session, "C-a", "d"])
            time.sleep(0.5)
            alt_after = capture_visible(env, alt_detach_session)
            if "ALT_SCREEN_READY" in alt_after:
                raise AssertionError(f"detach left alternate-screen contents visible:\n{alt_after}")
            run(env, [*TMUX_ARGS, "send-keys", "-t", alt_detach_session, "printf 'OUTER_ALT_DETACHED\\n'", "Enter"])
            wait_capture(env, alt_detach_session, "OUTER_ALT_DETACHED")
        finally:
            for tmux_session in (session, detach_session, f"{detach_session}-idle", alt_detach_session, bottom_session):
                subprocess.run(
                    [*TMUX_ARGS, "kill-session", "-t", tmux_session],
                    cwd=ROOT,
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
            cleanup_runtime(env)

    print("ok ssh reconnect banner is temporary and detach returns to the outer prompt")


if __name__ == "__main__":
    main()
