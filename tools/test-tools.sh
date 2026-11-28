#!/usr/bin/env bash
# Deterministic tests for repository tooling. No third-party dependencies.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 -I -m unittest discover -s "$ROOT/tools/tests" -p 'test_*.py'
