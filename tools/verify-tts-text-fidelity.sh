#!/usr/bin/env bash
# Bounded verification of settled TTS text fidelity.
#
# Compiles the real ClauseSplitter with its Domain dependency and checks that
# new meaning-bearing content reaches the synthesizer, no clause fabricates
# text, and a second consume speaks nothing new.
#
# Usage:
#   tools/verify-tts-text-fidelity.sh
#
# Exit codes: 0 = clean, 1 = fidelity violations, 2 = usage/toolchain/compile
# failure, 3 = modeling error.
# The expected baseline and how to read the output live in
# .claude/skills/verify-tts-text-fidelity/SKILL.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    printf '%s\n' "Usage: tools/verify-tts-text-fidelity.sh"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
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
    printf 'verify-tts-text-fidelity: xcrun not found; install Xcode command line tools.\n' >&2
    exit 2
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    printf 'verify-tts-text-fidelity: swiftc not found; install Xcode.\n' >&2
    exit 2
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mybuddy-tts-fidelity.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

SOURCES=(
    "$ROOT/Duiyi/Domain/Models/Clause.swift"
    "$ROOT/Duiyi/Domain/Models/AppLanguage.swift"
    "$ROOT/tools/verification/tts-text-fidelity/main.swift"
)

if ! xcrun swiftc -O -swift-version 6 -o "$BUILD_DIR/verify" "${SOURCES[@]}"; then
    printf 'verify-tts-text-fidelity: compile failed; restore the covered sources or fix the verifier.\n' >&2
    exit 2
fi

set +e
"$BUILD_DIR/verify"
status=$?
set -e

exit "$status"
