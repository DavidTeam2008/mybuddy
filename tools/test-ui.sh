#!/usr/bin/env bash
# Authoritative UI-test wrapper.
#
# Usage:
#   tools/test-ui.sh [--simulator <name-or-udid>]
#
# Environment overrides:
#   DERIVED_DATA_PATH, RESULT_BUNDLE_PATH, TEST_LOG_PATH
#
# Exit code is based on the xcresult summary, not xcodebuild's shell exit code.
# Failures and unexpected skips fail; the known simulator speech skip is allowed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/lib/xcode-test.sh
source "$ROOT/tools/lib/xcode-test.sh"

usage() {
    printf '%s\n' "Usage: tools/test-ui.sh [--simulator <name-or-udid>]"
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

run_tests "DuiyiUITests" "ui" "ui" "$requested"
