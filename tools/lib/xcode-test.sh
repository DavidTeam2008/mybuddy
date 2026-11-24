#!/usr/bin/env bash
# Shared helpers for tools/test-unit.sh and tools/test-ui.sh.
# Source this file; do not run it directly.
#
# Behavior:
# - picks an available iPhone simulator, preferring booted iOS 26.4 devices;
# - boots it and falls back to another simulator on Busy/preflight/data-migration failures;
# - runs xcodebuild with a result bundle and parses the xcresult summary;
# - prints logical and expanded test counts (Swift Testing parameterized cases);
# - unit mode rejects every skip; UI mode allows only the known simulator speech skip.

set -euo pipefail

_test_repo_root() {
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$lib_dir/../.." && pwd
}

_test_simulator_rows() {
    xcrun simctl list devices available --json | python3 -c '
import json
import sys

data = json.load(sys.stdin)
preferred = {"iPhone 17 Pro Max": 0, "iPhone 17e": 1, "iPhone Air": 2}
rows = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS-" not in runtime:
        continue
    if "iOS-26-4" in runtime:
        runtime_rank = 0
    elif "iOS-26-" in runtime:
        runtime_rank = 1
    elif "iOS-27-" in runtime:
        runtime_rank = 2
    else:
        runtime_rank = 3
    for device in devices:
        name = device.get("name", "")
        if not device.get("isAvailable") or not name.startswith("iPhone"):
            continue
        state = device.get("state", "")
        rows.append((
            runtime_rank,
            0 if state == "Booted" else 1,
            preferred.get(name, 3),
            name,
            device["udid"],
            state,
        ))
for runtime_rank, state_rank, name_rank, name, udid, state in sorted(rows):
    print(f"{udid}\t{name}\t{state}")
'
}

_test_candidate_rows() {
    local requested="${1:-}"
    if [[ -n "$requested" ]]; then
        local rows
        rows="$(_test_simulator_rows | awk -F '\t' -v q="$requested" '
            $1 == q || $2 == q { print; found = 1 }
            END { if (!found) exit 1 }
        ')" || {
            echo "No available simulator matches '$requested'." >&2
            return 1
        }
        printf '%s\n' "$rows"
    else
        _test_simulator_rows
    fi
}

_test_summary_check() {
    local result="$1"
    local mode="$2"
    python3 - "$result" "$mode" <<'PY'
import json
import subprocess
import sys

result_path, mode = sys.argv[1], sys.argv[2]

def xcresult(*args):
    return subprocess.check_output(
        ["xcrun", "xcresulttool", *args, "--path", result_path, "--format", "json"],
        text=True,
        stderr=subprocess.DEVNULL,
    )

try:
    summary = json.loads(xcresult("get", "test-results", "summary"))
except Exception as error:
    print(f"could not read xcresult summary: {error}", file=sys.stderr)
    sys.exit(1)

expanded = sum(
    item.get("passedTests", 0)
    for item in summary.get("devicesAndConfigurations", [])
)
if not expanded:
    expanded = summary.get("passedTests", 0)
logical = summary.get("totalTestCount", summary.get("passedTests", 0))
failed = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
expected = summary.get("expectedFailures", 0)
print(
    f"    result={summary.get('result')} logical={logical} "
    f"expanded={expanded} failed={failed} skipped={skipped}"
)

if summary.get("result") != "Passed" or failed or expected:
    sys.exit(1)
if skipped == 0:
    sys.exit(0)
if mode != "ui":
    print("    skipped tests are not allowed in the unit suite", file=sys.stderr)
    sys.exit(1)

try:
    tests = json.loads(xcresult("get", "test-results", "tests"))
except Exception as error:
    print(f"could not read xcresult tests: {error}", file=sys.stderr)
    sys.exit(1)

skipped_nodes = []
def walk(node):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case" and node.get("result") == "Skipped":
            skipped_nodes.append(node.get("nodeIdentifier") or node.get("name") or "<unknown>")
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)

walk(tests)
skipped_nodes = sorted(set(skipped_nodes))
print("    skipped: " + (", ".join(skipped_nodes) or "<unknown>"))
allowed = "SimultaneousFlowTests/testSimultaneousListeningPressure"
if not skipped_nodes or any(allowed not in node for node in skipped_nodes):
    print(
        "    only the known simulator speech skip is allowed in the UI suite",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

_test_failure_is_crash_only() {
    local result="$1"
    python3 - "$result" <<'PY'
import json
import subprocess
import sys

result_path = sys.argv[1]
try:
    output = subprocess.check_output(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            result_path,
            "--format",
            "json",
        ],
        text=True,
        stderr=subprocess.DEVNULL,
    )
    summary = json.loads(output)
except Exception:
    sys.exit(1)

failures = summary.get("testFailures", [])
if summary.get("failedTests") != 1 or len(failures) != 1:
    sys.exit(1)
text = failures[0].get("failureText", "")
sys.exit(0 if "crashed with signal" in text else 1)
PY
}

run_tests() {
    local target="$1"
    local label="$2"
    local mode="$3"
    local requested="${4:-}"
    local root derived result log
    root="$(_test_repo_root)"
    derived="${DERIVED_DATA_PATH:-/tmp/mybuddy-${label}-$$-dd}"
    result="${RESULT_BUNDLE_PATH:-/tmp/mybuddy-${label}-$$}.xcresult"
    log="${TEST_LOG_PATH:-/tmp/mybuddy-${label}-$$}.log"
    mkdir -p "$(dirname "$result")" "$(dirname "$log")"

    local rows
    if ! rows="$(_test_candidate_rows "$requested")"; then
        return 1
    fi
    local crashed_once=0

    while IFS=$'\t' read -r udid name state; do
        [[ -z "${udid:-}" ]] && continue
        echo "==> $label: trying $name ($udid, $state)"
        if ! xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1; then
            echo "    bootstatus failed; trying next simulator" >&2
            continue
        fi

        rm -rf "$result" "$log"
        echo "==> $label: xcodebuild test -only-testing:$target"
        echo "    log: $log"
        local status=0
        xcodebuild test \
            -project "$root/Duiyi.xcodeproj" \
            -scheme Duiyi \
            -destination "platform=iOS Simulator,id=$udid" \
            -derivedDataPath "$derived" \
            -only-testing:"$target" \
            -parallel-testing-enabled NO \
            -resultBundlePath "$result" \
            -quiet >"$log" 2>&1 || status=$?

        if [[ ! -d "$result" ]]; then
            echo "    xcodebuild exit $status and no result bundle; tail:" >&2
            tail -40 "$log" >&2 || true
            if grep -qiE 'Busy|preflight|Data Migration|Unable to boot|Failed to boot|not available' "$log"; then
                echo "    simulator/runner problem; trying next simulator" >&2
                continue
            fi
            return 1
        fi

        if _test_summary_check "$result" "$mode"; then
            echo "==> $label: PASS"
            echo "    xcresult: $result"
            return 0
        fi

        if [[ "$mode" == "ui" && "$crashed_once" -eq 0 ]] && _test_failure_is_crash_only "$result"; then
            echo "    UI runner crashed once; retrying on the next simulator" >&2
            crashed_once=1
            continue
        fi

        echo "==> $label: FAIL" >&2
        echo "    xcresult: $result" >&2
        tail -20 "$log" >&2 || true
        return 1
    done <<< "$rows"

    echo "No simulator completed the $label suite." >&2
    return 1
}
