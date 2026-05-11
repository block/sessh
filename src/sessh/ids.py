from __future__ import annotations

import re
import secrets
from collections.abc import Collection


ID_LENGTH = 6
ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"
ID_RE = re.compile(r"^[a-z0-9]{6}$")


def is_valid_resume_id(value: str) -> bool:
    return bool(ID_RE.fullmatch(value))


def generate_resume_id(existing: Collection[str]) -> str:
    existing_set = set(existing)
    while True:
        value = "".join(secrets.choice(ID_ALPHABET) for _ in range(ID_LENGTH))
        if value not in existing_set:
            return value

