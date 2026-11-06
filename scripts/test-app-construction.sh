#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/locationbridge-construction.XXXXXX")"
trap 'rm -rf "$CHECK_DIRECTORY"' EXIT

swiftc -module-name LocationBridgeConstructionCheck \
    "$PROJECT_ROOT/Sources/LocationBridgeApp/MainWindowController.swift" \
    "$PROJECT_ROOT/Sources/LocationBridgeApp/CLIInvocation.swift" \
    "$PROJECT_ROOT/Sources/LocationBridgeApp/LocationValidation.swift" \
    "$PROJECT_ROOT/Tests/AppConstruction/main.swift" \
    -framework AppKit -framework CoreLocation \
    -o "$CHECK_DIRECTORY/app-construction-check"

python3 - "$CHECK_DIRECTORY/app-construction-check" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run([sys.argv[1]], timeout=20)
except subprocess.TimeoutExpired:
    print("App construction exceeded 20 seconds", file=sys.stderr)
    sys.exit(124)
sys.exit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
