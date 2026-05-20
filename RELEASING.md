# Releasing sessh

Release artifacts are built by `scripts/build`. The archive contains the
Homebrew-facing wrapper plus every platform binary needed for local execution
and remote bootstrap:

```text
sessh-X.Y.Z/
  bin/sessh
  libexec/sessh/sessh-macos-aarch64
  libexec/sessh/sessh-macos-x86_64
  libexec/sessh/sessh-linux-aarch64
  libexec/sessh/sessh-linux-arm32
  libexec/sessh/sessh-linux-riscv64
  libexec/sessh/sessh-linux-x86
  libexec/sessh/sessh-linux-x86_64
```

## Before Tagging

1. Update the release version in `src/config.zig`.
2. Update the package version in `build.zig.zon`.
3. Run `scripts/check`.
4. Run `scripts/build --version X.Y.Z` and inspect `dist/sessh-X.Y.Z.tar.gz`.
5. Commit the version changes.

The release workflow checks that the tag version matches both version fields.
A tag `vX.Y.Z` should produce a binary whose `sessh --version` output is
`sessh X.Y.Z`.

## Cutting A Release

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

The GitHub release workflow:

1. installs Zig 0.15.2 and protobuf;
2. runs `scripts/check --fast`;
3. builds `dist/sessh-X.Y.Z.tar.gz`;
4. publishes the archive and `.sha256` file to the GitHub release;
5. triggers `block/homebrew-tap`'s `bump-formula.yaml` workflow for `sessh`.

The tap workflow opens or updates a PR in `block/homebrew-tap`. Review and merge
that PR to publish the new Homebrew formula version.

The sessh repository must have access to these GitHub secrets:

- `BLOCK_HOMEBREW_TAP_APP_ID`
- `BLOCK_HOMEBREW_TAP_PRIVATE_KEY`

Those secrets let the release workflow mint a token that can trigger workflows
in `block/homebrew-tap`.

## Homebrew Formula

`block/homebrew-tap` already owns `Formula/sessh.rb`. The shared tap bump
workflow rewrites only release metadata: `url`, `sha256`, and `version`.
The formula body must already match the native archive layout before the first
Zig release is tagged.

The formula should not depend on Python. Its install block should install the
wrapper and `libexec` artifacts directly:

```ruby
class Sessh < Formula
  desc "SSH with seamless connection recovery"
  homepage "https://github.com/block/sessh"
  url "https://github.com/block/sessh/releases/download/vX.Y.Z/sessh-X.Y.Z.tar.gz"
  sha256 "<sha256>"
  license "Apache-2.0"
  version "X.Y.Z"

  def install
    bin.install "bin/sessh"
    libexec.install "libexec/sessh"
  end

  test do
    assert_match "sessh #{version}", shell_output("#{bin}/sessh --version")
  end
end
```

After that one-time formula update lands, future releases should only need the
automatic bump PR.
