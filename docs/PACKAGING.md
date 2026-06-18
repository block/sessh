# Packaging

Sessh bootstraps remote hosts whose OS/architecture differs from the local
client. Release archives include one binary per supported platform under:

```text
libexec/sessh/<os>-<arch>/sessh
```

Role-shaped executable names are runtime details, not packaged artifacts. When
`sessh` starts a daemon namespace it writes `sesshd`, `sessh-broker`,
`sessh-proxy`, `sessh-terminal-remote`, and `sessh-proxy-remote` symlinks beside
`sesshd.sock`, all pointing back to the active `sessh` binary. That keeps
packaged archives simple while still making `ps` output readable.

Release archives also include `libexec/sessh/artifacts.manifest`, which records
sha256 sums so the bootstrapper can identify and install the right binary
without recomputing every artifact hash.

Release builds use Zig's ReleaseSafe mode.
