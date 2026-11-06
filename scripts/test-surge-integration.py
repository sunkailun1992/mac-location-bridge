#!/usr/bin/env python3
"""Regression tests for preserving unrelated profile edits during restoration."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("integration", Path(__file__).with_name("surge-integration.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class RestorationTests(unittest.TestCase):
    def test_restore_preserves_current_unrelated_entries_and_formatting(self):
        profile = "[Proxy]\n# User proxy comment\nCustom = direct\n# LocationBridge managed entry\nLocationBridge-Local = http, 127.0.0.1, 19443\n[Rule]\n# LocationBridge managed entry\nAND,((PROCESS-NAME,locationd),(DOMAIN,gs-loc.apple.com)),LocationBridge-Local\nAND,((PROCESS-NAME,locationd),(DOMAIN,gs-loc-cn.apple.com)),LocationBridge-Local\nDOMAIN,example.com,Custom\nFINAL,DIRECT\n"
        expected = "[Proxy]\n# User proxy comment\nCustom = direct\n[Rule]\nDOMAIN,example.com,Custom\nFINAL,DIRECT\n"
        self.assertEqual(module.strip_owned(profile, 19443), expected)

    def test_unknown_reference_and_changed_port_are_refused(self):
        for profile in ["[Rule]\nFINAL,LocationBridge-Local\n", "[Proxy]\nLocationBridge-Local=http,127.0.0.1,19444\n"]:
            with self.assertRaises(ValueError):
                module.strip_owned(profile, 19443)

    def test_duplicate_and_wrong_section_entries_are_refused(self):
        for profile in ["[Proxy]\nLocationBridge-Local=http,127.0.0.1,19443\nLocationBridge-Local=http,127.0.0.1,19443\n", "[Rule]\nLocationBridge-Local=http,127.0.0.1,19443\n"]:
            with self.assertRaises(ValueError):
                module.strip_owned(profile, 19443)

if __name__ == "__main__":
    unittest.main()
