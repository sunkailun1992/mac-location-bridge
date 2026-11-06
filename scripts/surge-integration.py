#!/usr/bin/env python3
"""Manage only LocationBridge's Surge entries; private before-state stays outside Git."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile

POLICY = "LocationBridge-Local"
COMMENT = "# LocationBridge managed entry"
CLI = "/Applications/Surge.app/Contents/Applications/surge-cli"

def entries(port):
    return {"[Proxy]": [f"{POLICY} = http, 127.0.0.1, {port}"], "[Rule]": [f"AND,((PROCESS-NAME,locationd),(DOMAIN,{host})),{POLICY}" for host in ("gs-loc.apple.com", "gs-loc-cn.apple.com")]}

def normalized(line):
    return re.sub(r"[ \t]*([,()=])[ \t]*", r"\1", line.strip())

def strip_owned(text, port):
    expected = {normalized(line): section for section, lines in entries(port).items() for line in lines}
    reference = re.compile(r"(?<![\w.-])" + re.escape(POLICY) + r"(?![\w.-])")
    section = None
    seen = set()
    result = []
    for line in text.splitlines(keepends=True):
        token = normalized(line)
        if re.fullmatch(r"\[[^\]]+\]", token):
            section = token
        if token in expected:
            if section != expected[token] or token in seen:
                raise ValueError("Owned entry duplicated or in an unexpected section")
            seen.add(token)
        elif token == COMMENT:
            key = (section, COMMENT)
            if section not in entries(port) or key in seen:
                raise ValueError("Owned comment duplicated or in an unexpected section")
            seen.add(key)
        elif reference.search(line):
            raise ValueError("Unknown reference to LocationBridge policy; refusing to overwrite external changes")
        else:
            result.append(line)
    return "".join(result)

def digest(data):
    return hashlib.sha256(data).hexdigest()

def private_write(path, data):
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())

def checked(args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise ValueError("Surge rejected the operation; private output was not printed")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "apply", "restore"])
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--port", type=int, default=19443)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        raise ValueError("Invalid local service port")
    profile = args.profile.expanduser().resolve()
    state = args.state.expanduser().resolve()
    repo = Path(__file__).resolve().parents[1]
    if state.is_relative_to(repo):
        raise ValueError("Private state must be outside the checkout; symlink destinations are refused")
    before = profile.read_bytes()
    candidate = strip_owned(before.decode("utf-8"), args.port)
    record = state / "state.json"
    if args.action in ("plan", "apply"):
        if candidate.encode() != before:
            raise ValueError("Existing managed entries found; restore the original session first")
        for section, lines in entries(args.port).items():
            if candidate.count(section + "\n") != 1:
                raise ValueError("Expected exactly one Proxy and Rule section")
            candidate = candidate.replace(section + "\n", section + "\n" + COMMENT + "\n" + "\n".join(lines) + "\n", 1)
    else:
        metadata = json.loads(record.read_text())
        if metadata.get("profile") != str(profile) or metadata.get("port") != args.port or metadata.get("schema") != 1:
            raise ValueError("Session ownership metadata does not match")
    if args.action == "plan":
        print(json.dumps({"action": "plan", "ownedEntries": 3, "otherProfileEntriesPreserved": True}))
        return
    if args.action == "apply":
        with socket.create_connection(("127.0.0.1", args.port), timeout=2):
            pass
        state.mkdir(mode=0o700, parents=True, exist_ok=False)
    elif state.stat().st_mode & 0o077:
        raise ValueError("Session state permissions are not private")
    # Check a private candidate before touching the active profile.
    check = state / ("candidate-" + args.action + "-" + next(tempfile._get_candidate_names()) + ".conf")
    private_write(check, candidate.encode())
    checked([CLI, "--check", str(check)])
    if profile.read_bytes() != before:
        raise ValueError("Profile changed concurrently; nothing was written")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    private_write(state / ("before-" + args.action + "-" + stamp + ".conf"), before)
    if args.action == "apply":
        private_write(record, json.dumps({"schema": 1, "profile": str(profile), "port": args.port, "beforeSHA256": digest(before), "appliedSHA256": digest(candidate.encode())}).encode())
    descriptor, name = tempfile.mkstemp(prefix=".locationbridge-", dir=profile.parent)
    try:
        os.fchmod(descriptor, profile.stat().st_mode & 0o777)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(candidate.encode())
            stream.flush()
            os.fsync(stream.fileno())
        if profile.read_bytes() != before:
            raise ValueError("Profile changed concurrently; nothing was written")
        os.replace(name, profile)
        try:
            checked([CLI, "reload"])
        except ValueError as error:
            raise ValueError("Profile was written, but Surge reload failed; use restore with this same state directory") from error
    finally:
        if os.path.exists(name):
            os.unlink(name)
    print(json.dumps({"action": args.action, "otherProfileEntriesPreserved": True, "systemLocationVerified": False}))

if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, json.JSONDecodeError) as error:
        raise SystemExit(str(error))
