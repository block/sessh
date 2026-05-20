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

## Before Releasing

1. Make sure the current branch is `main`.
2. Make sure the working tree is clean.
3. Run `scripts/check`.

The release workflow checks that the tag version matches both version fields.
A tag `vX.Y.Z` should produce a binary whose `sessh --version` output is
`sessh X.Y.Z`.

## Cutting A Release

```sh
scripts/release
```

The release script:

1. creates or resets `release/vX.Y.Z` from the current `main`;
2. infers `X.Y.Z` from `src/config.zig` by stripping `-dev`;
3. updates `src/config.zig` and `build.zig.zon` for `X.Y.Z`;
4. commits `Release vX.Y.Z`;
5. tags that commit as `vX.Y.Z`;
6. pushes the release branch and tag to `origin`;
7. waits for the release workflow to succeed;
8. integrates the release version commit into `main`;
9. bumps `main` to the next development version and pushes it.

For example, if `src/config.zig` says `0.4.0-dev`, `scripts/release` releases
`0.4.0` and bumps `main` to `0.5.0-dev` after the release succeeds.

Before mutating git state, the script prints the inferred release plan and
requires typing `yes`.

Re-running the same release after CI failure is supported. Commit the fix to
`main`, then run `scripts/release` again. As long as `src/config.zig` still has
the same `X.Y.Z-dev` version, the script will reset the release branch from the
updated `main` and move the tag to the new release commit. It refuses to move
the tag once a GitHub Release already exists for that version.

If the release workflow fails after the GitHub Release has already been
published, the script still integrates the release commit into `main` and bumps
to the next development version. This lets a release complete even when a later
publishing side effect, such as the Homebrew tap bump, needs separate follow-up.

The GitHub release workflow triggered by the tag:

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
