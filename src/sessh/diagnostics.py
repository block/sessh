from __future__ import annotations

from dataclasses import dataclass, field
from typing import TextIO


@dataclass
class ProgressReporter:
    stream: TextIO
    verbose: bool = False
    quiet: bool = False
    _line_active: bool = field(default=False, init=False)

    def update(self, message: str) -> None:
        if self.quiet:
            return
        if self.verbose or not self._supports_dynamic_line():
            self.clear()
            self.stream.write(f"sessh: {message}\n")
            self.stream.flush()
            return

        self.stream.write(f"\r\033[Ksessh: {message}")
        self.stream.flush()
        self._line_active = True

    def clear(self) -> None:
        if self.quiet or not self._line_active:
            return
        self.stream.write("\r\033[K")
        self.stream.flush()
        self._line_active = False

    def _supports_dynamic_line(self) -> bool:
        try:
            return self.stream.isatty()
        except (AttributeError, OSError):
            return False
