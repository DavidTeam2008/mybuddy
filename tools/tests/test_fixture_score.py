"""Tests for the device fixture scorer.

Run with:
    python3 -I -m unittest discover -s tools/tests -p 'test_*.py'
"""

from __future__ import annotations

import importlib.util
import sqlite3
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("fixture_score", ROOT / "tools" / "fixture-score.py")
assert SPEC is not None and SPEC.loader is not None
fixture_score = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture_score)


def make_store(directory: Path, rows: list[tuple[str, str, int]]) -> Path:
    store = directory / "fixture.store"
    connection = sqlite3.connect(store)
    try:
        connection.executescript(
            """
            create table ZTASKENTITY (
                Z_PK integer primary key,
                ZSTARTEDAT timestamp
            );
            create table ZTRANSCRIPTENTITY (
                Z_PK integer primary key,
                ZTASK integer,
                ZSORTINDEX integer,
                ZSOURCETEXT text,
                ZTRANSLATEDTEXT text,
                ZISFINAL integer
            );
            """
        )
        connection.execute(
            "insert into ZTASKENTITY (Z_PK, ZSTARTEDAT) values (1, 0)"
        )
        connection.executemany(
            "insert into ZTRANSCRIPTENTITY "
            "(ZTASK, ZSORTINDEX, ZSOURCETEXT, ZTRANSLATEDTEXT, ZISFINAL) "
            "values (1, ?, ?, ?, ?)",
            [
                (index, source, translation, is_final)
                for index, (source, translation, is_final) in enumerate(rows)
            ],
        )
        connection.commit()
    finally:
        connection.close()
    return store


class ShortCueRetentionTests(unittest.TestCase):
    def test_short_cues_are_counted_and_missing_cues_are_named(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            ground_truth = directory / "cues.tsv"
            ground_truth.write_text(
                "\n".join(
                    [
                        "0\tShe'll perform better.",
                        "1000\twhite men perform better.",
                        "2000\tThis deliberately long cue has more than five words in it.",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            store = make_store(
                directory,
                [
                    (
                        "She'll perform better. Lead them to believe it's diagnostic.",
                        "她会表现得更好。引导他们相信这是诊断性的。",
                        1,
                    ),
                    (
                        "Lead them to believe it's diagnostic of natural athletic ability.",
                        "引导他们相信这是对自然运动能力的诊断。",
                        1,
                    ),
                ],
            )

            result = fixture_score.score(store, ground_truth, None, None)

            self.assertEqual(result["shortCueTotal"], 2)
            self.assertEqual(result["shortCueFound"], 1)
            self.assertEqual(result["shortCueRetention"], 0.5)
            self.assertEqual(result["missingShortCues"], ["white men perform better."])


class RequiredCueTests(unittest.TestCase):
    def test_required_cues_are_checked_independently_of_short_cues(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            ground_truth = directory / "cues.tsv"
            ground_truth.write_text(
                "0\tShe'll perform better.\n1000\tFor four days, silence.\n",
                encoding="utf-8",
            )
            store = make_store(
                directory,
                [
                    (
                        "She'll perform better. Lead them to believe it's diagnostic.",
                        "她会表现得更好。",
                        1,
                    ),
                ],
            )
            baseline = {
                "requiredCues": [
                    "She'll perform better.",
                    "For four days, silence.",
                ]
            }

            result = fixture_score.score(
                store, ground_truth, None, None, baseline=baseline
            )

            self.assertEqual(result["requiredCueTotal"], 2)
            self.assertEqual(result["requiredCueFound"], 1)
            self.assertEqual(
                result["requiredCueMissing"],
                ["For four days, silence."],
            )


class BaselineRegressionTests(unittest.TestCase):
    def test_regressions_outside_tolerance_are_reported(self) -> None:
        result = {
            "sourceCoverage": 0.90,
            "exactMatchRate": 0.97,
            "wordErrorRate": 0.11,
            "shortCueRetention": 0.90,
        }
        baseline = {
            "metrics": {
                "sourceCoverage": 0.98,
                "exactMatchRate": 0.975,
                "wordErrorRate": 0.026,
                "shortCueRetention": 0.933,
            },
            "tolerance": {
                "sourceCoverage": 0.01,
                "exactMatchRate": 0.01,
                "wordErrorRate": 0.01,
                "shortCueRetention": 0.02,
            },
        }

        regressions = fixture_score.baseline_regressions(result, baseline)

        self.assertEqual(
            [regression["metric"] for regression in regressions],
            ["sourceCoverage", "wordErrorRate", "shortCueRetention"],
        )

    def test_values_inside_tolerance_pass(self) -> None:
        result = {
            "sourceCoverage": 0.975,
            "exactMatchRate": 0.97,
            "wordErrorRate": 0.03,
            "shortCueRetention": 0.93,
        }
        baseline = {
            "metrics": {
                "sourceCoverage": 0.98,
                "exactMatchRate": 0.975,
                "wordErrorRate": 0.026,
                "shortCueRetention": 0.933,
            },
            "tolerance": {
                "sourceCoverage": 0.01,
                "exactMatchRate": 0.01,
                "wordErrorRate": 0.01,
                "shortCueRetention": 0.02,
            },
        }

        self.assertEqual(
            fixture_score.baseline_regressions(result, baseline),
            [],
        )


if __name__ == "__main__":
    unittest.main()
