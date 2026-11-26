#!/usr/bin/env bash
# Bounded exhaustive verification of the D8 utterance-identity promise.
#
# Compiles the real UtteranceAssembler with its Domain dependencies and replays
# every event sequence up to the depth bound. No simulator, no mock assembler,
# no third-party dependency.
#
# Usage:
#   tools/verify-utterance-identity.sh [--depth N]
#
# Environment override:
#   UTTERANCE_VERIFY_DEPTH   default 5
#
# Exit codes: 0 = clean, 1 = identity violations, 2 = usage/toolchain/compile
# failure, 3 = modeling error.
# The expected baseline and how to read the output live in
# .claude/skills/verify-utterance-identity/SKILL.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPTH="${UTTERANCE_VERIFY_DEPTH:-5}"

usage() {
    printf '%s\n' "Usage: tools/verify-utterance-identity.sh [--depth N]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --depth)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            DEPTH="$2"
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

if ! command -v xcrun >/dev/null 2>&1; then
    printf 'verify-utterance-identity: xcrun not found; install Xcode command line tools.\n' >&2
    exit 2
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    printf 'verify-utterance-identity: swiftc not found; install Xcode.\n' >&2
    exit 2
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mybuddy-utterance-identity.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

SOURCES=(
    "$ROOT/Duiyi/Domain/Models/Utterance.swift"
    "$ROOT/Duiyi/Domain/Models/AppLanguage.swift"
    "$ROOT/Duiyi/Domain/Models/ScriptCounts.swift"
    "$ROOT/Duiyi/Domain/Models/SpokenText.swift"
    "$ROOT/Duiyi/Services/DuiyiLog.swift"
    "$ROOT/Duiyi/Services/Speech/UtteranceAssembler.swift"
    "$ROOT/tools/verification/utterance-identity/main.swift"
)

if ! xcrun swiftc -O -swift-version 6 -o "$BUILD_DIR/verify" "${SOURCES[@]}"; then
    printf 'verify-utterance-identity: compile failed; restore the covered sources or fix the verifier.\n' >&2
    exit 2
fi

set +e
"$BUILD_DIR/verify" --depth "$DEPTH"
status=$?
set -e

exit "$status"
