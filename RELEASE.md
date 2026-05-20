# Releasing sessh

Release packaging is described in [Packaging](docs/PACKAGING.md). A release must
include the `bin/sessh` wrapper and platform binaries for every supported
remote target under `libexec/sessh`.

Before tagging, ensure the version is consistent across the binary,
artifact-set id, and any package-manager metadata.

Release archives are built from version tags:

```sh
scripts/check
scripts/build --version X.Y.Z
git tag vX.Y.Z
git push origin vX.Y.Z
```

The release workflow should publish:

- an installable release archive containing `bin/sessh`;
- remote bootstrap artifacts for every supported target under `libexec/sessh`;
- SHA-256 checksums for published archives;
- `homebrew-bump.txt`

It does not update `block/homebrew-tap` directly. Use the generated
`homebrew-bump.txt` command when the tap is ready to be updated.
