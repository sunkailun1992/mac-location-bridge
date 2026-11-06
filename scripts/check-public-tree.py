#!/usr/bin/env python3
"""Scan Git's tracked and nonignored untracked files without printing their contents.

Optional --private-terms FILE loads literal UTF-8 terms from outside the repository.
Terms and matched content are never included in diagnostics. This guard supplements
human review; it cannot identify every encoded secret or personal fact.
"""
from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest


@dataclass(frozen=True)
class Violation:
    path: str
    line: int
    rule: str


MAX_FILE_BYTES = 8 * 1024 * 1024
BLOCKED_SUFFIXES = {".pem", ".cer", ".crt", ".der", ".p12", ".pfx", ".key", ".p7b", ".p7c", ".jks", ".keystore", ".mobileprovision"}
PATTERNS = (
    ("private-key-pem", re.compile(rb"-{5}BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-{5}")),
    # A parser's header string is not a certificate. Require subsequent Base64
    # body material; recognize both PEM whitespace and JSON-escaped newlines.
    ("certificate-pem", re.compile(rb"-{5}BEGIN CERTIFICATE-{5}(?:[ \t\r\n]|\\[nr])+[A-Za-z0-9+/]{32,}={0,2}")),
    ("credential-token", re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{50,}|sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{35}|xox[baprs]-[A-Za-z0-9-]{20,})\b")),
    ("credential-token", re.compile(rb"\bBearer[ \t]+[A-Za-z0-9_./+=-]{24,}", re.I)),
    ("machine-specific-path", re.compile(rb"/" + rb"(?:Users|home|Volumes)/[^/\s\"'<>`]+/")),
    ("machine-specific-path", re.compile(rb"/(?:private/)?var/" + rb"folders/[^\s\"'<>`]+")),
    ("machine-specific-path", re.compile(rb"[A-Za-z]:\\" + rb"Users\\[^\\\s\"'<>`]+\\")),
    ("wifi-identifier", re.compile(rb"(?<![A-Za-z0-9])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![A-Za-z0-9])", re.I)),
    ("wifi-identifier", re.compile(rb"\bbssid\b[^\r\n]{0,32}?[\"'][0-9a-f]{12}[\"']", re.I)),
)


def load_private_terms(path: Path | None, root: Path) -> tuple[bytes, ...]:
    if path is None:
        return ()
    resolved = path.resolve(strict=True)
    if resolved.is_relative_to(root.resolve()):
        raise ValueError("private terms must stay outside the repository")
    if not resolved.is_file() or resolved.stat().st_size > 1024 * 1024:
        raise ValueError("private terms must be a regular file no larger than 1 MiB")
    lines = resolved.read_text(encoding="utf-8").splitlines()
    return tuple(dict.fromkeys(line.strip().encode("utf-8") for line in lines if line.strip() and not line.lstrip().startswith("#")))


def safe_path(path: str, private_terms: tuple[bytes, ...]) -> str:
    value = os.fsencode(path)
    for _, pattern in PATTERNS:
        value = pattern.sub(b"[REDACTED]", value)
    for term in private_terms:
        value = re.sub(re.escape(term), b"[REDACTED]", value, flags=re.I)
    return os.fsdecode(value)


def scan(root: Path, private_terms: tuple[bytes, ...] = ()) -> tuple[int, list[Violation]]:
    root = root.resolve(strict=True)
    top = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], check=True, capture_output=True).stdout.strip()
    if Path(os.fsdecode(top)).resolve() != root:
        raise ValueError("scan root must be a Git worktree root")
    listing = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"], check=True, capture_output=True).stdout
    names = sorted(set(os.fsdecode(name) for name in listing.split(b"\0") if name))
    found: list[Violation] = []
    for name in names:
        display = safe_path(name, private_terms)
        path = root / name
        def add(rule: str, line: int = 0) -> None:
            found.append(Violation(display, line, rule))
        if path.is_symlink():
            add("symlink")
            continue
        if not path.resolve().is_relative_to(root):
            add("path-outside-repository")
            continue
        # Refuse symlink parents too, even if they point back into this checkout.
        if any(parent.is_symlink() for parent in path.parents if parent != root and parent.is_relative_to(root)):
            add("symlink")
            continue
        try:
            metadata = path.stat()
            if not stat.S_ISREG(metadata.st_mode):
                add("nonregular-file")
                continue
            if path.suffix.lower() in BLOCKED_SUFFIXES:
                add("certificate-or-key-file")
                continue
            if metadata.st_size > MAX_FILE_BYTES:
                add("file-too-large-to-inspect")
                continue
            data = path.read_bytes()
        except OSError:
            add("file-unreadable")
            continue
        # Check relative filenames as well; never echo a matched value in output.
        for rule, pattern in PATTERNS:
            if pattern.search(os.fsencode(name)):
                add(rule)
            for match in pattern.finditer(data):
                add(rule, data.count(b"\n", 0, match.start()) + 1)
        for term in private_terms:
            if re.search(re.escape(term), os.fsencode(name), re.I):
                add("private-term")
            for match in re.finditer(re.escape(term), data, re.I):
                add("private-term", data.count(b"\n", 0, match.start()) + 1)
    return len(names), sorted(set(found), key=lambda v: (v.path, v.line, v.rule))


class ScannerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.root = self.parent / "repo"
        self.root.mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, capture_output=True)

    def put(self, name: str, data: bytes = b"safe documentation\n") -> Path:
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        return p

    def rules(self, terms: tuple[bytes, ...] = ()) -> set[str]:
        return {item.rule for item in scan(self.root, terms)[1]}

    def test_tracked_ignored_files_are_checked_and_untracked_ignored_files_are_excluded(self):
        self.put(".gitignore", b"ignored*\n")
        self.put("ignored.pem")
        self.assertEqual(self.rules(), set())
        subprocess.run(["git", "-C", str(self.root), "add", "-f", "ignored.pem"], check=True)
        self.assertIn("certificate-or-key-file", self.rules())

    def test_untracked_certificate_and_private_key_header_are_blocked(self):
        self.put("unexpected.P12", b"synthetic binary fixture")
        header = b"-" * 5 + b"BEGIN RSA " + b"PRIVATE KEY" + b"-" * 5
        self.put("payload.txt", header + b"\nnot-a-real-key\n")
        self.assertIn("certificate-or-key-file", self.rules())
        self.assertIn("private-key-pem", self.rules())

    def test_words_and_runtime_identity_filenames_are_not_secret_material(self):
        self.put("guide.md", b"Generate a private key outside Git; identity.p12 and leaf.pem are runtime files.\n")
        self.assertEqual(self.rules(), set())

    def test_parser_header_constant_without_certificate_body_is_safe(self):
        header = b"-" * 5 + b"BEGIN CERTIFICATE" + b"-" * 5
        self.put("parser.m", b'if ([input containsString:@"' + header + b'"]) { parse(input); }\n')
        self.assertEqual(self.rules(), set())

    def test_certificate_body_is_blocked_in_plain_pem_and_escaped_json(self):
        header = b"-" * 5 + b"BEGIN CERTIFICATE" + b"-" * 5
        footer = b"-" * 5 + b"END CERTIFICATE" + b"-" * 5
        body = base64.b64encode(b"synthetic-certificate-fixture" * 8)
        pem = b"\n".join((header, body[:64], body[64:], footer))
        for payload in (pem, pem.replace(b"\n", b"\r\n"), json.dumps({"certificate": pem.decode()}).encode()):
            with self.subTest(escaped=payload.startswith(b"{")):
                self.put("fixture.txt", payload)
                self.assertIn("certificate-pem", self.rules())

    def test_tokens_machine_paths_and_radio_identifiers_are_detected(self):
        token = b"ghp_" + b"A" * 36
        machine_path = b"/" + b"Users" + b"/fixture-user/file.txt"
        radio = b":".join(bytes(f"{n:02x}", "ascii") for n in (16, 32, 48, 64, 80, 96))
        self.put("fixture.txt", b"\n".join((token, machine_path, radio)))
        self.assertTrue({"credential-token", "machine-specific-path", "wifi-identifier"} <= self.rules())

    def test_mac_shaped_fixtures_are_blocked_in_tests_and_sources(self):
        sentinel = b":".join(bytes(f"{n:02x}", "ascii") for n in (2, 0, 0, 0, 0, 1))
        self.put("Tests/Fixture.swift", sentinel)
        self.assertIn("wifi-identifier", self.rules())
        self.put("Sources/Fixture.swift", sentinel)
        self.assertIn("wifi-identifier", self.rules())

    def test_symlink_outside_repository_is_not_followed(self):
        target = self.parent / "outside.txt"
        target.write_bytes(b"ghp_" + b"B" * 36)
        (self.root / "link.txt").symlink_to(target)
        found = self.rules()
        self.assertIn("symlink", found)
        self.assertNotIn("credential-token", found)

    def test_private_terms_are_literal_and_diagnostics_never_echo_values(self):
        term = b"synthetic-sensitive-value[1]"
        self.put("fixture.txt", term)
        violations = scan(self.root, (term,))[1]
        self.assertIn("private-term", {v.rule for v in violations})
        self.assertNotIn(term.decode(), repr(violations))

    def test_external_terms_file_is_deduplicated_and_cannot_live_inside_git_tree(self):
        outside = self.parent / "terms.txt"
        outside.write_text("# only synthetic test data\nexample[1]\nexample[1]\n", encoding="utf-8")
        self.assertEqual(load_private_terms(outside, self.root), (b"example[1]",))
        inside = self.put("terms.txt", b"example[1]")
        with self.assertRaises(ValueError):
            load_private_terms(inside, self.root)

    def test_secret_values_in_filenames_are_redacted(self):
        token = "ghp_" + "C" * 36
        self.put(token + ".txt")
        findings = scan(self.root)[1]
        self.assertIn("credential-token", {v.rule for v in findings})
        self.assertNotIn(token, repr(findings))
        self.assertIn("[REDACTED]", repr(findings))

    def test_tracked_parent_replaced_with_symlink_never_reads_external_fixture(self):
        self.put("directory/note.txt")
        subprocess.run(["git", "-C", str(self.root), "add", "directory/note.txt"], check=True)
        (self.root / "directory").rename(self.parent / "moved")
        (self.parent / "moved/note.txt").write_bytes(b"ghp_" + b"D" * 36)
        (self.root / "directory").symlink_to(self.parent / "moved", target_is_directory=True)
        found = self.rules()
        self.assertIn("path-outside-repository", found)
        self.assertNotIn("credential-token", found)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--private-terms", type=Path, help="literal term file outside this repository; values are never printed")
    args = parser.parse_args()
    if args.self_test:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ScannerTests)).wasSuccessful() else 1
    root = Path(__file__).resolve().parents[1]
    try:
        terms = load_private_terms(args.private_terms, root)
        count, found = scan(root, terms)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError):
        print("Public tree check could not complete; verify Git and the external term-file location.", file=sys.stderr)
        return 2
    for item in found:
        print(f"{json.dumps(item.path)}:{item.line}: {item.rule}")
    print(f"Public tree: {count} files, {len(found)} violations")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
