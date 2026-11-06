#!/usr/bin/env python3
"""Read-only tests for the real bundled CLI and experimental trust helper.

Fresh identities and snapshots live in a temporary directory outside Git. This
script never supplies the mutation acknowledgement, never invokes CLI apply or
restore, and never changes OS trust. Security reads use the real macOS APIs.
Build dist/LocationBridge.app first; LOCATION_BRIDGE_CLI and
LOCATION_BRIDGE_TRUST_HELPER may select another built pair.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_BIN = ROOT / "dist/LocationBridge.app/Contents/MacOS"
CLI = Path(os.environ.get("LOCATION_BRIDGE_CLI", BUNDLE_BIN / "location-bridge"))
HELPER = Path(os.environ.get("LOCATION_BRIDGE_TRUST_HELPER", CLI.with_name("locationbridge-trust")))
HOSTS = ["gs-loc.apple.com", "gs-loc-cn.apple.com"]
ITEM_NOT_FOUND = -25300
MACOS = platform.mac_ver()[0]
SUPPORTED = bool(MACOS) and int(MACOS.split(".", 1)[0]) >= 15


def command(executable, *arguments):
    return subprocess.run([str(executable), *map(str, arguments)], capture_output=True, text=True, timeout=30)


def receipt(result):
    return json.loads(result.stdout)


@unittest.skipUnless(SUPPORTED, "Real Security helper regression requires macOS 15+")
class ReadOnlyTrustHelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CLI.is_file() or not HELPER.is_file():
            raise AssertionError("Build the app bundle or select an existing CLI/helper pair")
        cls.temporary = tempfile.TemporaryDirectory(prefix="locationbridge-trust-test-")
        cls.base = Path(cls.temporary.name).resolve()
        if cls.base.is_relative_to(ROOT):
            cls.temporary.cleanup()
            raise AssertionError("Private test data must remain outside the checkout")
        cls.identity = cls.base / "identity"
        generated = command(CLI, "init-identity", "--directory", cls.identity)
        if generated.returncode:
            cls.temporary.cleanup()
            raise AssertionError("Fresh identity generation failed: " + generated.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def prepare(self):
        state = self.base / self.id().rsplit(".", 1)[-1] / "nested-private-parent" / "session"
        result = command(CLI, "prepare-trust", "--directory", self.identity, "--state", state)
        self.assertEqual(result.returncode, 0, result.stderr)
        prepared = receipt(result)
        self.assertTrue(prepared["snapshotCreated"])
        self.assertFalse(prepared["systemTrustChanged"])
        self.assertFalse(prepared["realLocationVerified"])
        return state

    def assert_absent(self, state):
        checked = command(HELPER, "check", state)
        self.assertEqual(checked.returncode, 0, checked.stdout)
        status = receipt(checked)
        self.assertEqual(status["state"], "baseline_absent")
        self.assertFalse(status["systemTrustChanged"])
        self.assertFalse(status["realLocationVerified"])

    def edit_snapshot(self, state, edit):
        path = state / "baseline.plist"
        snapshot = plistlib.loads(path.read_bytes())
        edit(snapshot)
        path.write_bytes(plistlib.dumps(snapshot, fmt=plistlib.FMT_BINARY))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def assert_rejected_snapshot(self, state, error):
        result = command(HELPER, "check", state)
        self.assertNotEqual(result.returncode, 0)
        rejected = receipt(result)
        self.assertEqual(rejected["error"], error)
        self.assertFalse(rejected["realLocationVerified"])

    def test_prepare_creates_nested_private_snapshot_and_read_only_absence_receipt(self):
        state = self.prepare()
        for directory in [state, state.parent, state.parent.parent]:
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        path = state / "baseline.plist"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        snapshot = plistlib.loads(path.read_bytes())
        self.assertEqual(snapshot["schema"], 1)
        self.assertEqual(snapshot["leafUserStatus"], ITEM_NOT_FOUND)
        self.assertEqual(snapshot["leafAdminStatus"], ITEM_NOT_FOUND)
        self.assertEqual(snapshot["hosts"], HOSTS)
        self.assertEqual(snapshot["application"], "/usr/libexec/locationd")
        self.assertEqual(snapshot["constraintCount"], 2)
        self.assertEqual(snapshot["allowedError"], 0)
        self.assertEqual(snapshot["trustResult"], 2)
        self.assertTrue(snapshot["experimentalLeafAnchor"])
        self.assertTrue(snapshot["noBroadTrust"])
        self.assertFalse(snapshot["addsRootTrust"])
        for key in ["leaf", "root", "requirement"]:
            self.assertIsInstance(snapshot[key], bytes)
            self.assertTrue(snapshot[key])
        self.assertNotEqual(hashlib.sha256(snapshot["leaf"]).digest(), hashlib.sha256(snapshot["root"]).digest())
        self.assert_absent(state)
        cli_check = command(CLI, "trust-status", "--state", state)
        self.assertEqual(cli_check.returncode, 0, cli_check.stderr)
        self.assertEqual(receipt(cli_check)["state"], "baseline_absent")

    def test_inspect_fresh_identity_reports_no_scoped_trust(self):
        result = command(HELPER, "inspect", self.identity / "leaf.pem", self.identity / "root.pem")
        self.assertEqual(result.returncode, 0, result.stdout)
        inspected = receipt(result)
        self.assertFalse(inspected["locationdScopedTrustPresent"])
        self.assertFalse(inspected["systemTrustChanged"])
        self.assertFalse(inspected["realLocationVerified"])
        self.assertEqual(inspected["offlineCaller"], "this_helper_not_locationd")
        self.assertEqual(inspected["leafUserStatus"], ITEM_NOT_FOUND)
        self.assertEqual(inspected["leafAdminStatus"], ITEM_NOT_FOUND)
        self.assertEqual(set(inspected["offlineSSL"]), set(HOSTS))
        for assessment in inspected["offlineSSL"].values():
            self.assertIsInstance(assessment["valid"], bool)

    def test_existing_prepare_refuses_to_overwrite_snapshot(self):
        state = self.prepare()
        path = state / "baseline.plist"
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        repeated = command(CLI, "prepare-trust", "--directory", self.identity, "--state", state)
        self.assertNotEqual(repeated.returncode, 0)
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        self.assertEqual([file.name for file in state.iterdir()], ["baseline.plist"])
        self.assert_absent(state)

    def test_unknown_snapshot_variant_rejected(self):
        state = self.prepare()
        self.edit_snapshot(state, lambda snapshot: snapshot.update(variant="unsupported-synthetic-variant"))
        self.assert_rejected_snapshot(state, "snapshot_variant_mismatch")

    def test_changed_snapshot_host_rejected(self):
        state = self.prepare()
        self.edit_snapshot(state, lambda snapshot: snapshot.update(hosts=[HOSTS[0], "example.invalid"]))
        self.assert_rejected_snapshot(state, "snapshot_constraint_parameters_mismatch")

    def test_malformed_snapshot_rejected(self):
        state = self.prepare()
        (state / "baseline.plist").write_bytes(b"synthetic-invalid-property-list")
        self.assert_rejected_snapshot(state, "invalid_snapshot")

    def test_apply_without_confirmation_refused_before_snapshot_load_or_write(self):
        state = self.prepare()
        path = state / "baseline.plist"
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        # Call the raw helper only. CLI apply-trust supplies the acknowledgement
        # internally, so invoking that CLI command would be a real mutation.
        result = command(HELPER, "apply", state)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt(result)["error"], "explicit_mutation_confirmation_required")
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        self.assert_absent(state)
        missing = self.base / "never-created-snapshot"
        missing_result = command(HELPER, "apply", missing)
        self.assertNotEqual(missing_result.returncode, 0)
        self.assertEqual(receipt(missing_result)["error"], "explicit_mutation_confirmation_required")
        self.assertFalse(missing.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
