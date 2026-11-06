#!/usr/bin/env python3
"""Exercise real identity generation and strict CLI validation with synthetic inputs."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("LOCATION_BRIDGE_CLI", ROOT / ".build/debug/location-bridge"))

def run(*args):
    return subprocess.run([str(CLI), *map(str, args)], text=True, capture_output=True)

class CLITests(unittest.TestCase):
    def test_unknown_command_and_duplicated_option_fail(self):
        self.assertNotEqual(run("unknown").returncode, 0)
        self.assertNotEqual(run("serve", "--latitude", "0", "--latitude", "1").returncode, 0)

    def test_identity_is_private_unique_and_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "identity"
            result = run("init-identity", "--directory", path)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ["identity.p12", "password.txt", "leaf.pem", "root.pem"]:
                self.assertTrue((path / name).is_file(), name)
                self.assertEqual(stat.S_IMODE((path / name).stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
            old = (path / "identity.p12").read_bytes()
            self.assertNotEqual(run("init-identity", "--directory", path).returncode, 0)
            self.assertEqual((path / "identity.p12").read_bytes(), old)
            cert = subprocess.check_output(["/usr/bin/openssl", "x509", "-in", str(path / "leaf.pem"), "-noout", "-text"], text=True)
            self.assertIn("DNS:gs-loc.apple.com, DNS:gs-loc-cn.apple.com", cert)
            self.assertNotIn("DNS:*", cert)
            preflight = run("preflight", "--directory", path)
            self.assertIn(preflight.returncode, (0, 2), preflight.stderr)
            report = json.loads(preflight.stdout)
            self.assertFalse(report["systemLocationVerified"])
            self.assertEqual(len(report["pinningAssessmentWithExplicitAnchor"]), 2)

    def test_symlink_identity_destination_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "target"
            target.mkdir()
            link = Path(temp) / "link"
            link.symlink_to(target, target_is_directory=True)
            self.assertNotEqual(run("init-identity", "--directory", link).returncode, 0)
            self.assertEqual(list(target.iterdir()), [])

if __name__ == "__main__":
    unittest.main()
