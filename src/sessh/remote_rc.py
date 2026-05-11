from __future__ import annotations


def default_remote_rc(shell: str) -> str:
    if shell == "bash":
        return """case $- in
  *i*)
    if [ -r "$HOME/.bashrc" ]; then
      . "$HOME/.bashrc"
    fi
    ;;
esac
"""
    if shell == "zsh":
        return """case $- in
  *i*)
    if [ -r "$HOME/.zshrc" ]; then
      . "$HOME/.zshrc"
    fi
    ;;
esac
"""
    raise ValueError(f"unsupported shell: {shell}")
