#!/usr/bin/env bash
# Physical iPhone automation wrapper for agent-device.
#
# Configuration comes from Config/Local.xcconfig (gitignored):
#   DEVELOPMENT_TEAM = <team id>
#   DEVICE_UDID = <device udid>
# Copy Config/Local.xcconfig.example to get started.
#
# agent-device is pinned; the first run downloads it into the npx cache.
# The runner state lives in .device-state/ (gitignored) so sessions and the
# device claim stay stable across runs.
#
# Usage:
#   tools/device.sh check
#   tools/device.sh open [app-bundle-id]
#   tools/device.sh snapshot
#   tools/device.sh click <ref|selector>
#   tools/device.sh press <x> <y>
#   tools/device.sh wait <ms|text <text>|...>
#   tools/device.sh screenshot <path>
#   tools/device.sh close
#   tools/device.sh ui-tests
#   tools/device.sh agent <agent-device args...>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_CONFIG="$ROOT/Config/Local.xcconfig"
AGENT_DEVICE_VERSION="${AGENT_DEVICE_VERSION:-0.21.13}"
SESSION="${DEVICE_SESSION:-mybuddy-device}"
STATE_DIR="${AGENT_DEVICE_STATE_DIR:-$ROOT/.device-state}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.david.Duiyi}"
RUNNER_BUNDLE_ID="${AGENT_DEVICE_IOS_BUNDLE_ID:-com.david.agentdevice.runner}"
UI_RESULT_BUNDLE="$ROOT/.device-derived/DuiyiUITests.xcresult"

usage() {
    cat <<'EOF'
Usage:
  tools/device.sh check
  tools/device.sh open [app-bundle-id]
  tools/device.sh snapshot
  tools/device.sh click <ref|selector>
  tools/device.sh press <x> <y>
  tools/device.sh wait <ms|text <text>|...>
  tools/device.sh screenshot <path>
  tools/device.sh close
  tools/device.sh ui-tests
  tools/device.sh agent <agent-device args...>
EOF
}

config_value() {
    local key="$1"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([^/]*\).*/\1/p" "$LOCAL_CONFIG" \
        | head -n 1 | tr -d '[:space:]'
}

require_local_config() {
    if [[ ! -f "$LOCAL_CONFIG" ]]; then
        printf 'Missing %s\nCopy Config/Local.xcconfig.example and fill it in.\n' "$LOCAL_CONFIG" >&2
        exit 1
    fi
    TEAM_ID="$(config_value DEVELOPMENT_TEAM)"
    DEVICE_UDID="$(config_value DEVICE_UDID)"
    if [[ -z "$TEAM_ID" || -z "$DEVICE_UDID" ]]; then
        printf 'Config/Local.xcconfig must set DEVELOPMENT_TEAM and DEVICE_UDID.\n' >&2
        exit 1
    fi
}

agent() {
    AGENT_DEVICE_IOS_TEAM_ID="$TEAM_ID" \
    AGENT_DEVICE_STATE_DIR="$STATE_DIR" \
    AGENT_DEVICE_IOS_BUNDLE_ID="$RUNNER_BUNDLE_ID" \
    npx --yes "agent-device@$AGENT_DEVICE_VERSION" "$@"
}

check() {
    require_local_config
    local failed=0
    printf 'agent-device: %s (pinned)\n' "$AGENT_DEVICE_VERSION"
    printf 'team:         %s\n' "$TEAM_ID"
    printf 'device:       %s\n' "$DEVICE_UDID"
    printf 'state:        %s\n' "$STATE_DIR"
    printf 'session:      %s\n' "$SESSION"

    if ! DevToolsSecurity -status 2>&1 | grep -q 'enabled'; then
        printf 'FAIL: DevToolsSecurity is disabled (run: sudo DevToolsSecurity -enable).\n' >&2
        failed=1
    fi
    if pgrep -x Xcode >/dev/null; then
        printf 'WARN: Xcode is running; quit it before runner tests (code 74).\n' >&2
    fi
    if ! xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE_UDID"; then
        printf 'FAIL: device %s is not listed by devicectl.\n' "$DEVICE_UDID" >&2
        failed=1
    fi
    if ! xcrun xcdevice list 2>/dev/null | DEVICE_UDID="$DEVICE_UDID" python3 -c '
import json, os, sys

udid = os.environ["DEVICE_UDID"]
devices = json.load(sys.stdin)
match = [d for d in devices if d.get("identifier") == udid and not d.get("simulator")]
if not match:
    print("FAIL: device not found by xcdevice", file=sys.stderr)
    sys.exit(1)
interface = match[0].get("interface")
if interface != "usb":
    print("FAIL: device transport is", interface, "not usb", file=sys.stderr)
    sys.exit(1)
'; then
        failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
        printf 'check: FAIL\n' >&2
        exit 1
    fi
    printf 'check: PASS\n'
}

case "${1:-}" in
    check)
        check
        ;;
    open)
        shift
        require_local_config
        agent open "${1:-$APP_BUNDLE_ID}" --udid "$DEVICE_UDID" \
            --foreground --relaunch --session "$SESSION" --json
        ;;
    snapshot)
        require_local_config
        agent snapshot -i --session "$SESSION" --json
        ;;
    click)
        shift
        require_local_config
        [[ $# -ge 1 ]] || { usage; exit 2; }
        agent click "$1" --session "$SESSION" --settle --json
        ;;
    press)
        shift
        require_local_config
        [[ $# -ge 2 ]] || { usage; exit 2; }
        agent press "$1" "$2" --session "$SESSION" --settle --json
        ;;
    wait)
        shift
        require_local_config
        [[ $# -ge 1 ]] || { usage; exit 2; }
        agent wait "$@" --session "$SESSION"
        ;;
    screenshot)
        shift
        require_local_config
        [[ $# -ge 1 ]] || { usage; exit 2; }
        agent screenshot "$1" --session "$SESSION" --json
        ;;
    close)
        require_local_config
        agent close --session "$SESSION"
        ;;
    ui-tests)
        require_local_config
        mkdir -p "$(dirname "$UI_RESULT_BUNDLE")"
        rm -rf "$UI_RESULT_BUNDLE"
        xcodebuild test -project "$ROOT/Duiyi.xcodeproj" -scheme Duiyi \
            -destination "platform=iOS,id=$DEVICE_UDID" \
            -derivedDataPath "$ROOT/.device-derived" \
            DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates \
            -only-testing:DuiyiUITests -parallel-testing-enabled NO \
            -resultBundlePath "$UI_RESULT_BUNDLE"
        ;;
    agent)
        shift
        require_local_config
        agent "$@"
        ;;
    *)
        usage
        exit 2
        ;;
esac
