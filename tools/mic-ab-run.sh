#!/usr/bin/env bash
# Real-microphone P1-1 preemption A/B runner.
#
# This drives the DEBUG-only `-duiyi.micAB*` harness in the app. It does not
# inject fixture audio: the Mac plays a scripted WAV through its speakers and
# the iPhone microphone hears it. The app runs the real speech engine,
# assembler, translation, and SwiftData path.
#
# Usage:
#   tools/mic-ab-run.sh --run-id conv-ja-a-1 --arm a \
#     --module conversation --user-language english --peer-language japanese \
#     --audio .device-state/mic-ab/audio/p11-kana-6cycles.wav
#
#   tools/mic-ab-run.sh --run-id conv-ja-b-1 --arm b ...   # interleave A/B
#
# Evidence: .device-state/mic-ab/runs/<run-id>/ (gitignored). It contains the
# no-text diagnostics JSON, marker/log, and the isolated SwiftData store.
# Never commit the store or raw audio; the transcript is local evidence only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_CONFIG="$ROOT/Config/Local.xcconfig"
BUNDLE_ID="${BUNDLE_ID:-com.david.Duiyi}"
DERIVED_DATA="$ROOT/.device-derived"

RUN_ID=""
ARM=""
MODULE="conversation"
USER_LANGUAGE="english"
PEER_LANGUAGE="japanese"
AUDIO=""
DURATION=""
SKIP_BUILD=0

usage() {
    sed -n '2,22p' "$0"
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id) RUN_ID="${2:-}"; shift 2 ;;
        --arm) ARM="${2:-}"; shift 2 ;;
        --module) MODULE="${2:-}"; shift 2 ;;
        --user-language) USER_LANGUAGE="${2:-}"; shift 2 ;;
        --peer-language) PEER_LANGUAGE="${2:-}"; shift 2 ;;
        --audio) AUDIO="${2:-}"; shift 2 ;;
        --duration) DURATION="${2:-}"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[[ -n "$RUN_ID" ]] || { echo "--run-id is required" >&2; exit 2; }
[[ "$ARM" == "a" || "$ARM" == "b" ]] || { echo "--arm must be a or b" >&2; exit 2; }
[[ "$MODULE" == "conversation" || "$MODULE" == "meeting" ]] || {
    echo "--module must be conversation or meeting" >&2; exit 2
}
[[ -f "$AUDIO" ]] || { echo "--audio must be an existing file" >&2; exit 2; }

if [[ ! -f "$LOCAL_CONFIG" ]]; then
    echo "Missing $LOCAL_CONFIG" >&2
    exit 1
fi
config_value() {
    sed -n "s/^[[:space:]]*${1}[[:space:]]*=[[:space:]]*\([^/]*\).*/\1/p" "$LOCAL_CONFIG" \
        | head -n 1 | tr -d '[:space:]'
}
TEAM_ID="$(config_value DEVELOPMENT_TEAM)"
DEVICE_UDID="$(config_value DEVICE_UDID)"
[[ -n "$TEAM_ID" && -n "$DEVICE_UDID" ]] || {
    echo "Config/Local.xcconfig must set DEVELOPMENT_TEAM and DEVICE_UDID" >&2
    exit 1
}

if [[ -z "$DURATION" ]]; then
    DURATION="$(afinfo "$AUDIO" | awk '/estimated duration/ {print int($3) + 8; exit}')"
fi

EVIDENCE="$ROOT/.device-state/mic-ab/runs/$RUN_ID"
rm -rf "$EVIDENCE"
mkdir -p "$EVIDENCE/store"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "== build/install =="
    xcodebuild \
        -project "$ROOT/Duiyi.xcodeproj" \
        -scheme Duiyi \
        -configuration Debug \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -derivedDataPath "$DERIVED_DATA" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        -allowProvisioningUpdates \
        build > "$EVIDENCE/build.log" 2>&1
    xcrun devicectl device install app --device "$DEVICE_UDID" \
        "$DERIVED_DATA/Build/Products/Debug-iphoneos/Duiyi.app" \
        > "$EVIDENCE/install.log" 2>&1
fi

PUBLISH="no"
[[ "$ARM" == "b" ]] && PUBLISH="yes"
STORE_FILE="micab-$RUN_ID"

ORIG_VOL="$(osascript -e 'output volume of (get volume settings)')"
cleanup() {
    osascript -e "set volume output volume $ORIG_VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT
osascript -e 'set volume output volume 85' >/dev/null

printf '{}\n' > "$EVIDENCE/stale-marker.json"
for marker in mic-ab-ready.json mic-ab-done.json; do
    xcrun devicectl device copy to \
        --device "$DEVICE_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "$EVIDENCE/stale-marker.json" \
        --destination "Documents/$marker" >/dev/null 2>&1 || true
done

echo "== launch ($ARM, $MODULE, $USER_LANGUAGE/$PEER_LANGUAGE) =="
launch_app() {
    xcrun devicectl device process launch \
        --device "$DEVICE_UDID" \
        --terminate-existing \
        "$BUNDLE_ID" \
        -- \
        -duiyi.onboardingComplete YES \
        -duiyi.storeFile "$STORE_FILE" \
        -duiyi.prefsSuite "micab-$RUN_ID" \
        -duiyi.micABModule "$MODULE" \
        -duiyi.micABUserLanguage "$USER_LANGUAGE" \
        -duiyi.micABPeerLanguage "$PEER_LANGUAGE" \
        -duiyi.micABDuration "$DURATION" \
        -duiyi.assemblerPreemptionPublish "$PUBLISH" \
        > "$EVIDENCE/launch.log" 2>&1
}
if ! launch_app; then
    # The previous run's process can still be terminating; devicectl reports
    # 10004 even though the app is launchable a moment later.
    if grep -q '10004' "$EVIDENCE/launch.log"; then
        sleep 2
        launch_app || true
    fi
fi

READY="$EVIDENCE/ready.json"
READY_DEADLINE=$((SECONDS + 90))
while [[ $SECONDS -lt $READY_DEADLINE ]]; do
    if xcrun devicectl device copy from \
        --device "$DEVICE_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source Documents/mic-ab-ready.json \
        --destination "$READY" >/dev/null 2>&1; then
        if grep -q "\"preemptionPublish\" : $([[ "$PUBLISH" == "yes" ]] && echo true || echo false)" "$READY"; then
            break
        fi
    fi
    sleep 2
done
if [[ ! -s "$READY" ]]; then
    echo "app did not become ready; see $EVIDENCE/launch.log" >&2
    exit 1
fi
echo "ready: $(cat "$READY")"

echo "== play $AUDIO =="
afplay "$AUDIO"
echo "playback done"

DONE="$EVIDENCE/done.json"
DONE_DEADLINE=$((SECONDS + DURATION + 90))
while [[ $SECONDS -lt $DONE_DEADLINE ]]; do
    if xcrun devicectl device copy from \
        --device "$DEVICE_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source Documents/mic-ab-done.json \
        --destination "$DONE" >/dev/null 2>&1; then
        if grep -q "\"preemptionPublish\" : $([[ "$PUBLISH" == "yes" ]] && echo true || echo false)" "$DONE"; then
            break
        fi
    fi
    sleep 2
done
if [[ ! -s "$DONE" ]]; then
    echo "app did not finish; see $EVIDENCE" >&2
    exit 1
fi
cat "$DONE"

DIAGNOSTICS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["diagnosticsFile"])' "$DONE")"
xcrun devicectl device copy from \
    --device "$DEVICE_UDID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "Documents/$DIAGNOSTICS" \
    --destination "$EVIDENCE/diagnostics.json" >/dev/null
xcrun devicectl device copy from \
    --device "$DEVICE_UDID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source Documents/mic-ab.log \
    --destination "$EVIDENCE/mic-ab.log" >/dev/null 2>&1 || true

for suffix in "" "-wal" "-shm"; do
    xcrun devicectl device copy from \
        --device "$DEVICE_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "Library/Application Support/UITestStores/$STORE_FILE.store$suffix" \
        --destination "$EVIDENCE/store/$STORE_FILE.store$suffix" >/dev/null 2>&1 || true
done

python3 - "$EVIDENCE/run-meta.json" <<PY
import hashlib, json, subprocess, sys
from pathlib import Path
root = Path("$ROOT")
audio = Path("$AUDIO")
meta = {
    "schemaVersion": 1,
    "runId": "$RUN_ID",
    "arm": "$ARM",
    "module": "$MODULE",
    "languages": {"user": "$USER_LANGUAGE", "peer": "$PEER_LANGUAGE"},
    "preemptionPublish": "$PUBLISH" == "yes",
    "durationSeconds": float("$DURATION"),
    "audio": {
        "path": str(audio),
        "sha256": hashlib.sha256(audio.read_bytes()).hexdigest(),
        "durationSeconds": float(subprocess.check_output(
            ["afinfo", str(audio)], text=True
        ).split("estimated duration:")[1].split("sec")[0].strip()),
    },
    "commit": subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
    ).strip(),
    "dirty": bool(subprocess.check_output(
        ["git", "-C", str(root), "status", "--porcelain"], text=True
    ).strip()),
    "device": "physical-iPhone13",
}
Path(sys.argv[1]).write_text(json.dumps(meta, indent=2, sort_keys=True) + "\\n")
PY
echo "evidence: $EVIDENCE"
