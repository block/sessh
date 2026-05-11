import io
import os
import unittest
from contextlib import redirect_stdout
from pathlib import Path
import subprocess
import tomllib

import sessh
from sessh.cli import parse_args


ROOT = Path(__file__).resolve().parents[1]


class ReleasePackagingTests(unittest.TestCase):
    def test_project_version_matches_package_version(self):
        pyproject = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))

        self.assertEqual(pyproject["project"]["version"], sessh.__version__)

    def test_package_release_check_validates_metadata(self):
        result = subprocess.run(
            [str(ROOT / "scripts" / "package-release"), "--check"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

        self.assertEqual(result.stdout, f"release metadata OK for v{sessh.__version__}\n")
        self.assertEqual(result.stderr, "")

    def test_package_release_rejects_tag_that_does_not_match_version(self):
        result = subprocess.run(
            [str(ROOT / "scripts" / "package-release"), "--repo", "block/sessh"],
            cwd=ROOT,
            env={**os.environ, "GITHUB_REF_NAME": "v999.999.999"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr,
            f"scripts/package-release: tag v999.999.999 does not match project version {sessh.__version__}; expected v{sessh.__version__}\n",
        )

    def test_cli_version_reports_package_version(self):
        stdout = io.StringIO()

        with redirect_stdout(stdout):
            with self.assertRaises(SystemExit) as raised:
                parse_args(["--version"])

        self.assertEqual(raised.exception.code, 0)
        self.assertEqual(stdout.getvalue(), f"sessh {sessh.__version__}\n")


if __name__ == "__main__":
    unittest.main()
