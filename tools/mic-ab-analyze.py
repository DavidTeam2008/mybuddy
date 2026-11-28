#!/usr/bin/env python3
"""Summarize real-microphone P1-1 preemption A/B evidence.

Reads only local evidence written by tools/mic-ab-run.sh:

  .device-state/mic-ab/runs/<run-id>/
    run-meta.json
    diagnostics.json
    store/<store>.store, -wal, -shm

The join key is the incumbent utterance ID in `speech.preemption` and the
SwiftData `ZTRANSCRIPTENTITY.ZID`. A retained row must exist in the store and
be final; a preview-only row is not retention.

Usage:
  tools/mic-ab-analyze.py [--runs-dir PATH] [--json PATH]
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path


def load_runs(runs_dir: Path) -> list[Path]:
    return sorted(
        path
        for path in runs_dir.iterdir()
        if path.is_dir()
        and (path / "run-meta.json").is_file()
        and (path / "diagnostics.json").is_file()
    )


LATIN = re.compile(r"[A-Za-z]")
CJK = re.compile(r"[぀-ヿ一-鿿]")


def read_store(run_dir: Path) -> tuple[dict[str, dict], int]:
    stores = sorted((run_dir / "store").glob("*.store"))
    if not stores:
        return {}, 0
    store = stores[0]
    uri = f"file:{store}?mode=ro"
    rows: dict[str, dict] = {}
    zids: list[str] = []
    with sqlite3.connect(uri, uri=True) as conn:
        try:
            cursor = conn.execute(
                "select hex(ZID), ZISFINAL, ZSOURCETEXT, ZTRANSLATEDTEXT "
                "from ZTRANSCRIPTENTITY order by ZSORTINDEX"
            )
        except sqlite3.DatabaseError as error:
            print(f"cannot read {store}: {error}", file=sys.stderr)
            return {}, 0
        for zid, is_final, source, translated in cursor:
            key = zid.upper()
            zids.append(key)
            rows[key] = {
                "isFinal": bool(is_final),
                "source": source or "",
                "translated": translated or "",
                "mixedScript": bool(
                    LATIN.search(source or "") and CJK.search(source or "")
                ),
            }
    duplicate_ids = sum(count - 1 for count in Counter(zids).values() if count > 1)
    return rows, duplicate_ids


def summarize_run(run_dir: Path) -> dict:
    meta = json.loads((run_dir / "run-meta.json").read_text())
    diagnostics = json.loads((run_dir / "diagnostics.json").read_text())
    rows, duplicate_ids = read_store(run_dir)
    events = diagnostics.get("events", [])
    preemptions = [event for event in events if event.get("kind") == "speech.preemption"]
    applied = [
        event
        for event in preemptions
        if event.get("applied") and event.get("incumbentVisible")
    ]
    unique_ids = {str(event.get("utteranceID", "")).upper() for event in applied}
    retained_final = 0
    retained_clean_final = 0
    retained_mixed_final = 0
    retained_preview = 0
    missing = 0
    queued = 0
    for event in applied:
        queued += 1 if event.get("queuedFinal") else 0
    for zid in unique_ids:
        row = rows.get(zid.replace("-", ""))
        if row is None:
            missing += 1
        elif row["isFinal"] and row["source"].strip():
            retained_final += 1
            if row["mixedScript"]:
                retained_mixed_final += 1
            else:
                retained_clean_final += 1
        else:
            retained_preview += 1

    empty_translations = sum(
        1
        for row in rows.values()
        if row["isFinal"] and not row["translated"].strip()
    )
    replacements = sum(
        row["translated"].count("�") for row in rows.values()
    )
    summary = diagnostics.get("summary", {})
    speech_starts = [e for e in events if e.get("kind") == "speech.start"]
    return {
        "runId": meta["runId"],
        "arm": meta["arm"],
        "module": meta["module"],
        "languages": meta["languages"],
        "preemptionPublish": meta["preemptionPublish"],
        "speechStarts": len(speech_starts),
        "usingDual": any(e.get("usingDual") for e in speech_starts),
        "preemptionEvents": len(preemptions),
        "appliedVisible": len(applied),
        "uniqueApplied": len(unique_ids),
        "queuedFinal": queued,
        "retainedFinal": retained_final,
        "retainedCleanFinal": retained_clean_final,
        "retainedMixedFinal": retained_mixed_final,
        "retainedPreview": retained_preview,
        "missingRow": missing,
        "duplicateIDs": duplicate_ids,
        "emptyFinalTranslations": empty_translations,
        "replacementCharacters": replacements,
        "transcriptRows": len(rows),
        "summary": {
            "asrResultCount": summary.get("asrResultCount", 0),
            "asrDropCount": summary.get("asrDropCount", 0),
            "settledUtterances": summary.get("settledUtterances", 0),
            "permanentFailureCount": summary.get("permanentFailureCount", 0),
            "finalAppliedCount": summary.get("finalAppliedCount", 0),
        },
    }


def aggregate(runs: list[dict]) -> dict:
    groups: dict[str, list[dict]] = defaultdict(list)
    for run in runs:
        key = f"{run['arm']}:{run['module']}:{run['languages']['user']}/{run['languages']['peer']}"
        groups[key].append(run)
    result = {}
    for key, group in sorted(groups.items()):
        applied = sum(run["appliedVisible"] for run in group)
        unique = sum(run["uniqueApplied"] for run in group)
        retained = sum(run["retainedFinal"] for run in group)
        clean = sum(run["retainedCleanFinal"] for run in group)
        mixed = sum(run["retainedMixedFinal"] for run in group)
        preview = sum(run["retainedPreview"] for run in group)
        missing = sum(run["missingRow"] for run in group)
        result[key] = {
            "runs": len(group),
            "appliedVisible": applied,
            "uniqueApplied": unique,
            "retainedFinal": retained,
            "retainedCleanFinal": clean,
            "retainedMixedFinal": mixed,
            "retainedPreview": preview,
            "missingRow": missing,
            "retentionRate": (retained / unique) if unique else None,
            "cleanRetentionRate": (clean / unique) if unique else None,
            "queuedFinal": sum(run["queuedFinal"] for run in group),
            "usingDualRuns": sum(1 for run in group if run["usingDual"]),
        }
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--runs-dir",
        type=Path,
        default=Path(".device-state/mic-ab/runs"),
    )
    parser.add_argument("--json", type=Path, default=None)
    args = parser.parse_args()

    if not args.runs_dir.is_dir():
        print(f"missing runs dir: {args.runs_dir}", file=sys.stderr)
        return 1

    runs = [summarize_run(path) for path in load_runs(args.runs_dir)]
    if not runs:
        print("no complete runs found", file=sys.stderr)
        return 1

    print(
        "run                         arm module       events unique final clean mixed "
        "preview missing queued rows dual"
    )
    for run in runs:
        print(
            f"{run['runId']:<27} {run['arm']:<3} {run['module']:<11} "
            f"{run['appliedVisible']:>6} {run['uniqueApplied']:>6} "
            f"{run['retainedFinal']:>5} {run['retainedCleanFinal']:>5} "
            f"{run['retainedMixedFinal']:>5} {run['retainedPreview']:>7} "
            f"{run['missingRow']:>7} {run['queuedFinal']:>6} "
            f"{run['transcriptRows']:>4} {str(run['usingDual']):>5}"
        )

    print("\naggregate")
    for key, value in aggregate(runs).items():
        retention = value["retentionRate"]
        clean = value["cleanRetentionRate"]
        retention_text = "n/a" if retention is None else f"{retention:.1%}"
        clean_text = "n/a" if clean is None else f"{clean:.1%}"
        print(
            f"  {key}: runs={value['runs']} events={value['appliedVisible']} "
            f"unique={value['uniqueApplied']} final={value['retainedFinal']} "
            f"clean={value['retainedCleanFinal']} mixed={value['retainedMixedFinal']} "
            f"preview={value['retainedPreview']} missing={value['missingRow']} "
            f"retention={retention_text} cleanRetention={clean_text} "
            f"queuedFinal={value['queuedFinal']} dualRuns={value['usingDualRuns']}"
        )

    payload = {"runs": runs, "aggregate": aggregate(runs)}
    if args.json:
        args.json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(f"\njson: {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
