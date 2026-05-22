#!/bin/sh

set -u
exec 3>&1

err() {
  code=$1
  shift
  printf 'ERR %s %s\n' "$code" "$*" >&3
  exit 1
}

is_safe_relpath() {
  value=$1
  case "$value" in
    ""|/*|*//*|.|..|./*|*/.|*/..|../*|*/../*|*"/./"*|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-]*)
      return 1
      ;;
  esac
  return 0
}

is_safe_artifact_id() {
  value=$1
  case "$value" in
    ""|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*)
      return 1
      ;;
  esac
  return 0
}

is_sha256() {
  value=$1
  case "$value" in
    *[!0123456789abcdefABCDEF]*)
      return 1
      ;;
  esac
  [ ${#value} -eq 64 ]
}

probe_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    SHA256_TOOL=sha256sum
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    SHA256_TOOL=shasum
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    SHA256_TOOL=openssl
    return 0
  fi
  if command -v sha256 >/dev/null 2>&1; then
    SHA256_TOOL=sha256
    return 0
  fi
  return 1
}

sha256_file() {
  file=$1
  case "$SHA256_TOOL" in
    sha256sum)
      set -- $(sha256sum "$file" 2>/dev/null) || return 1
      printf '%s\n' "$1"
      ;;
    shasum)
      set -- $(shasum -a 256 "$file" 2>/dev/null) || return 1
      printf '%s\n' "$1"
      ;;
    openssl)
      set -- $(openssl dgst -sha256 "$file" 2>/dev/null) || return 1
      last=
      for field in "$@"; do
        last=$field
      done
      printf '%s\n' "$last"
      ;;
    sha256)
      sha256 -q "$file" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

probe_base64() {
  if command -v base64 >/dev/null 2>&1 && printf '' | base64 -d >/dev/null 2>&1; then
    BASE64_TOOL=base64_d
    return 0
  fi
  if command -v base64 >/dev/null 2>&1 && printf '' | base64 -D >/dev/null 2>&1; then
    BASE64_TOOL=base64_D
    return 0
  fi
  if command -v openssl >/dev/null 2>&1 && printf '' | openssl base64 -d >/dev/null 2>&1; then
    BASE64_TOOL=openssl
    return 0
  fi
  return 1
}

decode_base64_to_file() {
  payload=$1
  output=$2
  case "$BASE64_TOOL" in
    base64_d)
      printf '%s\n' "$payload" | base64 -d >"$output"
      ;;
    base64_D)
      printf '%s\n' "$payload" | base64 -D >"$output"
      ;;
    openssl)
      printf '%s\n' "$payload" | openssl base64 -d >"$output"
      ;;
    *)
      return 1
      ;;
  esac
}

canonical_platform() {
  os_raw=$(uname -s 2>/dev/null) || err UNSUPPORTED_PLATFORM uname_failed
  arch_raw=$(uname -m 2>/dev/null) || err UNSUPPORTED_PLATFORM uname_failed

  case "$os_raw" in
    Linux) os=linux ;;
    Darwin) os=macos ;;
    *) err UNSUPPORTED_PLATFORM "unsupported_os_$os_raw" ;;
  esac

  case "$arch_raw" in
    i386|i486|i586|i686) arch=x86 ;;
    x86_64|amd64) arch=x86_64 ;;
    arm|armv6l|armv7l|armv8l) arch=arm32 ;;
    aarch64|arm64) arch=aarch64 ;;
    riscv64) arch=riscv64 ;;
    *) err UNSUPPORTED_PLATFORM "unsupported_arch_$arch_raw" ;;
  esac

  printf '%s %s\n' "$os" "$arch"
}

IFS= read -r exec_line || err INVALID_EXEC missing_exec
set -- $exec_line
[ "$#" -ge 3 ] || err INVALID_EXEC expected_exec_set_and_hashes
[ "$1" = "EXEC" ] || err INVALID_EXEC expected_exec
artifact_set_id=$2
is_safe_relpath "$artifact_set_id" || err INVALID_EXEC invalid_artifact_set_id
shift 2

broker_args=
hashes=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--" ]; then
    shift
    broker_args="$*"
    break
  fi
  is_sha256 "$1" || err INVALID_EXEC invalid_sha256
  hashes="${hashes}${hashes:+ }$1"
  shift
done

cache_root=${XDG_CACHE_HOME:-${HOME:-}/.cache}/sessh/bin
[ "$cache_root" != "/.cache/sessh/bin" ] || err INVALID_ENV missing_cache_home
cache_dir=$cache_root/$artifact_set_id

for hash in $hashes; do
  candidate=$cache_dir/$hash
  if [ -f "$candidate" ] && [ -x "$candidate" ]; then
    printf 'OK\n'
    exec "$candidate" :internal-host-broker: $broker_args
  fi
done

platform=$(canonical_platform)
printf 'MISSING %s\n' "$platform"

IFS= read -r upload_line || err MISSING_UPLOAD expected_upload
set -- $upload_line
[ "$#" -eq 4 ] || err INVALID_UPLOAD expected_upload_artifact_hash_payload
[ "$1" = "UPLOAD" ] || err INVALID_UPLOAD expected_upload
artifact_id=$2
upload_hash=$3
payload=$4

is_safe_artifact_id "$artifact_id" || err INVALID_UPLOAD invalid_artifact_id
is_sha256 "$upload_hash" || err INVALID_UPLOAD invalid_sha256
probe_base64 || err MISSING_TOOL base64
mkdir -p "$cache_dir" || err INSTALL_FAILED mkdir

tmp=$cache_dir/.$upload_hash.tmp.$$
trap 'rm -f "$tmp"' EXIT HUP INT TERM
decode_base64_to_file "$payload" "$tmp" || err INVALID_UPLOAD base64_decode_failed
probe_sha256 || err MISSING_TOOL sha256
actual=$(sha256_file "$tmp") || err INSTALL_FAILED sha256_failed
[ "$actual" = "$upload_hash" ] || err CHECKSUM_MISMATCH expected_$upload_hash
chmod 700 "$tmp" || err INSTALL_FAILED chmod
mv "$tmp" "$cache_dir/$upload_hash" || err INSTALL_FAILED rename
trap - EXIT HUP INT TERM

printf 'OK\n'
exec "$cache_dir/$upload_hash" :internal-host-broker: $broker_args
