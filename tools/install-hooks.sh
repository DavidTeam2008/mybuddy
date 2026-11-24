#!/usr/bin/env bash
# Install the repository's committed git hooks and keep the tool scripts executable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$ROOT" config core.hooksPath .githooks
chmod +x \
    "$ROOT/.githooks/pre-commit" \
    "$ROOT/tools/check-static.sh" \
    "$ROOT/tools/test-unit.sh" \
    "$ROOT/tools/test-ui.sh"
printf 'Installed hooks from .githooks\n'
