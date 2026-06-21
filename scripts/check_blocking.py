#!/usr/bin/env python3
"""Reject accidental production blocking primitives.

The policy is intentionally simple:

* raw blocking syscalls live in src/core/blocking.zig;
* the process Dispatcher may call poll(2) because it is the event loop;
* a small set of existing boundary modules still expose foreground blocking
  behavior while they are migrated to Source/Sink/DispatchTask;
* tests may block freely;

That keeps new blocking work auditable while the codebase migrates toward the
Source/Sink/DispatchTask APIs described in docs/THREADING.md.
"""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"

FORBIDDEN = (
    ("posix.poll(", "raw poll(2)"),
    ("c.poll(", "raw poll(2)"),
    ("posix.nanosleep(", "raw sleep"),
    ("std.time.sleep(", "raw sleep"),
    ("c.nanosleep(", "raw sleep"),
    ("std.process.Child.run(", "blocking child run"),
)

WAITPID = (
    ("posix.waitpid(", "blocking waitpid"),
    ("c.waitpid(", "blocking waitpid"),
)

TOKEN_CREATION = (
    ("blocking.fromMain(", "Blocking token creation"),
    ("blocking.fromTest(", "Blocking test token creation"),
)


def strip_line_comment(line: str) -> str:
    # This checker is a policy guard, not a Zig parser. Removing plain line
    # comments avoids false positives from prose while keeping call-site
    # detection easy to review.
    return line.split("//", 1)[0]


def update_test_depth(line: str, in_test: bool, depth: int) -> tuple[bool, int]:
    stripped = line.strip()
    if not in_test and (stripped.startswith("test ") or stripped.startswith("test{")):
        in_test = True
        depth = 0
    if in_test:
        depth += line.count("{")
        depth -= line.count("}")
        if depth <= 0:
            return False, 0
    return in_test, depth


def allowed_file(path: Path) -> bool:
    rel = path.relative_to(ROOT).as_posix()
    if rel.endswith("test_helpers.zig"):
        return True
    return rel in {
        "src/core/blocking.zig",
        "src/core/dispatcher.zig",
        "src/core/io.zig",
        "src/daemon/identity.zig",
        "src/transport/bootstrap.zig",
        "src/transport/foreground_frame_io.zig",
        "src/transport/plain_ssh.zig",
        "src/transport/ssh_options.zig",
        "src/tty/pty_process.zig",
        "src/tty/terminal.zig",
    }


def waitpid_is_nonblocking(line: str) -> bool:
    return "nohang" in line or "WNOHANG" in line


def check_file(path: Path) -> list[str]:
    rel = path.relative_to(ROOT).as_posix()
    lines = path.read_text().splitlines()
    errors: list[str] = []
    in_test = False
    test_depth = 0

    for index, line in enumerate(lines):
        in_test, test_depth = update_test_depth(line, in_test, test_depth)
        code = strip_line_comment(line)
        if in_test or allowed_file(path):
            continue

        for needle, label in FORBIDDEN:
            if needle in code:
                errors.append(
                    f"{rel}:{index + 1}: {label} must go through core/blocking.zig "
                    "or the dispatcher Source/Sink APIs"
                )

        for needle, label in WAITPID:
            if needle in code and not waitpid_is_nonblocking(code):
                errors.append(
                    f"{rel}:{index + 1}: {label} must go through core/blocking.zig "
                    "or the dispatcher Source/Sink APIs"
                )

        for needle, label in TOKEN_CREATION:
            if needle not in code:
                continue
            if needle == "blocking.fromMain(" and rel != "src/main.zig":
                errors.append(f"{rel}:{index + 1}: {label} is only allowed in src/main.zig")
            if needle == "blocking.fromTest(":
                errors.append(f"{rel}:{index + 1}: {label} is only allowed inside Zig test blocks")

    return errors


def main() -> int:
    errors: list[str] = []
    for path in sorted(SRC.rglob("*.zig")):
        # Generated protobuf files are output from protoc and should not encode
        # project policy.
        if "/proto/sessh/" in path.as_posix():
            continue
        errors.extend(check_file(path))

    if errors:
        print("blocking API policy violations:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
