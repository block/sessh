#!/usr/bin/env python3
import difflib
import os
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

from harness_cleanup import cleanup_runtime
from test_env import isolated_env


ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("SESSH_BIN", str(ROOT / "zig-out" / "bin" / "sessh")))
TMUX = shutil.which("tmux")

XDG_ENV_KEYS = (
    "HOME",
    "XDG_RUNTIME_DIR",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
)


@dataclass(frozen=True)
class Probe:
    name: str
    payload: bytes
    expected_cursor: tuple[int, int] | None = None
    expected_capture: str | None = None
    normalize_capture_tabs: bool = False
    expected_styled_capture: str | None = None
    rows: int = 10
    cols: int = 40


@dataclass(frozen=True)
class PaneState:
    cursor: tuple[int, int]
    capture: str
    styled_capture: str


# Adapted from terminfo.dev's cursor.move.absolute probe.
def sgr_probe(name, payload, styled_capture):
    return Probe(
        name=name,
        payload=payload,
        expected_cursor=(1, 0),
        expected_capture="X\n\n\n",
        expected_styled_capture=styled_capture,
        rows=3,
        cols=20,
    )


def sgr_probe_xy(name, payload, styled_capture):
    return Probe(
        name=name,
        payload=payload,
        expected_cursor=(2, 0),
        expected_capture="XY\n\n\n",
        expected_styled_capture=styled_capture,
        rows=3,
        cols=30,
    )


def text_payload(value):
    return value.encode("utf-8")


PROBES = (
    Probe(
        name="cursor.move.absolute",
        payload=b"\x1b[5;10H",
        expected_cursor=(9, 4),
    ),
    Probe(
        name="cursor.move.home",
        payload=b"ABC\x1b[H",
        expected_cursor=(0, 0),
    ),
    Probe(
        name="cursor.move.forward",
        payload=b"\x1b[5C",
        expected_cursor=(5, 0),
    ),
    Probe(
        name="cursor.move.back",
        payload=b"ABC\x1b[2D",
        expected_cursor=(1, 0),
    ),
    Probe(
        name="cursor.move.down",
        payload=b"\x1b[3B",
        expected_cursor=(0, 3),
    ),
    Probe(
        name="cursor.move.up",
        payload=b"\x1b[5B\x1b[2A",
        expected_cursor=(0, 3),
    ),
    Probe(
        name="text.basic",
        payload=b"Hello",
        expected_cursor=(5, 0),
        expected_capture="Hello\n\n\n\n\n",
        rows=5,
    ),
    Probe(
        name="text.cr",
        payload=b"AB\rC",
        expected_cursor=(1, 0),
        expected_capture="CB\n\n\n\n\n",
        rows=5,
    ),
    Probe(
        name="text.backspace",
        payload=b"AB\x08C",
        expected_cursor=(2, 0),
        expected_capture="AC\n\n\n\n\n",
        rows=5,
    ),
    Probe(
        name="text.newline",
        payload=b"A\r\nB",
        expected_cursor=(1, 1),
        expected_capture="A\nB\n\n\n\n",
        rows=5,
    ),
    Probe(
        name="text.wrap",
        payload=b"X" * 41,
        expected_cursor=(1, 1),
        expected_capture=("X" * 40) + "\nX\n\n\n\n",
        rows=5,
        cols=40,
    ),
    Probe(
        name="cursor.horizontal-absolute",
        payload=b"ABCDE\x1b[3G",
        expected_cursor=(2, 0),
    ),
    Probe(
        name="cursor.next-line",
        payload=b"ABC\x1b[2E",
        expected_cursor=(0, 2),
    ),
    Probe(
        name="cursor.ansi-save",
        payload=b"\x1b[3;5H\x1b[s\x1b[10;15H\x1b[u",
        expected_cursor=(4, 2),
    ),
    Probe(
        name="cursor.ansi-restore",
        payload=b"\x1b[4;6H\x1b[s\x1b[12;18H\x1b[u",
        expected_cursor=(5, 3),
        rows=12,
    ),
    Probe(
        name="cursor.save-restore",
        payload=b"AB\x1b7\x1b[5;5H\x1b8",
        expected_cursor=(2, 0),
    ),
    Probe(
        name="cursor.cuu-past-top",
        payload=b"\x1b[4;1H\x1b[999A",
        expected_cursor=(0, 0),
    ),
    Probe(
        name="cursor.cud-past-bottom",
        payload=b"\x1b[1;1H\x1b[999B",
        expected_cursor=(0, 9),
    ),
    Probe(
        name="cursor.vpa",
        payload=b"\x1b[3;5H\x1b[10d",
        expected_cursor=(4, 9),
    ),
    Probe(
        name="cursor.cpl",
        payload=b"\x1b[6;10H\x1b[2F",
        expected_cursor=(0, 3),
    ),
    Probe(
        name="cursor.hpa",
        payload=b"ABCDEFGH\x1b[5`",
        expected_cursor=(4, 0),
    ),
    Probe(
        name="cursor.cup-scroll-region",
        payload=b"\x1b[5;10r\x1b[?6h\x1b[1;1H",
        expected_cursor=(0, 4),
    ),
    Probe(
        name="erase.line.right",
        payload=b"XXXXX\x1b[1G\x1b[K",
        expected_cursor=(0, 0),
        expected_capture="\n\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="erase.line.left",
        payload=b"XXXXX\x1b[3G\x1b[1K",
        expected_cursor=(2, 0),
        expected_capture="   XX\n\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="erase.line.all",
        payload=b"XXXXX\x1b[2K",
        expected_cursor=(5, 0),
        expected_capture="\n\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="erase.screen.below",
        payload=b"AAA\r\nBBB\r\nCCC\x1b[H\x1b[J",
        expected_cursor=(0, 0),
        expected_capture="AAA\nBBB\nCCC\n\n\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="erase.screen.above",
        payload=b"AAA\r\nBBB\r\nCCC\x1b[3;2H\x1b[1J",
        expected_cursor=(1, 2),
        expected_capture="\n\n  C\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="erase.screen.all",
        payload=b"AAA\r\nBBB\r\nCCC\x1b[2J",
        expected_cursor=(3, 2),
        expected_capture="AAA\nBBB\nCCC\n\n\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="erase.character",
        payload=b"ABCDE\x1b[1G\x1b[3X",
        expected_cursor=(0, 0),
        expected_capture="   DE\n\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="editing.insert-chars",
        payload=b"ABCDE\x1b[1G\x1b[2@",
        expected_cursor=(0, 0),
        expected_capture="  ABCDE\n\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="editing.delete-chars",
        payload=b"ABCDE\x1b[1G\x1b[2P",
        expected_cursor=(0, 0),
        expected_capture="CDE\n\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="editing.insert-lines",
        payload=b"LINE1\r\nLINE2\r\nLINE3\x1b[2;1H\x1b[1L",
        expected_cursor=(0, 1),
        expected_capture="LINE1\n\nLINE2\nLINE3\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="editing.delete-lines",
        payload=b"LINE1\r\nLINE2\r\nLINE3\x1b[2;1H\x1b[1M",
        expected_cursor=(0, 1),
        expected_capture="LINE1\nLINE3\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    Probe(
        name="editing.repeat-char",
        payload=b"X\x1b[4b",
        expected_cursor=(5, 0),
        expected_capture="XXXXX\n\n\n\n\n\n",
        rows=6,
        cols=20,
    ),
    sgr_probe("sgr.bold", b"\x1b[1mX\x1b[0m", "\x1b[1mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.faint", b"\x1b[2mX\x1b[0m", "\x1b[2mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.italic", b"\x1b[3mX\x1b[0m", "\x1b[3mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.underline.single", b"\x1b[4mX\x1b[0m", "\x1b[4mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.blink", b"\x1b[5mX\x1b[0m", "\x1b[5mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.inverse", b"\x1b[7mX\x1b[0m", "\x1b[7mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.hidden", b"\x1b[8mX\x1b[0m", "\x1b[8mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.strikethrough", b"\x1b[9mX\x1b[0m", "\x1b[9mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.fg.standard", b"\x1b[31mX\x1b[0m", "\x1b[31mX\x1b[39m\n\n\n"),
    sgr_probe("sgr.bg.standard", b"\x1b[42mX\x1b[0m", "\x1b[42mX\x1b[49m\n\n\n"),
    sgr_probe("sgr.fg.bright", b"\x1b[91mX\x1b[0m", "\x1b[91mX\x1b[39m\n\n\n"),
    sgr_probe("sgr.bg.bright", b"\x1b[102mX\x1b[0m", "\x1b[102mX\x1b[49m\n\n\n"),
    sgr_probe("sgr.fg.256", b"\x1b[38;5;196mX\x1b[0m", "\x1b[38;5;196mX\x1b[39m\n\n\n"),
    sgr_probe("sgr.bg.256", b"\x1b[48;5;22mX\x1b[0m", "\x1b[48;5;22mX\x1b[49m\n\n\n"),
    sgr_probe("sgr.fg.truecolor", b"\x1b[38;2;255;128;0mX\x1b[0m", "\x1b[38;2;255;128;0mX\x1b[39m\n\n\n"),
    sgr_probe("sgr.bg.truecolor", b"\x1b[48;2;10;20;30mX\x1b[0m", "\x1b[48;2;10;20;30mX\x1b[49m\n\n\n"),
    sgr_probe("sgr.underline.double", b"\x1b[21mX\x1b[0m", "\x1b[4:2mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.underline.curly", b"\x1b[4:3mX\x1b[0m", "\x1b[4:3mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.underline.dotted", b"\x1b[4:4mX\x1b[0m", "\x1b[4:4mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.underline.dashed", b"\x1b[4:5mX\x1b[0m", "\x1b[4:5mX\x1b[0m\n\n\n"),
    sgr_probe("sgr.overline", b"\x1b[53mX\x1b[0m", "\x1b[5:3mX\x1b[0m\n\n\n"),
    sgr_probe(
        "sgr.underline.color",
        b"\x1b[4m\x1b[58;2;255;0;128mX\x1b[0m",
        "\x1b[4m\x1b[58;2;255;0;128mX\x1b[0m\n\n\n",
    ),
    sgr_probe(
        "sgr.underline-color-indexed",
        b"\x1b[4m\x1b[58;5;5mX\x1b[0m",
        "\x1b[4m\x1b[58;5;5mX\x1b[0m\n\n\n",
    ),
    sgr_probe(
        "sgr.underline-color-rgb",
        b"\x1b[4m\x1b[58;2;255;0;128mX\x1b[0m",
        "\x1b[4m\x1b[58;2;255;0;128mX\x1b[0m\n\n\n",
    ),
    sgr_probe(
        "sgr.underline-color-reset",
        b"\x1b[4m\x1b[58;2;255;0;128m\x1b[59mX\x1b[0m",
        "\x1b[4mX\x1b[0m\n\n\n",
    ),
    sgr_probe_xy("sgr.fg.default", b"\x1b[31mX\x1b[39mY\x1b[0m", "\x1b[31mX\x1b[39mY\n\n\n"),
    sgr_probe_xy("sgr.bg.default", b"\x1b[42mX\x1b[49mY\x1b[0m", "\x1b[42mX\x1b[49mY\n\n\n"),
    sgr_probe_xy("sgr.selective-reset.bold", b"\x1b[1mX\x1b[22mY\x1b[0m", "\x1b[1mX\x1b[0mY\n\n\n"),
    sgr_probe_xy("sgr.selective-reset.underline", b"\x1b[4mX\x1b[24mY\x1b[0m", "\x1b[4mX\x1b[0mY\n\n\n"),
    sgr_probe_xy("sgr.selective-reset.italic", b"\x1b[3mX\x1b[23mY\x1b[0m", "\x1b[3mX\x1b[0mY\n\n\n"),
    sgr_probe_xy("sgr.selective-reset.inverse", b"\x1b[7mX\x1b[27mY\x1b[0m", "\x1b[7mX\x1b[0mY\n\n\n"),
    sgr_probe_xy("sgr.reset", b"\x1b[1;3;4mX\x1b[0mY", "\x1b[1;3;4mX\x1b[0mY\n\n\n"),
    Probe(
        name="text.tab",
        payload=b"\tX",
        expected_cursor=(9, 0),
        expected_capture="        X\n\n\n\n\n\n\n\n",
        # tmux 3.6 can preserve literal tabs in capture-pane output; older tmux expands them.
        normalize_capture_tabs=True,
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.overwrite",
        payload=b"AB\x1b[1GC",
        expected_cursor=(1, 0),
        expected_capture="CB\n\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.index",
        payload=b"A\x1bD",
        expected_cursor=(1, 1),
        expected_capture="A\n\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.next-line",
        payload=b"ABC\x1bE",
        expected_cursor=(0, 1),
        expected_capture="ABC\n\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.reverse-index-scroll",
        payload=b"\x1b[1;5r\x1b[HMARKER\x1b[H\x1bM",
        expected_cursor=(0, 0),
        expected_capture="\nMARKER\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.combining",
        payload=text_payload("e\u0301X"),
        expected_cursor=(2, 0),
        expected_capture="e\u0301X\n\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.hts",
        payload=b"\x1b[3g\x1b[6G\x1bH\x1b[1G\t",
        expected_cursor=(5, 0),
        expected_capture="\n\n\n\n\n\n\n\n",
        normalize_capture_tabs=True,
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.wide.emoji",
        payload=text_payload("\U0001f389X"),
        expected_cursor=(3, 0),
        expected_capture="\U0001f389X\n\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.wide.cjk",
        payload=text_payload("\u4e2dX"),
        expected_cursor=(3, 0),
        expected_capture="\u4e2dX\n\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.wide.emoji-flags",
        payload=text_payload("\U0001f1fa\U0001f1f8X"),
        expected_cursor=(3, 0),
        expected_capture="\U0001f1fa\U0001f1f8X\n\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.wide.emoji-vs16",
        payload=text_payload("\u2764\ufe0fX"),
        expected_cursor=(3, 0),
        expected_capture="\u2764\ufe0fX\n\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
    Probe(
        name="text.wide.emoji-zwj",
        payload=text_payload("\U0001f469\u200d\U0001f4bbX"),
        expected_cursor=(3, 0),
        expected_capture="\U0001f469\u200d\U0001f4bbX\n\n\n\n\n\n\n\n",
        rows=8,
        cols=30,
    ),
)


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


class TmuxServer:
    def __init__(self, socket_path, config_path):
        self.socket_path = socket_path
        self.config_path = config_path

    def run(self, *args, check=True):
        result = subprocess.run(
            [TMUX, "-S", str(self.socket_path), "-f", str(self.config_path), *args],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if check and result.returncode != 0:
            rendered = " ".join(shlex.quote(str(part)) for part in result.args)
            raise AssertionError(
                f"tmux command failed: {rendered}\n"
                f"exit={result.returncode}\n"
                f"stdout:\n{result.stdout}\n"
                f"stderr:\n{result.stderr}"
            )
        return result

    def start(self):
        self.config_path.write_text(
            "set-option -g status off\n"
            "set-option -gw allow-set-title on\n"
            "set-option -gw automatic-rename off\n"
        )

    def kill(self):
        self.run("kill-server", check=False)

    def new_session(self, session, rows, cols, command):
        self.run(
            "new-session",
            "-d",
            "-s",
            session,
            "-x",
            str(cols),
            "-y",
            str(rows),
            command,
        )

    def kill_session(self, session):
        self.run("kill-session", "-t", session, check=False)

    def capture(self, session):
        return self.run("capture-pane", "-p", "-S", "-", "-t", session).stdout

    def styled_capture(self, session):
        return self.run("capture-pane", "-p", "-e", "-S", "-", "-t", session).stdout

    def cursor(self, session):
        output = self.run("display-message", "-p", "-t", session, "#{cursor_x} #{cursor_y}").stdout.strip()
        x, y = output.split()
        return int(x), int(y)

    def title(self, session):
        return self.run("display-message", "-p", "-t", session, "#{pane_title}").stdout.strip()

    def wait_title(self, session, expected, timeout=10.0):
        end = time.monotonic() + timeout
        last = ""
        while time.monotonic() < end:
            last = self.title(session)
            if last == expected:
                return
            time.sleep(0.05)
        raise AssertionError(f"timed out waiting for pane title {expected!r}; last title was {last!r}")

    def pane_state(self, session):
        return PaneState(
            cursor=self.cursor(session),
            capture=self.capture(session),
            styled_capture=self.styled_capture(session),
        )


def quoted_env_assignments(env):
    return [f"{key}={shlex.quote(env[key])}" for key in XDG_ENV_KEYS]


def sessh_args(*args):
    if BIN.name == "sesshmux-dev":
        return [str(BIN), ":internal-sessh:", *args]
    return [str(BIN), *args]


def sessh_command(env, shell):
    parts = [
        "env",
        *quoted_env_assignments(env),
        f"SHELL={shlex.quote(str(shell))}",
    ]
    parts.extend(shlex.quote(str(arg)) for arg in sessh_args("."))
    return " ".join(parts)


def write_emitter(path, payload, barrier_title):
    path.write_text(
        "#!/usr/bin/env python3\n"
        "import sys\n"
        "import time\n"
        f"payload = {payload!r}\n"
        f"barrier = {barrier_title!r}.encode('ascii')\n"
        "sys.stdout.buffer.write(payload)\n"
        "sys.stdout.buffer.write(b'\\x1b]2;' + barrier + b'\\x07')\n"
        "sys.stdout.flush()\n"
        "time.sleep(30)\n"
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def captures_match(probe, actual, expected):
    return normalize_capture(probe, actual) == normalize_capture(probe, expected)


def normalize_capture(probe, capture):
    if not probe.normalize_capture_tabs:
        return capture
    return "\n".join(line.expandtabs(8).rstrip(" ") for line in capture.split("\n"))


def assert_expected(probe, state, label):
    failures = []
    if probe.expected_cursor is not None and state.cursor != probe.expected_cursor:
        failures.append(f"cursor {state.cursor!r}, expected {probe.expected_cursor!r}")
    if probe.expected_capture is not None and not captures_match(probe, state.capture, probe.expected_capture):
        failures.append(
            "capture differed:\n"
            + "\n".join(
                difflib.unified_diff(
                    probe.expected_capture.splitlines(),
                    state.capture.splitlines(),
                    fromfile=f"{probe.name}.expected",
                    tofile=label,
                    lineterm="",
                )
            )
        )
    if probe.expected_styled_capture is not None and state.styled_capture != probe.expected_styled_capture:
        failures.append(
            "styled capture differed:\n"
            + "\n".join(
                difflib.unified_diff(
                    probe.expected_styled_capture.splitlines(),
                    state.styled_capture.splitlines(),
                    fromfile=f"{probe.name}.expected",
                    tofile=label,
                    lineterm="",
                )
            )
        )
    if failures:
        raise AssertionError(f"{label} failed {probe.name}:\n" + "\n".join(failures))


def assert_matches_direct(probe, direct, through_sessh):
    failures = []
    if probe.expected_cursor is not None and through_sessh.cursor != direct.cursor:
        failures.append(f"cursor direct={direct.cursor!r} sessh={through_sessh.cursor!r}")
    if probe.expected_capture is not None and not captures_match(probe, through_sessh.capture, direct.capture):
        failures.append(
            "capture differed:\n"
            + "\n".join(
                difflib.unified_diff(
                    direct.capture.splitlines(),
                    through_sessh.capture.splitlines(),
                    fromfile="tmux-direct",
                    tofile="sessh",
                    lineterm="",
                )
            )
        )
    if probe.expected_styled_capture is not None and through_sessh.styled_capture != direct.styled_capture:
        failures.append(
            "styled capture differed:\n"
            + "\n".join(
                difflib.unified_diff(
                    direct.styled_capture.splitlines(),
                    through_sessh.styled_capture.splitlines(),
                    fromfile="tmux-direct",
                    tofile="sessh",
                    lineterm="",
                )
            )
        )
    if failures:
        raise AssertionError(f"sessh differed from direct tmux for {probe.name}:\n" + "\n".join(failures))


def run_direct_probe(tmux, probe, tmp_root):
    barrier = f"sessh-conformance:{os.getpid()}:{probe.name}:direct"
    script = tmp_root / f"{probe.name}.direct.py"
    write_emitter(script, probe.payload, barrier)

    session = f"sessh-conformance-direct-{os.getpid()}"
    tmux.new_session(session, probe.rows, probe.cols, shlex.quote(str(script)))
    try:
        tmux.wait_title(session, barrier)
        state = tmux.pane_state(session)
        assert_expected(probe, state, "tmux-direct")
        return state
    finally:
        tmux.kill_session(session)


def run_sessh_probe(tmux, probe, env, tmp_root):
    barrier = f"sessh-conformance:{os.getpid()}:{probe.name}:sessh"
    script = tmp_root / f"{probe.name}.sessh.py"
    write_emitter(script, probe.payload, barrier)

    session = f"sessh-conformance-sessh-{os.getpid()}"
    cleanup_runtime(env)
    tmux.new_session(session, probe.rows, probe.cols, sessh_command(env, script))
    try:
        tmux.wait_title(session, barrier)
        return tmux.pane_state(session)
    finally:
        tmux.kill_session(session)
        cleanup_runtime(env)


def run_probe(tmux, probe, env, tmp_root):
    direct = run_direct_probe(tmux, probe, tmp_root)
    through_sessh = run_sessh_probe(tmux, probe, env, tmp_root)
    assert_expected(probe, through_sessh, "sessh")
    assert_matches_direct(probe, direct, through_sessh)


def main():
    if TMUX is None:
        raise SystemExit("missing tmux")
    if not BIN.exists():
        raise SystemExit(f"missing binary: {BIN}")

    with tempfile.TemporaryDirectory(prefix="sessh-terminal-conformance-", dir="/tmp") as tmp:
        tmp_root = Path(tmp)
        tmux = TmuxServer(tmp_root / "tmux.sock", tmp_root / "tmux.conf")
        tmux.start()
        try:
            tmp_root = Path(tmp)
            env = isolated_env(tmp_root / "env")
            for probe in PROBES:
                run_probe(tmux, probe, env, tmp_root)
                print(f"ok {probe.name}")
        finally:
            tmux.kill()


if __name__ == "__main__":
    main()
