# Releasing sessh

Before tagging, update `pyproject.toml` and `src/sessh/__init__.py` to the same
version.

Release archives are built from version tags:

```sh
scripts/check
git tag vX.Y.Z
git push origin vX.Y.Z
```

The release workflow publishes:

- `sessh-release.tar.gz`
- `sessh-X.Y.Z.tar.gz`
- `sessh-X.Y.Z-py3-none-any.whl`
- `sessh-release.tar.gz.sha256`
- `homebrew-bump.txt`

It does not update `block/homebrew-tap` directly. Use the generated
`homebrew-bump.txt` command when the tap is ready to be updated.
