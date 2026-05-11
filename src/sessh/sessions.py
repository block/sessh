from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class SessionInfo:
    resume_id: str
    attached_count: int
    created_at: int
    working_dir: str
    foreground_command: str
    window_title: str
