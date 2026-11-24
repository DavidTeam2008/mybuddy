#!/usr/bin/env bash
# Build and run the Liquid Glass UI prototype on an iOS simulator.
#
# Usage:
#   tools/prototype-liquid-glass.sh [A|B|C] [home|f2f]
#   tools/prototype-liquid-glass.sh shots
#
# The app reads:
#   -liquidGlassPrototype -lgVariant <A|B|C> -lgScreen <home|f2f>
# Prototype code is DEBUG-only; it never ships in a Release build.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-/tmp/mybuddy-prototype-dd}"
BUNDLE_ID="com.david.Duiyi"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Duiyi.app"
SHOT_PREFIX="${SHOT_PREFIX:-/tmp/lg}"

pick_device() {
    xcrun simctl list devices available --json | python3 -c '
import json, sys

data = json.load(sys.stdin)
candidates = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS-" not in runtime:
        continue
    for device in devices:
        name = device.get("name", "")
        if not device.get("isAvailable") or not name.startswith("iPhone"):
            continue
        candidates.append((
            0 if device.get("state") == "Booted" else 1,
            0 if name == "iPhone 17 Pro Max" else 1,
            name,
            device["udid"],
        ))
candidates.sort()
print(candidates[0][3] if candidates else "")
'
}

DEVICE_ID="${SIMULATOR_ID:-$(pick_device)}"
if [[ -z "$DEVICE_ID" ]]; then
    echo "No available iPhone simulator; boot one or set SIMULATOR_ID." >&2
    exit 1
fi

build() {
    xcodebuild build \
        -project "$ROOT/Duiyi.xcodeproj" \
        -scheme Duiyi \
        -destination "platform=iOS Simulator,id=$DEVICE_ID" \
        -derivedDataPath "$DERIVED" \
        -quiet
}

prepare() {
    build
    xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
    xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null
    xcrun simctl install "$DEVICE_ID" "$APP"
    open -a Simulator 2>/dev/null \
        || open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null \
        || true
}

launch() {
    local variant="$1" screen="$2"
    xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" \
        -liquidGlassPrototype -lgVariant "$variant" -lgScreen "$screen" >/dev/null
}

if [[ "${1:-}" == "shots" ]]; then
    prepare
    for variant in A B C; do
        for screen in home f2f; do
            launch "$variant" "$screen"
            sleep 2
            xcrun simctl io "$DEVICE_ID" screenshot "$SHOT_PREFIX-$variant-$screen.png" >/dev/null
            echo "$SHOT_PREFIX-$variant-$screen.png"
        done
    done
    exit 0
fi

prepare
launch "${1:-A}" "${2:-home}"
printf 'Prototype launched: variant %s, screen %s\n' "${1:-A}" "${2:-home}"
