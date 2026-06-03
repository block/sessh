#!/usr/bin/env python3
import os
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
import stat
from pathlib import Path

from harness_cleanup import cleanup_runtime, kill_all
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("SESSH_BIN", str(ROOT / "zig-out" / "bin" / "sessh")))
COMMAND_BIN = BIN
TMUX = shutil.which("tmux")
TMUX_ARGS = [TMUX, "-L", f"sessh-test-{os.getpid()}"] if TMUX else []
HARNESS_PROMPT = "SESSH_TEST>"
FAKE_SHELL_NAME = "fake-shell"
COMMAND_SHELL_NAME = "command-shell"
FIRST_PATCH_SHELL_NAME = "first-patch-shell"
NEWLINE_PROMPT_SHELL_NAME = "newline-prompt-shell"
LINE_EDIT_SHELL_NAME = "line-edit-shell"
ALT_SCREEN_SHELL_NAME = "alt-screen-shell"
CLEAR_BELOW_SHELL_NAME = "clear-below-shell"
CLEAR_SCROLL_SHELL_NAME = "clear-scroll-shell"
RESET_SCROLL_SHELL_NAME = "reset-scroll-shell"
REDRAW_PROMPT_SHELL_NAME = "redraw-prompt-shell"
PROMPT_CLEAR_SHELL_NAME = "prompt-clear-shell"
QUERY_RESPONSE_SHELL_NAME = "query-response-shell"
MOUSE_INPUT_SHELL_NAME = "mouse-input-shell"


def sessh_args(*args):
    if BIN.name == "sesshmux-dev" and COMMAND_BIN == BIN:
        return [str(BIN), ":internal-sessh:", *args]
    return [str(COMMAND_BIN), *args]


def sesshmux_local_args(*extra):
    if extra and extra[0] == "attach":
        return [str(BIN), "attach", *extra[1:]]
    return [str(BIN), "new", *extra, "."]


def configure_command_bin(env):
    global COMMAND_BIN
    if BIN.name != "sesshmux-dev":
        COMMAND_BIN = BIN
        return
    wrapper = Path(env["HOME"]) / "s"
    wrapper.write_text(
        "#!/bin/sh\n"
        f"exec {shlex.quote(str(BIN))} :internal-sessh: \"$@\"\n"
    )
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR)
    COMMAND_BIN = wrapper


def run(args, **kwargs):
    return subprocess.run(
        args,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
        **kwargs,
    )


XDG_ENV_KEYS = (
    "HOME",
    "XDG_RUNTIME_DIR",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
)


def env_assignments(env):
    return [f"{key}={env[key]}" for key in XDG_ENV_KEYS]


def quoted_env_assignments(env):
    return [f"{key}={shlex.quote(env[key])}" for key in XDG_ENV_KEYS]


def shell_command_args(env, prompt_env=None):
    args = [
        "env",
        *env_assignments(env),
        "SHELL=/bin/sh",
        f"PS1={HARNESS_PROMPT}",
    ]
    if prompt_env is not None:
        args.append(f"ENV={prompt_env}")
    args.append("/bin/sh")
    return args


def sessh_command(env, *extra, shell="/bin/sh"):
    parts = [
        "env",
        *quoted_env_assignments(env),
        f"SHELL={shlex.quote(str(shell))}",
        f"PS1={shlex.quote(HARNESS_PROMPT)}",
    ]
    parts.extend(shlex.quote(str(arg)) for arg in sesshmux_local_args(*extra))
    return " ".join(parts)


def home_shell_command(name, *extra):
    args = [f"SHELL=~/{name}"]
    args.extend(shlex.quote(str(arg)) for arg in sesshmux_local_args(*extra))
    return " ".join(args)


def capture(session):
    return run([*TMUX_ARGS, "capture-pane", "-p", "-S", "-200", "-t", session]).stdout


def capture_visible(session):
    return run([*TMUX_ARGS, "capture-pane", "-p", "-t", session]).stdout


def normalize_home(text, env):
    return text.replace(env["HOME"], "~")


def wait_capture(session, needle, timeout=10.0):
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        last = capture(session)
        if needle in last:
            return last
        time.sleep(0.1)
    raise AssertionError(f"did not see {needle!r}; pane contained:\n{last}")


def wait_capture_prefix(session, expected_lines, env, timeout=10.0):
    end = time.monotonic() + timeout
    last = ""
    normalized_expected = [normalize_home(line, env) for line in expected_lines]
    while time.monotonic() < end:
        last = normalize_home(capture(session), env)
        if last.splitlines()[: len(normalized_expected)] == normalized_expected:
            return last
        time.sleep(0.05)
    raise AssertionError(
        "did not see expected pane prefix:\n"
        + "\n".join(normalized_expected)
        + "\npane contained:\n"
        + last
    )


def wait_capture_count(session, needle, count, timeout=10.0):
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        last = capture(session)
        if last.count(needle) >= count:
            return last
        time.sleep(0.1)
    raise AssertionError(f"did not see {count} copies of {needle!r}; pane contained:\n{last}")


def wait_pane_dead(session, timeout=10.0):
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        result = subprocess.run(
            [*TMUX_ARGS, "display-message", "-p", "-t", session, "#{pane_dead}"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            return
        last = result.stdout.strip()
        if last == "1":
            return
        time.sleep(0.1)
    raise AssertionError(f"pane did not exit; pane_dead={last!r}")


def assert_equal(actual, expected):
    if actual == expected:
        return
    actual_lines = actual.splitlines()
    expected_lines = expected.splitlines()
    for index, (actual_line, expected_line) in enumerate(zip(actual_lines, expected_lines), start=1):
        if actual_line != expected_line:
            raise AssertionError(
                f"pane differed at line {index}\n"
                f"expected: {expected_line!r}\n"
                f"actual:   {actual_line!r}\n"
                f"full pane:\n{actual}"
            )
    raise AssertionError(
        f"pane had {len(actual_lines)} lines, expected {len(expected_lines)} lines\n"
        f"full pane:\n{actual}"
    )


def assert_equal_normalized(actual, expected, env):
    assert_equal(normalize_home(actual, env), normalize_home(expected, env))


def main():
    if TMUX is None:
        raise SystemExit("missing tmux")
    if not BIN.exists():
        raise SystemExit(f"missing binary: {BIN}")

    session = f"sessh-{os.getpid()}"
    restore_session = f"{session}-restore"
    scrollback_session = f"{session}-scrollback"
    fake_shell_session = f"{session}-fake-shell"
    first_patch_session = f"{session}-first-patch"
    newline_prompt_session = f"{session}-newline-prompt"
    line_edit_session = f"{session}-line-edit"
    alt_screen_session = f"{session}-alt-screen"
    alt_screen_exit_session = f"{session}-alt-screen-exit"
    clear_below_session = f"{session}-clear-below"
    clear_scroll_session = f"{session}-clear-scroll"
    reset_scroll_session = f"{session}-reset-scroll"
    redraw_prompt_session = f"{session}-redraw-prompt"
    prompt_clear_session = f"{session}-prompt-clear"
    query_response_session = f"{session}-query-response"
    mouse_input_session = f"{session}-mouse-input"
    repaint_session = f"{session}-repaint"
    with tempfile.TemporaryDirectory(prefix="sessh-tmux-", dir="/tmp") as tmp:
        env = isolated_env(tmp)
        configure_command_bin(env)
        prompt_env = Path(env["HOME"]) / "shenv"
        fake_shell = Path(env["HOME"]) / FAKE_SHELL_NAME
        command_shell = Path(env["HOME"]) / COMMAND_SHELL_NAME
        first_patch_shell = Path(env["HOME"]) / FIRST_PATCH_SHELL_NAME
        newline_prompt_shell = Path(env["HOME"]) / NEWLINE_PROMPT_SHELL_NAME
        line_edit_shell = Path(env["HOME"]) / LINE_EDIT_SHELL_NAME
        alt_screen_shell = Path(env["HOME"]) / ALT_SCREEN_SHELL_NAME
        clear_below_shell = Path(env["HOME"]) / CLEAR_BELOW_SHELL_NAME
        clear_scroll_shell = Path(env["HOME"]) / CLEAR_SCROLL_SHELL_NAME
        reset_scroll_shell = Path(env["HOME"]) / RESET_SCROLL_SHELL_NAME
        redraw_prompt_shell = Path(env["HOME"]) / REDRAW_PROMPT_SHELL_NAME
        prompt_clear_shell = Path(env["HOME"]) / PROMPT_CLEAR_SHELL_NAME
        query_response_shell = Path(env["HOME"]) / QUERY_RESPONSE_SHELL_NAME
        mouse_input_shell = Path(env["HOME"]) / MOUSE_INPUT_SHELL_NAME
        prompt_env.write_text(f"PS1='{HARNESS_PROMPT}'\n")
        fake_shell.write_text(
            "#!/bin/sh\n"
            "printf '%*s\\r' 1 ''\n"
            "sleep 0.2\n"
            "printf 'FAKE_PROMPT$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '%s\\n' \"$line\"\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "  printf 'FAKE_PROMPT$ '\n"
            "done\n"
        )
        fake_shell.chmod(fake_shell.stat().st_mode | stat.S_IXUSR)
        command_shell.write_text(
            "#!/bin/sh\n"
            f"printf '{HARNESS_PROMPT}'\n"
            "while IFS= read -r line; do\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "  eval \"$line\"\n"
            f"  printf '{HARNESS_PROMPT}'\n"
            "done\n"
        )
        command_shell.chmod(command_shell.stat().st_mode | stat.S_IXUSR)
        first_patch_shell.write_text(
            "#!/bin/sh\n"
            "sleep 0.4\n"
            "printf 'FIRST_PATCH$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '%s\\n' \"$line\"\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "  printf 'FIRST_PATCH$ '\n"
            "done\n"
        )
        first_patch_shell.chmod(first_patch_shell.stat().st_mode | stat.S_IXUSR)
        newline_prompt_shell.write_text(
            "#!/bin/sh\n"
            "printf '\\nNEWLINE_PROMPT$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '%s\\n' \"$line\"\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "  printf '\\nNEWLINE_PROMPT$ '\n"
            "done\n"
        )
        newline_prompt_shell.chmod(newline_prompt_shell.stat().st_mode | stat.S_IXUSR)
        line_edit_shell.write_text(
            "#!/bin/sh\n"
            "printf 'EDIT_BEGIN\\n'\n"
            "printf 'ABCDE'\n"
            "sleep 0.2\n"
            "printf '\\r12\\033[K\\n'\n"
            "printf 'EDIT_DONE\\n'\n"
        )
        line_edit_shell.chmod(line_edit_shell.stat().st_mode | stat.S_IXUSR)
        alt_screen_shell.write_text(
            "#!/bin/sh\n"
            "printf 'ALT_READY$ '\n"
            "while IFS= read -r line; do\n"
            "  case \"$line\" in\n"
            "    leave)\n"
            "      printf '\\033[?1049hALT_TRANSIENT\\033[?1049lPRIMARY_AFTER_ALT\\nALT_READY$ '\n"
            "      ;;\n"
            "    *)\n"
            "      printf '\\033[?1049hALT_SCREEN'\n"
            "      sleep 5\n"
            "      ;;\n"
            "  esac\n"
            "done\n"
        )
        alt_screen_shell.chmod(alt_screen_shell.stat().st_mode | stat.S_IXUSR)
        clear_below_shell.write_text(
            "#!/bin/sh\n"
            "printf '\\033[J'\n"
            "printf 'CLEAR_BELOW$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '%s\\n' \"$line\"\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "  printf 'CLEAR_BELOW$ '\n"
            "done\n"
        )
        clear_below_shell.chmod(clear_below_shell.stat().st_mode | stat.S_IXUSR)
        clear_scroll_shell.write_text(
            "#!/bin/sh\n"
            "printf '\\033[2J\\033[H'\n"
            "i=1\n"
            "while [ \"$i\" -le 40 ]; do\n"
            "  printf 'CLEAR_SCROLL_%02d\\n' \"$i\"\n"
            "  i=$((i + 1))\n"
            "done\n"
            "printf 'CLEAR_SCROLL_DONE:%s\\n' \"${SESSH_GUID:-missing}\"\n"
        )
        clear_scroll_shell.chmod(clear_scroll_shell.stat().st_mode | stat.S_IXUSR)
        reset_scroll_shell.write_text(
            "#!/bin/sh\n"
            "printf '\\033[2J\\033[HMAIN_SCREEN_MARKER'\n"
            "printf '\\033[?1049h\\033[2J\\033[HALT_SCREEN\\033[?1049l'\n"
            "printf '\\033[?1049h\\033[3;3H\\033[?1049l'\n"
            "printf '\\033c'\n"
            "printf 'RIS_REPORT\\nRIS_DONE:%s\\n' \"${SESSH_GUID:-missing}\"\n"
        )
        reset_scroll_shell.chmod(reset_scroll_shell.stat().st_mode | stat.S_IXUSR)
        redraw_prompt_shell.write_text(
            "#!/bin/sh\n"
            "printf '%*s\\r \\r\\r\\033[J' 80 ''\n"
            "printf 'REDRAW_TOP\\nREDRAW_BOTTOM$ '\n"
            "printf '\\r\\033[A\\r\\033[J'\n"
            "printf 'REDRAW_TOP\\nREDRAW_BOTTOM$ '\n"
            "while IFS= read -r line; do\n"
            "  printf '%s\\n' \"$line\"\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "  printf 'REDRAW_TOP\\nREDRAW_BOTTOM$ '\n"
            "done\n"
        )
        redraw_prompt_shell.chmod(redraw_prompt_shell.stat().st_mode | stat.S_IXUSR)
        prompt_clear_shell.write_text(
            "#!/bin/sh\n"
            "draw_prompt() {\n"
            "  printf '%*s\\r \\r\\r\\033[J' 80 ''\n"
            "  printf 'PROMPT_CLEAR_TOP\\nPROMPT_CLEAR$ '\n"
            "  printf '\\r\\r\\033[A\\033[J'\n"
            "  printf 'PROMPT_CLEAR_TOP\\nPROMPT_CLEAR$ '\n"
            "}\n"
            "draw_prompt\n"
            "while IFS= read -r line; do\n"
            "  [ \"$line\" = exit ] && exit 0\n"
            "  eval \"$line\"\n"
            "  draw_prompt\n"
            "done\n"
        )
        prompt_clear_shell.chmod(prompt_clear_shell.stat().st_mode | stat.S_IXUSR)
        query_response_shell.write_text(
            "#!/bin/sh\n"
            "stty raw -echo\n"
            "printf '\\033[3;5H\\033[6n'\n"
            "response=$(dd bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \\n')\n"
            "stty sane\n"
            "printf '\\r\\nQUERY_RESPONSE:%s\\r\\n' \"$response\"\n"
        )
        query_response_shell.chmod(query_response_shell.stat().st_mode | stat.S_IXUSR)
        mouse_input_shell.write_text(
            "#!/usr/bin/env python3\n"
            "import os\n"
            "import re\n"
            "import sys\n"
            "import termios\n"
            "import tty\n"
            "\n"
            "sys.stdout.write('\\033[?1000;1006hMOUSE_READY\\n')\n"
            "sys.stdout.flush()\n"
            "fd = sys.stdin.fileno()\n"
            "old = termios.tcgetattr(fd)\n"
            "tty.setraw(fd)\n"
            "data = b''\n"
            "try:\n"
            "    while not data.endswith((b'M', b'm')):\n"
            "        chunk = os.read(fd, 1)\n"
            "        if not chunk:\n"
            "            break\n"
            "        data += chunk\n"
            "finally:\n"
            "    termios.tcsetattr(fd, termios.TCSADRAIN, old)\n"
            "\n"
            "match = re.fullmatch(rb'\\x1b\\[<(\\d+);(\\d+);(\\d+)([Mm])', data)\n"
            "if match is None:\n"
            "    sys.stdout.write('\\r\\nMOUSE_REPORT_INVALID:%s\\r\\n' % data.hex())\n"
            "else:\n"
            "    button, col, row, suffix = match.groups()\n"
            "    sys.stdout.write(\n"
            "        '\\r\\nMOUSE_REPORT:%s;%s;%s%s\\r\\n'\n"
            "        % (button.decode(), col.decode(), row.decode(), suffix.decode())\n"
            "    )\n"
            "sys.stdout.flush()\n"
        )
        mouse_input_shell.chmod(mouse_input_shell.stat().st_mode | stat.S_IXUSR)
        cleanup_runtime(env)
        try:
            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    sessh_command(env, shell=command_shell),
                ]
            )
            run([*TMUX_ARGS, "set-window-option", "-t", session, "remain-on-exit", "on"])

            wait_capture(session, HARNESS_PROMPT)
            run([*TMUX_ARGS, "send-keys", "-t", session, "echo sessh_tmux_before", "Enter"])
            wait_capture_count(session, "sessh_tmux_before", 2)

            detached_marker = "sessh_detached_line_60"
            run(
                [
                    *TMUX_ARGS,
                    "send-keys",
                    "-t",
                    session,
                    "sh -c 'sleep 1; i=1; while [ \"$i\" -le 60 ]; do printf \"sessh_detached_line_%02d\\n\" \"$i\"; i=$((i + 1)); done'",
                    "Enter",
                ]
            )
            wait_capture(session, "done'")
            time.sleep(0.2)
            run([*TMUX_ARGS, "send-keys", "-t", session, "Enter", "~d"])
            wait_pane_dead(session)
            time.sleep(1.2)

            run(
                [
                    *TMUX_ARGS,
                    "respawn-pane",
                    "-k",
                    "-t",
                    session,
                    sessh_command(env, "attach", shell=command_shell),
                ]
            )
            wait_capture(session, detached_marker)
            detached_capture = capture(session)
            if "sessh_detached_line_01" not in detached_capture:
                raise AssertionError(f"attach did not render retained detached scrollback:\n{detached_capture}")
            run([*TMUX_ARGS, "send-keys", "-t", session, "echo sessh_tmux_after", "Enter"])
            wait_capture_count(session, "sessh_tmux_after", 2)

            run(
                [
                    *TMUX_ARGS,
                    "resize-window",
                    "-t",
                    session,
                    "-x",
                    "100",
                    "-y",
                    "30",
                ]
            )
            pane_size = run([*TMUX_ARGS, "display-message", "-p", "-t", session, "#{pane_height} #{pane_width}"]).stdout.strip()
            if pane_size != "30 100":
                raise AssertionError(f"tmux pane size was {pane_size!r}, expected '30 100'")
            time.sleep(0.3)
            run(
                [
                    *TMUX_ARGS,
                    "send-keys",
                    "-t",
                    session,
                    "printf 'SIZE:%s\\n' \"$(stty size)\"",
                    "Enter",
                ]
            )
            wait_capture(session, "SIZE:30 100")

            run([*TMUX_ARGS, "send-keys", "-t", session, "exit", "Enter"])
            subprocess.run(
                [*TMUX_ARGS, "kill-session", "-t", session],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    restore_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    "/bin/sh",
                    "-c",
                    f"{sessh_command(env, shell=command_shell)}; stty -a | tr ' ;' '\\n\\n' | grep -x echo >/dev/null && echo sessh_tty_restored; sleep 2",
                ]
            )
            wait_capture(restore_session, HARNESS_PROMPT)
            run([*TMUX_ARGS, "send-keys", "-t", restore_session, "exit", "Enter"])
            wait_capture(restore_session, "sessh_tty_restored")

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    scrollback_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(scrollback_session, HARNESS_PROMPT)
            scrollback_command = "for i in $(seq 1 100); do printf 'outer_pre_%03d\\n' \"$i\"; done"
            run(
                [
                    *TMUX_ARGS,
                    "send-keys",
                    "-t",
                    scrollback_session,
                    scrollback_command,
                    "Enter",
                ]
            )
            wait_capture(scrollback_session, "outer_pre_100")
            prompt_count = capture(scrollback_session).count(HARNESS_PROMPT)
            scrollback_sessh_command = home_shell_command(COMMAND_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", scrollback_session, scrollback_sessh_command, "Enter"])
            wait_capture_count(scrollback_session, HARNESS_PROMPT, prompt_count + 1)
            run([*TMUX_ARGS, "send-keys", "-t", scrollback_session, "echo sessh_scrollback_preserved", "Enter"])
            wait_capture_count(scrollback_session, "sessh_scrollback_preserved", 2)
            run([*TMUX_ARGS, "send-keys", "-t", scrollback_session, "exit", "Enter"])
            time.sleep(0.3)
            scrollback = capture(scrollback_session)
            expected_scrollback_lines = (
                [f"{HARNESS_PROMPT}{scrollback_command}"]
                + [f"outer_pre_{i:03d}" for i in range(1, 101)]
                + [
                    f"{HARNESS_PROMPT}{scrollback_sessh_command}",
                    f"{HARNESS_PROMPT}echo sessh_scrollback_preserved",
                    "sessh_scrollback_preserved",
                    f"{HARNESS_PROMPT}exit",
                    HARNESS_PROMPT,
                ]
            )
            assert_equal(scrollback, "\n".join(expected_scrollback_lines) + "\n")

            kill_all(env)

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    fake_shell_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(fake_shell_session, HARNESS_PROMPT)
            fake_shell_preamble = "for i in $(seq 1 100); do printf 'fake_pre_%03d\\n' \"$i\"; done"
            run([*TMUX_ARGS, "send-keys", "-t", fake_shell_session, fake_shell_preamble, "Enter"])
            wait_capture(fake_shell_session, "fake_pre_100")
            fake_shell_command = home_shell_command(FAKE_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", fake_shell_session, fake_shell_command, "Enter"])
            wait_capture(fake_shell_session, "FAKE_PROMPT$")
            run([*TMUX_ARGS, "send-keys", "-t", fake_shell_session, "exit", "Enter"])
            time.sleep(0.3)
            fake_shell_scrollback = capture(fake_shell_session)
            expected_fake_shell_lines = (
                [f"{HARNESS_PROMPT}{fake_shell_preamble}"]
                + [f"fake_pre_{i:03d}" for i in range(1, 101)]
                + [
                    f"{HARNESS_PROMPT}{fake_shell_command}",
                    "FAKE_PROMPT$ exit",
                    "exit",
                    HARNESS_PROMPT,
                ]
            )
            assert_equal_normalized(fake_shell_scrollback, "\n".join(expected_fake_shell_lines) + "\n", env)

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    clear_below_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(clear_below_session, HARNESS_PROMPT)
            clear_below_preamble = "for i in $(seq 1 40); do printf 'clear_below_pre_%02d\\n' \"$i\"; done"
            run([*TMUX_ARGS, "send-keys", "-t", clear_below_session, clear_below_preamble, "Enter"])
            wait_capture(clear_below_session, "clear_below_pre_40")
            clear_below_command = home_shell_command(CLEAR_BELOW_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", clear_below_session, clear_below_command, "Enter"])
            wait_capture(clear_below_session, "CLEAR_BELOW$")
            clear_below_visible = capture_visible(clear_below_session)
            if "clear_below_pre_40" not in clear_below_visible:
                raise AssertionError(
                    "inner clear-below display op cleared the outer visible pane:\n"
                    f"{clear_below_visible}"
                )
            clear_below_scrollback = capture(clear_below_session)
            if "clear_below_pre_40" not in clear_below_scrollback:
                raise AssertionError(
                    "inner clear-below display op removed outer scrollback:\n"
                    f"{clear_below_scrollback}"
                )
            run([*TMUX_ARGS, "send-keys", "-t", clear_below_session, "exit", "Enter"])
            time.sleep(0.3)
            subprocess.run(
                [*TMUX_ARGS, "kill-session", "-t", clear_below_session],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    clear_scroll_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(clear_scroll_session, HARNESS_PROMPT)
            clear_scroll_command = home_shell_command(CLEAR_SCROLL_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", clear_scroll_session, clear_scroll_command, "Enter"])
            wait_capture(clear_scroll_session, "CLEAR_SCROLL_DONE:")
            clear_scroll_capture = capture(clear_scroll_session)
            for i in range(1, 41):
                line = f"CLEAR_SCROLL_{i:02d}"
                if clear_scroll_capture.count(line) != 1:
                    raise AssertionError(
                        f"expected one copy of {line} after clear-then-scroll output:\n"
                        f"{clear_scroll_capture}"
                    )
            if clear_scroll_capture.count("CLEAR_SCROLL_DONE:") != 1:
                raise AssertionError(f"missing clear-scroll completion marker:\n{clear_scroll_capture}")
            subprocess.run(
                [*TMUX_ARGS, "kill-session", "-t", clear_scroll_session],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    reset_scroll_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(reset_scroll_session, HARNESS_PROMPT)
            reset_scroll_command = home_shell_command(RESET_SCROLL_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", reset_scroll_session, reset_scroll_command, "Enter"])
            wait_capture(reset_scroll_session, "RIS_DONE:")
            reset_scroll_capture = capture(reset_scroll_session)
            # Tmux itself keeps primary-screen text that was committed before
            # an alternate-screen switch in capture-pane history, even after
            # RIS. The important leak check here is that alternate-screen
            # content does not become primary scrollback.
            if reset_scroll_capture.count("RIS_REPORT") != 1 or reset_scroll_capture.count("RIS_DONE:") != 1:
                raise AssertionError(f"missing post-reset output:\n{reset_scroll_capture}")
            if "ALT_SCREEN" in reset_scroll_capture:
                raise AssertionError(f"alternate-screen content leaked into scrollback:\n{reset_scroll_capture}")
            subprocess.run(
                [*TMUX_ARGS, "kill-session", "-t", reset_scroll_session],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    redraw_prompt_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(redraw_prompt_session, HARNESS_PROMPT)
            redraw_prompt_command = home_shell_command(REDRAW_PROMPT_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", redraw_prompt_session, redraw_prompt_command, "Enter"])
            wait_capture_prefix(
                redraw_prompt_session,
                [
                    f"{HARNESS_PROMPT}{redraw_prompt_command}",
                    "REDRAW_TOP",
                    "REDRAW_BOTTOM$",
                ],
                env,
            )
            run([*TMUX_ARGS, "send-keys", "-t", redraw_prompt_session, "exit", "Enter"])
            time.sleep(0.3)
            redraw_prompt_capture = capture(redraw_prompt_session)
            expected_redraw_prompt_lines = [
                f"{HARNESS_PROMPT}{redraw_prompt_command}",
                "REDRAW_TOP",
                "REDRAW_BOTTOM$ exit",
                "exit",
                HARNESS_PROMPT,
            ]
            expected_redraw_prompt_lines.extend([""] * (24 - len(expected_redraw_prompt_lines)))
            assert_equal_normalized(
                redraw_prompt_capture,
                "\n".join(expected_redraw_prompt_lines) + "\n",
                env,
            )
            subprocess.run(
                [*TMUX_ARGS, "kill-session", "-t", redraw_prompt_session],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    prompt_clear_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(prompt_clear_session, HARNESS_PROMPT)
            prompt_clear_command = home_shell_command(PROMPT_CLEAR_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", prompt_clear_session, prompt_clear_command, "Enter"])
            wait_capture(prompt_clear_session, "PROMPT_CLEAR$")
            run([*TMUX_ARGS, "send-keys", "-t", prompt_clear_session, "echo prompt_clear_once", "Enter"])
            wait_capture_count(prompt_clear_session, "PROMPT_CLEAR$", 2)
            run([*TMUX_ARGS, "send-keys", "-t", prompt_clear_session, "exit", "Enter"])
            time.sleep(0.3)
            prompt_clear_capture = capture(prompt_clear_session)
            expected_prompt_clear_lines = [
                f"{HARNESS_PROMPT}{prompt_clear_command}",
                "PROMPT_CLEAR_TOP",
                "PROMPT_CLEAR$ echo prompt_clear_once",
                "prompt_clear_once",
                "PROMPT_CLEAR_TOP",
                "PROMPT_CLEAR$ exit",
                HARNESS_PROMPT,
            ]
            expected_prompt_clear_lines.extend([""] * (24 - len(expected_prompt_clear_lines)))
            assert_equal_normalized(
                prompt_clear_capture,
                "\n".join(expected_prompt_clear_lines) + "\n",
                env,
            )
            subprocess.run(
                [*TMUX_ARGS, "kill-session", "-t", prompt_clear_session],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    first_patch_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(first_patch_session, HARNESS_PROMPT)
            first_patch_preamble = "for i in $(seq 1 100); do printf 'first_patch_pre_%03d\\n' \"$i\"; done"
            run([*TMUX_ARGS, "send-keys", "-t", first_patch_session, first_patch_preamble, "Enter"])
            wait_capture(first_patch_session, "first_patch_pre_100")
            first_patch_command = home_shell_command(FIRST_PATCH_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", first_patch_session, first_patch_command, "Enter"])
            wait_capture(first_patch_session, "FIRST_PATCH$")
            run([*TMUX_ARGS, "send-keys", "-t", first_patch_session, "exit", "Enter"])
            time.sleep(0.3)
            first_patch_capture = capture(first_patch_session)
            expected_first_patch_lines = (
                [f"{HARNESS_PROMPT}{first_patch_preamble}"]
                + [f"first_patch_pre_{i:03d}" for i in range(1, 101)]
                + [
                    f"{HARNESS_PROMPT}{first_patch_command}",
                    "FIRST_PATCH$ exit",
                    "exit",
                    HARNESS_PROMPT,
                ]
            )
            assert_equal_normalized(first_patch_capture, "\n".join(expected_first_patch_lines) + "\n", env)

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    newline_prompt_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(newline_prompt_session, HARNESS_PROMPT)
            newline_prompt_preamble = "for i in $(seq 1 100); do printf 'newline_pre_%03d\\n' \"$i\"; done"
            run([*TMUX_ARGS, "send-keys", "-t", newline_prompt_session, newline_prompt_preamble, "Enter"])
            wait_capture(newline_prompt_session, "newline_pre_100")
            newline_prompt_command = home_shell_command(NEWLINE_PROMPT_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", newline_prompt_session, newline_prompt_command, "Enter"])
            wait_capture(newline_prompt_session, "NEWLINE_PROMPT$")
            run([*TMUX_ARGS, "send-keys", "-t", newline_prompt_session, "exit", "Enter"])
            time.sleep(0.3)
            newline_prompt_scrollback = capture(newline_prompt_session)
            expected_newline_prompt_lines = (
                [f"{HARNESS_PROMPT}{newline_prompt_preamble}"]
                + [f"newline_pre_{i:03d}" for i in range(1, 101)]
                + [
                    f"{HARNESS_PROMPT}{newline_prompt_command}",
                    "",
                    "NEWLINE_PROMPT$ exit",
                    "exit",
                    HARNESS_PROMPT,
                ]
            )
            assert_equal_normalized(newline_prompt_scrollback, "\n".join(expected_newline_prompt_lines) + "\n", env)

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    line_edit_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(line_edit_session, HARNESS_PROMPT)
            line_edit_preamble = "for i in $(seq 1 100); do printf 'line_pre_%03d\\n' \"$i\"; done"
            run([*TMUX_ARGS, "send-keys", "-t", line_edit_session, line_edit_preamble, "Enter"])
            wait_capture(line_edit_session, "line_pre_100")
            line_edit_command = home_shell_command(LINE_EDIT_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", line_edit_session, line_edit_command, "Enter"])
            wait_capture(line_edit_session, "EDIT_DONE")
            time.sleep(0.3)
            line_edit_scrollback = capture(line_edit_session)
            expected_line_edit_lines = (
                [f"{HARNESS_PROMPT}{line_edit_preamble}"]
                + [f"line_pre_{i:03d}" for i in range(1, 101)]
                + [
                    f"{HARNESS_PROMPT}{line_edit_command}",
                    "EDIT_BEGIN",
                    "12",
                    "EDIT_DONE",
                    HARNESS_PROMPT,
                ]
            )
            assert_equal_normalized(line_edit_scrollback, "\n".join(expected_line_edit_lines) + "\n", env)

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    alt_screen_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            run([*TMUX_ARGS, "set-window-option", "-t", alt_screen_session, "remain-on-exit", "on"])
            wait_capture(alt_screen_session, HARNESS_PROMPT)
            alt_screen_prompt_count = capture(alt_screen_session).count(HARNESS_PROMPT)
            alt_screen_command = home_shell_command(ALT_SCREEN_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", alt_screen_session, alt_screen_command, "Enter"])
            wait_capture(alt_screen_session, "ALT_READY$")
            run([*TMUX_ARGS, "send-keys", "-t", alt_screen_session, "go", "Enter"])
            wait_capture(alt_screen_session, "ALT_SCREEN")
            run([*TMUX_ARGS, "send-keys", "-t", alt_screen_session, "Enter", "~d"])
            wait_capture_count(alt_screen_session, HARNESS_PROMPT, alt_screen_prompt_count + 1)
            alt_screen_capture = capture(alt_screen_session)
            if "ALT_SCREEN" in alt_screen_capture:
                raise AssertionError(f"detach left tmux on the remote alternate screen:\n{alt_screen_capture}")
            if alt_screen_command not in alt_screen_capture or "ALT_READY$ go" not in alt_screen_capture:
                raise AssertionError(f"detach did not restore the primary screen:\n{alt_screen_capture}")
            alt_screen_unwrapped = alt_screen_capture.replace("\n", "")
            if (
                "sessh: detached" not in alt_screen_capture
                or "Re-attach: `sesshmux attach" not in alt_screen_unwrapped
                or "Kill: `sesshmux kill" not in alt_screen_unwrapped
            ):
                raise AssertionError(f"detach did not print a reattach banner:\n{alt_screen_capture}")

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    alt_screen_exit_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(alt_screen_exit_session, HARNESS_PROMPT)
            alt_screen_exit_command = home_shell_command(ALT_SCREEN_SHELL_NAME)
            run([*TMUX_ARGS, "send-keys", "-t", alt_screen_exit_session, alt_screen_exit_command, "Enter"])
            wait_capture(alt_screen_exit_session, "ALT_READY$")
            run([*TMUX_ARGS, "send-keys", "-t", alt_screen_exit_session, "leave", "Enter"])
            wait_capture(alt_screen_exit_session, "PRIMARY_AFTER_ALT")
            alt_screen_exit_capture = capture(alt_screen_exit_session)
            if "ALT_TRANSIENT" in alt_screen_exit_capture:
                raise AssertionError(
                    "inner alternate-screen content survived after alternate-screen exit:\n"
                    f"{alt_screen_exit_capture}"
                )
            if "PRIMARY_AFTER_ALT" not in alt_screen_exit_capture:
                raise AssertionError(
                    "primary screen was not redrawn after alternate-screen exit:\n"
                    f"{alt_screen_exit_capture}"
                )

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    query_response_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(query_response_session, HARNESS_PROMPT)
            run(
                [
                    *TMUX_ARGS,
                    "send-keys",
                    "-t",
                    query_response_session,
                    home_shell_command(QUERY_RESPONSE_SHELL_NAME),
                    "Enter",
                ]
            )
            wait_capture(query_response_session, "QUERY_RESPONSE:1b5b333b3552")

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    mouse_input_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(mouse_input_session, HARNESS_PROMPT)
            run([*TMUX_ARGS, "send-keys", "-t", mouse_input_session, "printf 'OUTER_MOUSE_1\\nOUTER_MOUSE_2\\n'", "Enter"])
            wait_capture(mouse_input_session, "OUTER_MOUSE_2")
            run([*TMUX_ARGS, "send-keys", "-t", mouse_input_session, home_shell_command(MOUSE_INPUT_SHELL_NAME), "Enter"])
            wait_capture(mouse_input_session, "MOUSE_READY")
            mouse_lines = []
            outer_mouse_row = None
            end = time.monotonic() + 5.0
            while time.monotonic() < end:
                mouse_lines = capture_visible(mouse_input_session).splitlines()
                outer_mouse_row = next(
                    (index + 1 for index, line in enumerate(mouse_lines) if "MOUSE_READY" in line),
                    None,
                )
                if outer_mouse_row == 1:
                    break
                time.sleep(0.1)
            if outer_mouse_row is None:
                raise AssertionError(f"could not locate mouse-ready row:\n{capture_visible(mouse_input_session)}")
            if outer_mouse_row != 1:
                raise AssertionError(
                    "enabling mouse mode did not align the sessh viewport to the top of the outer terminal:\n"
                    f"{capture_visible(mouse_input_session)}"
                )
            run([*TMUX_ARGS, "send-keys", "-t", mouse_input_session, "Escape"])
            run([*TMUX_ARGS, "send-keys", "-l", "-t", mouse_input_session, f"[<0;12;{outer_mouse_row}M"])
            wait_capture(mouse_input_session, "MOUSE_REPORT:")
            mouse_capture = capture(mouse_input_session)
            if "MOUSE_REPORT:0;12;1M" not in mouse_capture:
                raise AssertionError(
                    "SGR mouse input was not translated from outer terminal "
                    f"row {outer_mouse_row} to inner row 1:\n{mouse_capture}"
                )

            run(
                [
                    *TMUX_ARGS,
                    "new-session",
                    "-d",
                    "-s",
                    repaint_session,
                    "-x",
                    "80",
                    "-y",
                    "24",
                    *shell_command_args(env, prompt_env),
                ]
            )
            wait_capture(repaint_session, HARNESS_PROMPT)
            repaint_preamble = "for i in $(seq 1 100); do printf 'repaint_pre_%03d\\n' \"$i\"; done"
            run([*TMUX_ARGS, "send-keys", "-t", repaint_session, repaint_preamble, "Enter"])
            wait_capture(repaint_session, "repaint_pre_100")
            repaint_command = home_shell_command(COMMAND_SHELL_NAME)
            prompt_count = capture(repaint_session).count(HARNESS_PROMPT)
            run([*TMUX_ARGS, "send-keys", "-t", repaint_session, repaint_command, "Enter"])
            wait_capture_count(repaint_session, HARNESS_PROMPT, prompt_count + 1)
            run([*TMUX_ARGS, "send-keys", "-t", repaint_session, "echo sessh_repaint_marker", "Enter"])
            wait_capture_count(repaint_session, "sessh_repaint_marker", 2)
            run([*TMUX_ARGS, "send-keys", "-t", repaint_session, "Enter", "~p"])
            time.sleep(0.3)
            repaint_capture = capture(repaint_session)
            if "sessh_repaint_marker" not in repaint_capture:
                raise AssertionError(f"repaint lost session content:\n{repaint_capture}")
            if f"{HARNESS_PROMPT}~p" in repaint_capture:
                raise AssertionError(f"repaint escape command was forwarded:\n{repaint_capture}")
            if "repaint_pre_100" in repaint_capture:
                raise AssertionError(f"repaint did not clear outer scrollback:\n{repaint_capture}")
            run([*TMUX_ARGS, "send-keys", "-t", repaint_session, "exit", "Enter"])
            time.sleep(0.3)
        finally:
            for tmux_session in (
                session,
                restore_session,
                scrollback_session,
                fake_shell_session,
                first_patch_session,
                newline_prompt_session,
                line_edit_session,
                alt_screen_session,
                alt_screen_exit_session,
                clear_below_session,
                clear_scroll_session,
                reset_scroll_session,
                redraw_prompt_session,
                prompt_clear_session,
                query_response_session,
                mouse_input_session,
                repaint_session,
            ):
                subprocess.run(
                    [*TMUX_ARGS, "kill-session", "-t", tmux_session],
                    cwd=ROOT,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                )
            subprocess.run(
                [*TMUX_ARGS, "kill-server"],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            cleanup_runtime(env)
            try:
                fake_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                command_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                first_patch_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                newline_prompt_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                line_edit_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                alt_screen_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                clear_below_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                clear_scroll_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                reset_scroll_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                redraw_prompt_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                prompt_clear_shell.unlink()
            except FileNotFoundError:
                pass
            try:
                query_response_shell.unlink()
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"tmux_harness: {exc}", file=sys.stderr)
        raise
