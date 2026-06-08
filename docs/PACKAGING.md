# Packaging

Sessh bootstraps remote hosts whose OS/architecture differs from the local
client. Release archives include one binary per supported platform under:

```text
libexec/sessh/<os>-<arch>/sessh
libexec/sessh/<os>-<arch>/sesshd
```

The `sesshd` path is a symlink to `sessh`, not a second binary copy. The
separate pathname exists so daemon processes have a daemon-shaped executable
name when the wrapper execs that path.

Release archives also include `libexec/sessh/artifacts.manifest`, which records
sha256 sums so the bootstrapper can identify and install the right binary
without recomputing every artifact hash.

Release builds use Zig's ReleaseSafe mode.
