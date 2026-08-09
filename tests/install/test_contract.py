from __future__ import annotations

import re
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "install.sh"
PROTOCOL = ROOT / "protocol" / "control-bootstrap-v3.md"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"


class PublicBootstrapContractTests(unittest.TestCase):
    def test_shell_syntax(self) -> None:
        shell = shutil.which("sh")
        if shell is None:
            self.skipTest("POSIX sh is unavailable on this development host")
        completed = subprocess.run(
            [shell, "-n", str(INSTALLER)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_public_repository_is_control_plane_only(self) -> None:
        combined = INSTALLER.read_text(encoding="utf-8") + PROTOCOL.read_text(
            encoding="utf-8"
        )
        self.assertIn("maitix-control-bootstrap-v3", combined)
        self.assertIn("Suysker/Ticket-bootstrap", combined)
        self.assertNotIn("/api/v1/nodes/join-codes", combined)
        self.assertNotIn("/bootstrap/windows.ps1", combined)
        self.assertNotIn("/bootstrap/linux.sh", combined)

    def test_enrollment_code_is_not_an_argument_or_url(self) -> None:
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn("/dev/tty", source)
        self.assertIn("--data-binary @-", source)
        self.assertNotRegex(source, re.compile(r"curl[^\n]*\\\$ENROLLMENT_CODE"))
        self.assertNotIn("--code", source)

    def test_cleanup_roots_are_allowlisted(self) -> None:
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn("/run/maitix-control-seed.*", source)
        self.assertIn("/var/tmp/maitix-control-install.*", source)
        self.assertNotIn("rm -rf /", source)

    def test_release_is_draft_until_trusted_promotion(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("control-bootstrap-v*", workflow)
        self.assertIn("dist/maitix-control-install.sh", workflow)
        self.assertIn("--draft", workflow)
        self.assertNotIn("gh release download latest", workflow.lower())
        self.assertNotIn("/releases/latest/", workflow.lower())

    def test_no_public_secret_or_private_core_fixture(self) -> None:
        forbidden_suffixes = {".age", ".key", ".pem", ".p12", ".pfx"}
        files = [
            path
            for path in ROOT.rglob("*")
            if path.is_file()
            and ".git" not in path.parts
            and "__pycache__" not in path.parts
        ]
        self.assertFalse(
            [path for path in files if path.suffix.lower() in forbidden_suffixes]
        )
        text = "\n".join(
            path.read_text(encoding="utf-8", errors="ignore") for path in files
        )
        self.assertNotRegex(text, re.compile(r"gh[opusr]_[A-Za-z0-9]{20,}"))
        self.assertNotIn("BEGIN " + "OPENSSH PRIVATE KEY", text)
        self.assertNotIn("AGE-" + "SECRET-KEY-", text)


if __name__ == "__main__":
    unittest.main()
