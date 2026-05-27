sessh must bootstrap remote hosts whose OS/architecture differs from the local
client. For example, a macOS `aarch64` client may need to upload a Linux
`x86_64` binary.

Each release archive contains binaries for all of the OS/architectures that we
support, in `libexec/sessh/sessh-<os>-<arch>`.

In order to benefit from Zig's runtime safety checks, we ship ReleaseSafe binaries.

The release archive contains a manifest of the sha256sums of each of the
binaries - `libexec/sessh/artifacts.manifest` - so that the bootstrapping
process doesn't need to recompute them.
