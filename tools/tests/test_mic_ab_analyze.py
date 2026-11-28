"""Tests for the real-microphone preemption A/B analyzer.

Run with:
    python3 -I -m unittest discover -s tools/tests -p 'test_*.py'
"""

from __future__ import annotations

import importlib.util
import json
import sqlite3
import tempfile
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "mic_ab_analyze", ROOT / "tools" / "mic-ab-analyze.py"
)
assert SPEC is not None and SPEC.loader is not None
mic_ab_analyze = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mic_ab_analyze)


def make_run(directory: Path, rows: list[tuple[uuid.UUID, str, bool, str]]) -> Path:
    run = directory / "run"
    store_dir = run / "store"
    store_dir.mkdir(parents=True)
    (run / "run-meta.json").write_text(
        json.dumps(
            {
                "runId": "test-run",
                "arm": "b",
                "module": "conversation",
                "languages": {"user": "english", "peer": "japanese"},
                "preemptionPublish": True,
            }
        )
    )
    (run / "diagnostics.json").write_text(
        json.dumps(
            {
                "events": [
                    {"kind": "speech.start", "usingDual": True},
                    {
                        "kind": "speech.preemption",
                        "utteranceID": str(rows[0][0]),
                        "applied": True,
                        "incumbentVisible": True,
                        "queuedFinal": True,
                    },
                ],
                "summary": {"permanentFailureCount": 0},
            }
        )
    )
    connection = sqlite3.connect(store_dir / "test.store")
    try:
        connection.execute(
            "create table ZTRANSCRIPTENTITY ("
            "ZID blob, ZISFINAL integer, ZSOURCETEXT text, "
            "ZTRANSLATEDTEXT text, ZSORTINDEX integer)"
        )
        connection.executemany(
            "insert into ZTRANSCRIPTENTITY values (?, ?, ?, ?, ?)",
            [
                (row_id.bytes, int(is_final), source, translated, index)
                for index, (row_id, source, is_final, translated) in enumerate(rows)
            ],
        )
        connection.commit()
    finally:
        connection.close()
    return run


class MicABAnalyzeTests(unittest.TestCase):
    def test_joins_incumbent_to_a_clean_final_row(self) -> None:
        incumbent = uuid.UUID("2e73464c-99a9-4c6b-83aa-69b78ce715a8")
        with tempfile.TemporaryDirectory() as temporary:
            run = make_run(
                Path(temporary),
                [(incumbent, "They also cause", True, "他们也会导致")],
            )
            summary = mic_ab_analyze.summarize_run(run)

        self.assertEqual(summary["appliedVisible"], 1)
        self.assertEqual(summary["uniqueApplied"], 1)
        self.assertEqual(summary["retainedFinal"], 1)
        self.assertEqual(summary["retainedCleanFinal"], 1)
        self.assertEqual(summary["retainedMixedFinal"], 0)
        self.assertEqual(summary["retainedPreview"], 0)
        self.assertEqual(summary["duplicateIDs"], 0)

    def test_counts_a_preview_as_not_retained(self) -> None:
        incumbent = uuid.UUID("0f9ecda8-5f27-4d2b-a948-4b5554bc5985")
        with tempfile.TemporaryDirectory() as temporary:
            run = make_run(
                Path(temporary),
                [(incumbent, "They also", False, "")],
            )
            summary = mic_ab_analyze.summarize_run(run)

        self.assertEqual(summary["retainedFinal"], 0)
        self.assertEqual(summary["retainedPreview"], 1)

    def test_mixed_script_final_is_not_clean_retention(self) -> None:
        incumbent = uuid.UUID("b9e02f0d-b6ed-414a-9538-078461b7b6f8")
        with tempfile.TemporaryDirectory() as temporary:
            run = make_run(
                Path(temporary),
                [(incumbent, "They alsoこれは生活です", True, "")],
            )
            summary = mic_ab_analyze.summarize_run(run)

        self.assertEqual(summary["retainedFinal"], 1)
        self.assertEqual(summary["retainedCleanFinal"], 0)
        self.assertEqual(summary["retainedMixedFinal"], 1)


if __name__ == "__main__":
    unittest.main()
