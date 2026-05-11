from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

import yaml

from sessh.remote_rc import default_remote_rc


VALID_SHELLS = {"bash", "zsh"}
DEFAULT_HISTORY_LIMIT = 10_000


@dataclass(frozen=True)
class Config:
    shell: str
    history_limit: int
    scrollback: int = 0
    auto_reattach: bool = False
    remote_init: str = ""
    remote_rc: str | None = None

    @classmethod
    def built_in(cls, current_shell: str | None = None) -> "Config":
        current_shell = (
            os.environ.get("SHELL", "") if current_shell is None else current_shell
        )
        shell_name = Path(current_shell).name
        shell = shell_name if shell_name in VALID_SHELLS else "bash"
        return cls(shell=shell, history_limit=DEFAULT_HISTORY_LIMIT)

    @staticmethod
    def default_path() -> Path:
        config_home = os.environ.get("XDG_CONFIG_HOME")
        if config_home:
            return Path(config_home) / "sessh" / "config.yaml"
        return Path.home() / ".config" / "sessh" / "config.yaml"


def load_config(
    path: Path | None = None,
    *,
    current_shell: str | None = None,
    shell: str | None = None,
    history_limit: int | None = None,
) -> Config:
    config = Config.built_in(current_shell=current_shell)
    config_path = path or Config.default_path()

    if config_path.exists():
        raw = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        if not isinstance(raw, dict):
            raise ValueError("config file must contain a YAML mapping")
        defaults = raw.get("defaults", {})
        if defaults is None:
            defaults = {}
        if not isinstance(defaults, dict):
            raise ValueError("defaults must be a YAML mapping")
        remote_init = raw.get("remote-init", config.remote_init)
        remote_rc = raw.get("remote-rc", config.remote_rc)
        config = Config(
            shell=defaults.get("shell", config.shell),
            history_limit=defaults.get("history-limit", config.history_limit),
            scrollback=defaults.get("scrollback", config.scrollback),
            auto_reattach=defaults.get("auto-reattach", config.auto_reattach),
            remote_init=remote_init,
            remote_rc=remote_rc,
        )

    if shell is not None:
        config = Config(
            shell=shell,
            history_limit=config.history_limit,
            scrollback=config.scrollback,
            auto_reattach=config.auto_reattach,
            remote_init=config.remote_init,
            remote_rc=config.remote_rc,
        )
    if history_limit is not None:
        config = Config(
            shell=config.shell,
            history_limit=history_limit,
            scrollback=config.scrollback,
            auto_reattach=config.auto_reattach,
            remote_init=config.remote_init,
            remote_rc=config.remote_rc,
        )

    _validate_config(config)
    if config.remote_rc is None:
        config = Config(
            shell=config.shell,
            history_limit=config.history_limit,
            scrollback=config.scrollback,
            auto_reattach=config.auto_reattach,
            remote_init=config.remote_init,
            remote_rc=default_remote_rc(config.shell),
        )
    return config


def _validate_config(config: Config) -> None:
    if config.shell not in VALID_SHELLS:
        raise ValueError(f"unsupported shell: {config.shell}")
    if type(config.history_limit) is not int or config.history_limit <= 0:
        raise ValueError("history-limit must be a positive integer")
    if type(config.scrollback) is not int or config.scrollback < 0:
        raise ValueError("scrollback must be a non-negative integer")
    if type(config.auto_reattach) is not bool:
        raise ValueError("auto-reattach must be a boolean")
    if not isinstance(config.remote_init, str):
        raise ValueError("remote-init must be a string")
    if config.remote_rc is not None and not isinstance(config.remote_rc, str):
        raise ValueError("remote-rc must be a string")
