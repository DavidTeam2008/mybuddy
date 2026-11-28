#!/usr/bin/env bash
# Authoritative unit-test wrapper.
#
# Runs the deterministic tooling tests first (fixture scorer), then DuiyiTests.
#
# Usage:
#   tools/test-unit.sh [--simulator <name-or-udid>]
#
# Environment overrides:
#   DERIVED_DATA_PATH, RESULT_BUNDLE_PATH, TEST_LOG_PATH
#
# Exit code is based on the xcresult summary, not xcodebuild's shell exit code.
# Unit tests must have zero failures and zero skips.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/lib/xcode-test.sh
source "$ROOT/tools/lib/xcode-test.sh"

usage() {
    printf '%s\n' "Usage: tools/test-unit.sh [--simulator <name-or-udid>]"
}

requested=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --simulator)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            requested="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
done

echo "==> tooling: fixture scorer tests"
python3 -I -m unittest discover -s "$ROOT/tools/tests" -p 'test_*.py'

run_tests "DuiyiTests" "unit" "strict" "$requested"
