#!/usr/bin/env bash
# Run a fixed audio fixture through the real iPhone app and score the result.
#
# The debug build accepts `-duiyi.fixtureAudio <path>` and replaces only the
# microphone capturer; ASR, assembly, translation, captions, and persistence run
# unchanged. See docs/agents/device-testing.md.
#
# Requirements:
#   - Config/Local.xcconfig with DEVELOPMENT_TEAM and DEVICE_UDID
#   - a connected physical iPhone in Developer Mode, UI automation not required
#   - ffmpeg on the Mac (fixture derivation only)
#   - python3 for the mechanical score
#
# Usage:
#   tools/fixture-run.sh
#   tools/fixture-run.sh --run-id ted-1 --noise
#   tools/fixture-run.sh --start 511 --duration 785 --codec wav --pacing realtime
#   tools/fixture-run.sh --skip-build --run-id ted-2
#
# Evidence (marker, log, diagnostics, SwiftData store, score) is written to
# .device-state/fixture-runs/<run-id>/ and is not committed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_CONFIG="$ROOT/Config/Local.xcconfig"
BUNDLE_ID="${APP_BUNDLE_ID:-com.david.Duiyi}"
DERIVED_DATA="$ROOT/.device-state/fixture-derived"

RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
FIXTURE="$ROOT/docs/media/TED.mp3"
START=511
DURATION=785
CODEC="wav"
PACING="realtime"
SETTLE=12
NOISE=0
SKIP_BUILD=0
GROUND_TRUTH="$ROOT/tools/fixtures/ted-cue132-331.tsv"
MIN_COVERAGE="0.90"

usage() {
    cat <<'EOF'
Usage: tools/fixture-run.sh [options]

Options:
  --run-id <id>          Evidence directory name (default: UTC timestamp)
  --fixture <path>       Source audio (default: docs/media/TED.mp3)
  --start <seconds>      Fixture start (default: 511, 08:31)
  --duration <seconds>   Fixture duration (default: 785, 13:05)
  --codec wav|m4a        Device fixture format (default: wav)
  --pacing realtime|max  Fixture feed pacing (default: realtime)
  --settle <seconds>     Wait after EOF before ending the task (default: 12)
  --noise                Play speech on the Mac speakers during the run
  --ground-truth <path>  Cue TSV for scoring
  --min-coverage <0-1>   Fail below this source coverage (default: 0.90)
  --skip-build           Reuse the installed app and last build
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2 ;;
        --fixture) FIXTURE="$2"; shift 2 ;;
        --start) START="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --codec) CODEC="$2"; shift 2 ;;
        --pacing) PACING="$2"; shift 2 ;;
        --settle) SETTLE="$2"; shift 2 ;;
        --noise) NOISE=1; shift ;;
        --ground-truth) GROUND_TRUTH="$2"; shift 2 ;;
        --min-coverage) MIN_COVERAGE="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

config_value() {
    local key="$1"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([^/]*\).*/\1/p" "$LOCAL_CONFIG" \
        | head -n 1 | tr -d '[:space:]'
}

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

for tool in ffmpeg afinfo xcrun jq sqlite3 python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing required tool: %s\n' "$tool" >&2
        exit 1
    }
done
[[ -f "$FIXTURE" ]] || { printf 'Missing fixture: %s\n' "$FIXTURE" >&2; exit 1; }
[[ -f "$GROUND_TRUTH" ]] || { printf 'Missing ground truth: %s\n' "$GROUND_TRUTH" >&2; exit 1; }
if [[ "$CODEC" != "wav" && "$CODEC" != "m4a" ]]; then
    printf 'Unsupported --codec: %s\n' "$CODEC" >&2
    exit 2
fi

EVIDENCE="$ROOT/.device-state/fixture-runs/$RUN_ID"
mkdir -p "$EVIDENCE"
rm -f "$EVIDENCE/fixture-run-done.json" "$EVIDENCE/fixture-run.log"

FIXTURE_NAME="fixture-current.$CODEC"
FIXTURE_PATH="$EVIDENCE/$FIXTURE_NAME"

echo "== derive fixture =="
if [[ "$CODEC" == "wav" ]]; then
    ffmpeg -hide_banner -loglevel error \
        -ss "$START" -t "$DURATION" -i "$FIXTURE" \
        -ac 1 -ar 48000 -c:a pcm_s16le -y "$FIXTURE_PATH"
else
    ffmpeg -hide_banner -loglevel error \
        -ss "$START" -t "$DURATION" -i "$FIXTURE" \
        -ac 1 -ar 48000 -c:a aac -b:a 96k -y "$FIXTURE_PATH"
fi
afinfo "$FIXTURE_PATH" > "$EVIDENCE/fixture-info.txt"
shasum -a 256 "$FIXTURE_PATH" > "$EVIDENCE/fixture.sha256"
echo "fixture: $FIXTURE_PATH"
echo "sha256:  $(cut -d' ' -f1 "$EVIDENCE/fixture.sha256")"
echo "info:    $(grep -E 'Data format|estimated duration' "$EVIDENCE/fixture-info.txt" | tr '\n' ' ')"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "== build for device =="
    xcodebuild \
        -project "$ROOT/Duiyi.xcodeproj" \
        -scheme Duiyi \
        -configuration Debug \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -derivedDataPath "$DERIVED_DATA" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        -allowProvisioningUpdates \
        build > "$EVIDENCE/build.log" 2>&1
    echo "== install =="
    xcrun devicectl device install app \
        --device "$DEVICE_UDID" \
        "$DERIVED_DATA/Build/Products/Debug-iphoneos/Duiyi.app" \
        > "$EVIDENCE/install.log" 2>&1
else
    echo "== skip build/install =="
fi

echo "== push fixture =="
xcrun devicectl device copy to \
    --device "$DEVICE_UDID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source "$FIXTURE_PATH" \
    --destination "Documents/$FIXTURE_NAME" \
    > "$EVIDENCE/push.log" 2>&1

NOISE_PID=""
ORIG_VOL=""
cleanup() {
    if [[ -n "$NOISE_PID" ]]; then
        kill "$NOISE_PID" 2>/dev/null || true
        wait "$NOISE_PID" 2>/dev/null || true
    fi
    if [[ -n "$ORIG_VOL" ]]; then
        osascript -e "set volume output volume $ORIG_VOL" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [[ "$NOISE" -eq 1 ]]; then
    ORIG_VOL=$(osascript -e 'output volume of (get volume settings)')
    osascript -e 'set volume output volume 80'
    (while true; do
        say -v Samantha "The quick brown fox jumps over the lazy dog. This is room noise."
    done) >/dev/null 2>&1 &
    NOISE_PID=$!
    echo "== room noise on (Mac volume ${ORIG_VOL}->80) =="
fi

LAUNCH_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "== launch =="
echo "$LAUNCH_TS" > "$EVIDENCE/launch-ts.txt"
xcrun devicectl device process launch \
    --device "$DEVICE_UDID" \
    --terminate-existing \
    "$BUNDLE_ID" \
    -- \
    -duiyi.onboardingComplete YES \
    -duiyi.storeFile "fixture-$RUN_ID" \
    -duiyi.fixtureAudio "Documents/$FIXTURE_NAME" \
    -duiyi.fixturePacing "$PACING" \
    -duiyi.fixtureAutoRun YES \
    -duiyi.fixtureSettleSeconds "$SETTLE" \
    -duiyi.fixtureDeleteAfterRun YES \
    > "$EVIDENCE/launch.log" 2>&1

DEADLINE=$((SECONDS + DURATION + 300))
MARKER_READY=0
while [[ $SECONDS -lt $DEADLINE ]]; do
    xcrun devicectl device copy from \
        --device "$DEVICE_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source Documents/fixture-run.log \
        --destination "$EVIDENCE/fixture-run.log" >/dev/null 2>&1 || true
    xcrun devicectl device copy from \
        --device "$DEVICE_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source Documents/fixture-run-done.json \
        --destination "$EVIDENCE/fixture-run-done.json" >/dev/null 2>&1 || true
    if [[ -f "$EVIDENCE/fixture-run-done.json" ]]; then
        STARTED=$(jq -r '.startedAt // empty' "$EVIDENCE/fixture-run-done.json" 2>/dev/null || true)
        if [[ -n "$STARTED" ]] && { [[ "$STARTED" > "$LAUNCH_TS" ]] || [[ "$STARTED" == "$LAUNCH_TS" ]]; }; then
            MARKER_READY=1
            break
        fi
    fi
    sleep 10
done

if [[ "$MARKER_READY" -ne 1 ]]; then
    echo "ERROR: marker timeout; last log:" >&2
    tail -30 "$EVIDENCE/fixture-run.log" >&2 || true
    exit 1
fi

echo "== stop app =="
PID=$(xcrun devicectl device info processes --device "$DEVICE_UDID" 2>/dev/null \
    | awk '/Duiyi.app\/Duiyi/ {print $1; exit}')
if [[ -n "$PID" ]]; then
    xcrun devicectl device process terminate --device "$DEVICE_UDID" --pid "$PID" --kill \
        > "$EVIDENCE/terminate.log" 2>&1 || true
fi

echo "== pull evidence =="
DIAG=$(jq -r '.diagnosticsFile // empty' "$EVIDENCE/fixture-run-done.json")
if [[ -n "$DIAG" ]]; then
    xcrun devicectl device copy from \
        --device "$DEVICE_UDID" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "Documents/$DIAG" \
        --destination "$EVIDENCE/duiyi-diagnostics.json" >/dev/null 2>&1 || true
fi
xcrun devicectl device copy from \
    --device "$DEVICE_UDID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE_ID" \
    --source 'Library/Application Support/UITestStores' \
    --destination "$EVIDENCE/UITestStores" >/dev/null 2>&1 || true

STORE="$EVIDENCE/UITestStores/fixture-$RUN_ID.store"
if [[ ! -f "$STORE" ]]; then
    echo "ERROR: store not found: $STORE" >&2
    exit 1
fi

sqlite3 -header -separator $'\t' "$STORE" \
    "select ZSORTINDEX, ZISFINAL, ZSOURCETEXT, ZTRANSLATEDTEXT from ZTRANSCRIPTENTITY order by ZSORTINDEX;" \
    > "$EVIDENCE/transcript.tsv"

echo "== score =="
python3 -I "$ROOT/tools/fixture-score.py" \
    --store "$STORE" \
    --ground-truth "$GROUND_TRUTH" \
    --marker "$EVIDENCE/fixture-run-done.json" \
    --diagnostics "$EVIDENCE/duiyi-diagnostics.json" \
    --out "$EVIDENCE/score.json" >/dev/null

echo "== result =="
jq -r '
    "fixture:            \(.marker.fixture // "?") (\(.marker.pacing // "?"))",
    "listening:          \(.marker.listeningStarted // "?")",
    "end:                \(.marker.endOutcome // "?")",
    "mock/errors:        \(.marker.errors // [] | length)",
    "marker rows:        \(.marker.transcriptCount // "?") (source \(.marker.sourceNonEmptyCount // "?"), translated \(.marker.translatedCount // "?"))",
    "scored final rows:  \(.appFinalRows)",
    "capturer frames:    \(.marker.capturer.sentFrames // "?")",
    "coverage:           \(.sourceCoverage)",
    "exact match:        \(.exactMatchRate)",
    "WER:                \(.wordErrorRate)",
    "prefix duplicates:  \(.prefixDuplicatePairs)",
    "empty translations: \(.emptyTranslationRows)",
    "U+FFFD:             \(.replacementCharacters)",
    "cjk translations:   \(.cjkTranslationRows)",
    "settled / finals:   \(.diagnostics.summary.settledUtterances // "?") / \(.diagnostics.summary.finalJobCount // "?")",
    "final applied:      \(.diagnostics.summary.finalAppliedCount // "?")",
    "permanent failures: \(.diagnostics.summary.permanentFailureCount // "?")",
    "synthetic finals:   \(.diagnostics.syntheticFinals // "?")",
    "revision finals:    \(.diagnostics.revisionFinals // "?")",
    "apply rejects:      \(.diagnostics.applyRejects // {})",
    "final latency p95:  \(.diagnostics.finalLatencyP95Ms // "?") ms"
' "$EVIDENCE/score.json"

ERRORS=$(jq -r '.errors | length' "$EVIDENCE/fixture-run-done.json")
LISTENING=$(jq -r '.listeningStarted' "$EVIDENCE/fixture-run-done.json")
END=$(jq -r '.endOutcome' "$EVIDENCE/fixture-run-done.json")
ROWS=$(jq -r '.appFinalRows' "$EVIDENCE/score.json")
EMPTY=$(jq -r '.emptyTranslationRows' "$EVIDENCE/score.json")
BAD=$(jq -r '.replacementCharacters' "$EVIDENCE/score.json")
COVERAGE=$(jq -r '.sourceCoverage' "$EVIDENCE/score.json")

if [[ "$ERRORS" -ne 0 || "$LISTENING" != "true" || "$END" != "ended" || "$ROWS" -eq 0 || "$EMPTY" -ne 0 || "$BAD" -ne 0 ]]; then
    echo "FAIL: structural checks (errors=$ERRORS listening=$LISTENING end=$END rows=$ROWS empty=$EMPTY u+fffd=$BAD)" >&2
    exit 1
fi

if python3 -I -c "import sys; sys.exit(0 if float('$COVERAGE') >= float('$MIN_COVERAGE') else 1)"; then
    echo "PASS: evidence at $EVIDENCE"
    exit 0
else
    echo "PASS (structural), score below --min-coverage: evidence at $EVIDENCE" >&2
    exit 2
fi
