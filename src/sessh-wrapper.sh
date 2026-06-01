#!/bin/sh
set -eu

# Homebrew and other package managers may expose bin/sessh as a symlink. Resolve
# it with only POSIX sh plus readlink; macOS does not provide readlink -f.
case "$0" in
  */*) self=$0 ;;
  *)
    self=$(command -v "$0") || {
      printf 'sessh: could not resolve executable path\n' >&2
      exit 127
    }
    ;;
esac

while [ -L "$self" ]; do
  target=$(readlink "$self") || {
    printf 'sessh: could not read symlink: %s\n' "$self" >&2
    exit 127
  }
  case "$target" in
    /*) self=$target ;;
    *) self=$(dirname "$self")/$target ;;
  esac
done

bindir=$(CDPATH= cd -P "$(dirname "$self")" && pwd) || {
  printf 'sessh: could not resolve install directory\n' >&2
  exit 127
}

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *)
    printf 'sessh: unsupported local OS: %s\n' "$(uname -s)" >&2
    exit 127
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  i386|i486|i586|i686) arch=x86 ;;
  arm|armv6l|armv7l|armv8l) arch=arm32 ;;
  aarch64|arm64) arch=aarch64 ;;
  riscv64) arch=riscv64 ;;
  *)
    printf 'sessh: unsupported local architecture: %s\n' "$(uname -m)" >&2
    exit 127
    ;;
esac

name=$(basename "$self")
real="$bindir/../libexec/sessh/sesshmux-$os-$arch"
if [ ! -x "$real" ]; then
  printf 'sessh: missing platform binary: %s\n' "$real" >&2
  exit 127
fi

if [ "$name" = "sessh" ]; then
  if [ "${1:-}" = "." ]; then
    printf 'sessh: "." is not a valid ssh host\n' >&2
    exit 64
  fi
  exec "$real" :internal-sessh: "$@"
fi

exec "$real" "$@"
