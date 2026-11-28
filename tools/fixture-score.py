#!/usr/bin/env python3
"""Score a device fixture run against known cue text.

The store is the app's SwiftData SQLite file pulled with devicectl. The
ground truth is a TSV of `milliseconds<TAB>text` cues for the fixture window.
Metrics are intentionally mechanical: token-level Levenshtein alignment for
source coverage, and structural checks for translations. Semantic translation
quality is a separate LLM/human review.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import unicodedata
from difflib import SequenceMatcher
from pathlib import Path

# A short cue is a sentence fragment the assembler must not lose while it is
# revising rows. Five tokens covers the fixture's short sentences without
# counting every clause.
SHORT_CUE_MAX_TOKENS = 5

CONTRACTIONS = {
    "i'm": "i am",
    "i've": "i have",
    "i'll": "i will",
    "i'd": "i would",
    "you're": "you are",
    "you've": "you have",
    "you'll": "you will",
    "you'd": "you would",
    "he's": "he is",
    "she's": "she is",
    "it's": "it is",
    "we're": "we are",
    "they're": "they are",
    "we've": "we have",
    "they've": "they have",
    "we'll": "we will",
    "they'll": "they will",
    "don't": "do not",
    "doesn't": "does not",
    "didn't": "did not",
    "isn't": "is not",
    "aren't": "are not",
    "wasn't": "was not",
    "weren't": "were not",
    "haven't": "have not",
    "hasn't": "has not",
    "hadn't": "had not",
    "won't": "will not",
    "wouldn't": "would not",
    "can't": "cannot",
    "couldn't": "could not",
    "shouldn't": "should not",
    "that's": "that is",
    "there's": "there is",
    "what's": "what is",
    "let's": "let us",
    "it'd": "it would",
}


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower().replace("’", "'")
    text = re.sub(r"\([^)]*\)", " ", text)
    for key, value in CONTRACTIONS.items():
        text = re.sub(r"\b" + re.escape(key) + r"\b", value, text)
    text = re.sub(r"[^\w\s']", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def tokenize(text: str) -> list[str]:
    normalized = normalize(text)
    return normalized.split() if normalized else []


def read_cues(path: Path) -> list[str]:
    cues: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        _, _, text = line.partition("\t")
        if not text:
            continue
        cleaned = re.sub(r"\([^)]*\)", " ", text).strip()
        if tokenize(cleaned):
            cues.append(cleaned)
    return cues


def contains_contiguous(haystack: list[str], needle: list[str]) -> bool:
    """Return whether `needle` appears as a contiguous token sequence."""
    if not needle:
        return True
    width = len(needle)
    return any(
        haystack[index : index + width] == needle
        for index in range(len(haystack) - width + 1)
    )


def short_cue_retention(
    cue_texts: list[str],
    app_tokens: list[str],
    max_tokens: int = SHORT_CUE_MAX_TOKENS,
) -> dict:
    """Check that every short ground-truth cue survives somewhere in the app text.

    Contiguous matching is deliberately strict: a cue whose words were dropped,
    reordered, or replaced by an ASR mishearing is counted as missing. Merging
    short cues into a longer row still passes because the app tokens are
    concatenated in row order.
    """
    short_cues = [
        cue for cue in cue_texts if 0 < len(tokenize(cue)) <= max_tokens
    ]
    missing = [
        cue for cue in short_cues if not contains_contiguous(app_tokens, tokenize(cue))
    ]
    found = len(short_cues) - len(missing)
    return {
        "shortCueMaxTokens": max_tokens,
        "shortCueTotal": len(short_cues),
        "shortCueFound": found,
        "shortCueRetention": found / len(short_cues) if short_cues else None,
        "missingShortCues": missing,
    }


def cue_retention(cues: list[str], app_tokens: list[str], prefix: str) -> dict:
    missing = [
        cue for cue in cues
        if not contains_contiguous(app_tokens, tokenize(cue))
    ]
    return {
        f"{prefix}Total": len(cues),
        f"{prefix}Found": len(cues) - len(missing),
        f"{prefix}Missing": missing,
        f"{prefix}Retention": (len(cues) - len(missing)) / len(cues)
        if cues
        else None,
    }


def required_cue_retention(required_cues: list[str], app_tokens: list[str]) -> dict:
    """Check named canary cues that must survive regardless of cue length."""
    return cue_retention(required_cues, app_tokens, "requiredCue")


def name_cue_retention(name_cues: list[str], app_tokens: list[str]) -> dict:
    """Non-blocking proper-name canaries; never used as a hard gate."""
    return cue_retention(name_cues, app_tokens, "nameCue")


def read_raw_asr_final_texts(path: Path) -> list[str]:
    """Read final ASR texts from the fixture-only JSONL dump.

    The dump is device-local evidence and is not part of the app transcript.
    Empty or malformed lines are ignored so a failed cleanup cannot crash the
    scorer.
    """
    texts: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict) or not record.get("isFinal"):
            continue
        text = record.get("text")
        if isinstance(text, str) and tokenize(text):
            texts.append(text)
    return texts


def token_similarity(left: str, right: str) -> float:
    return SequenceMatcher(None, left, right).ratio()


def near_contiguous_variant(
    cue_tokens: list[str],
    raw_tokens: list[str],
    threshold: float = 0.8,
) -> bool:
    """True when a same-length raw window is a near-spelling of the cue.

    Scattered cue words elsewhere in the transcript are not a surface variant:
    `white men perform better` must not be excused because `white`, `men`, and
    `perform better` occur in unrelated phrases.
    """
    width = len(cue_tokens)
    if width == 0 or len(raw_tokens) < width:
        return False
    for start in range(len(raw_tokens) - width + 1):
        if all(
            token_similarity(cue_tokens[index], raw_tokens[start + index])
            >= threshold
            for index in range(width)
        ):
            return True
    return False


def cue_attribution(
    cue: str,
    raw_tokens: list[str],
    raw_final_count: int,
) -> dict:
    """Classify a missing cue without guessing at ASR content.

    `assemblerLoss` is provable when the exact cue is present in raw final
    text but absent from the app transcript. `surfaceVariant` means every cue
    token has a near-spelling in raw (for example Russell/Rushell); otherwise
    the cue is an ASR miss. With no raw evidence the cue is unattributed.
    """
    cue_tokens = tokenize(cue)
    if not cue_tokens:
        return {"reason": "unattributed", "detail": "empty cue"}
    if raw_final_count == 0:
        return {"reason": "unattributed", "detail": "no raw ASR finals"}
    if contains_contiguous(raw_tokens, cue_tokens):
        return {
            "reason": "assemblerLoss",
            "detail": "exact cue present in raw ASR finals",
        }
    if near_contiguous_variant(cue_tokens, raw_tokens):
        return {
            "reason": "surfaceVariant",
            "detail": "a contiguous raw window is a near-spelling of the cue",
        }
    return {"reason": "asrMiss", "detail": "cue not found in raw ASR finals"}


def missing_cue_attribution(
    missing_required: list[str],
    missing_short: list[str],
    raw_texts: list[str] | None,
) -> dict:
    if raw_texts is None:
        return {
            "available": False,
            "reason": "no raw ASR dump; run with --dump-asr-text and --asr-raw",
            "rawFinalCount": 0,
            "items": [],
            "counts": {},
        }
    raw_tokens = [token for text in raw_texts for token in tokenize(text)]
    raw_final_count = len(raw_texts)
    items: list[dict] = []
    seen: set[str] = set()
    for source, cues in (("required", missing_required), ("short", missing_short)):
        for cue in cues:
            key = normalize(cue)
            if key in seen:
                continue
            seen.add(key)
            attribution = cue_attribution(cue, raw_tokens, raw_final_count)
            items.append({"cue": cue, "source": source, **attribution})
    counts: dict[str, int] = {}
    for item in items:
        counts[item["reason"]] = counts.get(item["reason"], 0) + 1
    return {
        "available": True,
        "rawFinalCount": raw_final_count,
        "items": items,
        "counts": counts,
    }


def read_store(path: Path) -> list[tuple[str, str, int]]:
    connection = sqlite3.connect(str(path))
    try:
        task = connection.execute(
            "select Z_PK from ZTASKENTITY order by ZSTARTEDAT desc limit 1"
        ).fetchone()
        if task is None:
            return []
        return connection.execute(
            "select ZSOURCETEXT, ZTRANSLATEDTEXT, ZISFINAL from ZTRANSCRIPTENTITY "
            "where ZTASK=? order by ZSORTINDEX",
            (task[0],),
        ).fetchall()
    finally:
        connection.close()


def levenshtein_counts(a: list[str], b: list[str]) -> tuple[int, int, int, int]:
    """Return (matches, substitutions, deletions, insertions)."""
    n, m = len(a), len(b)
    if n == 0:
        return 0, 0, 0, m
    if m == 0:
        return 0, 0, n, 0

    stride = m + 1
    directions = bytearray((n + 1) * stride)
    for j in range(1, m + 1):
        directions[j] = 2  # left: insertion
    for i in range(1, n + 1):
        directions[i * stride] = 1  # up: deletion

    previous = list(range(m + 1))
    for i in range(1, n + 1):
        current = [i] + [0] * m
        ai = a[i - 1]
        base = i * stride
        for j in range(1, m + 1):
            diagonal = previous[j - 1] + (0 if ai == b[j - 1] else 1)
            up = previous[j] + 1
            left = current[j - 1] + 1
            best = diagonal
            direction = 0
            if up < best:
                best = up
                direction = 1
            if left < best:
                best = left
                direction = 2
            current[j] = best
            directions[base + j] = direction
        previous = current

    i, j = n, m
    matches = substitutions = deletions = insertions = 0
    while i > 0 or j > 0:
        direction = directions[i * stride + j]
        if i > 0 and j > 0 and direction == 0:
            if a[i - 1] == b[j - 1]:
                matches += 1
            else:
                substitutions += 1
            i -= 1
            j -= 1
        elif i > 0 and (j == 0 or direction == 1):
            deletions += 1
            i -= 1
        else:
            insertions += 1
            j -= 1
    return matches, substitutions, deletions, insertions


HIGHER_IS_BETTER = ("sourceCoverage", "exactMatchRate", "shortCueRetention")
LOWER_IS_BETTER = ("wordErrorRate",)


def baseline_regressions(result: dict, baseline: dict) -> list[dict]:
    """Return metrics that moved outside the committed baseline's tolerance."""
    metrics = baseline.get("metrics", {})
    tolerance = baseline.get("tolerance", {})
    regressions: list[dict] = []
    for metric, reference in metrics.items():
        if metric not in HIGHER_IS_BETTER and metric not in LOWER_IS_BETTER:
            raise ValueError(f"unknown baseline metric: {metric}")
        allowed_delta = float(tolerance.get(metric, 0.0))
        if allowed_delta < 0:
            raise ValueError(f"baseline tolerance must be non-negative: {metric}")
        current = result.get(metric)
        if current is None:
            regressions.append(
                {
                    "metric": metric,
                    "current": None,
                    "baseline": reference,
                    "allowed": None,
                }
            )
            continue
        if metric in HIGHER_IS_BETTER:
            allowed = float(reference) - allowed_delta
            if current < allowed:
                regressions.append(
                    {
                        "metric": metric,
                        "current": current,
                        "baseline": reference,
                        "allowed": allowed,
                    }
                )
        else:
            allowed = float(reference) + allowed_delta
            if current > allowed:
                regressions.append(
                    {
                        "metric": metric,
                        "current": current,
                        "baseline": reference,
                        "allowed": allowed,
                    }
                )
    return regressions


def diagnostics_metrics(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    events = data.get("events", [])
    asr = [event for event in events if event.get("kind") == "asr.result"]
    finals = [event for event in asr if event.get("isFinal")]
    applies = [event for event in events if event.get("kind") == "translation.apply"]
    final_applies = [event for event in applies if event.get("isFinal")]
    drops = [event for event in events if event.get("kind") == "asr.drop"]
    preemptions = [
        event for event in events if event.get("kind") == "speech.preemption"
    ]
    speech_starts = [
        event for event in events if event.get("kind") == "speech.start"
    ]
    drop_reasons: dict[str, int] = {}
    for event in drops:
        reason = event.get("dropReason") or "unknown"
        drop_reasons[reason] = drop_reasons.get(reason, 0) + 1
    latencies = sorted(
        event["latencyMilliseconds"]
        for event in final_applies
        if isinstance(event.get("latencyMilliseconds"), (int, float))
    )
    p95 = latencies[min(len(latencies) - 1, int(len(latencies) * 0.95))] if latencies else None
    rejected = {}
    for event in applies:
        applied = event.get("applied", event.get("accepted"))
        if applied is False:
            reason = event.get("reason") or "unknown"
            rejected[reason] = rejected.get(reason, 0) + 1
    return {
        "summary": data.get("summary"),
        "asrEvents": len(asr),
        "asrFinalEvents": len(finals),
        "syntheticFinals": sum(1 for event in finals if event.get("synthetic")),
        "revisionFinals": sum(1 for event in finals if event.get("revision")),
        "scriptMismatches": sum(1 for event in finals if event.get("scriptMismatch")),
        "applyEvents": len(applies),
        "finalApplyEvents": len(final_applies),
        "applyRejects": rejected,
        "finalLatencyP95Ms": p95,
        "finalLatencySamples": len(latencies),
        "asrDropEvents": len(drops),
        "asrDropReasons": drop_reasons,
        "preemptionEvents": len(preemptions),
        "preemptionApplied": sum(
            1 for event in preemptions if event.get("applied") is True
        ),
        "preemptionQueuedFinal": sum(
            1 for event in preemptions if event.get("queuedFinal") is True
        ),
        "speechStarts": [
            {
                "requested": event.get("requestedLanguages"),
                "active": event.get("activeLanguages"),
                "usingDual": event.get("usingDual"),
            }
            for event in speech_starts
        ],
    }


def score(
    store: Path,
    ground_truth: Path,
    marker: Path | None,
    diagnostics: Path | None,
    baseline: dict | None = None,
    asr_raw: Path | None = None,
) -> dict:
    short_cue_max_tokens = (
        int(baseline.get("shortCueMaxTokens", SHORT_CUE_MAX_TOKENS))
        if baseline is not None
        else SHORT_CUE_MAX_TOKENS
    )
    required_cues = baseline.get("requiredCues", []) if baseline is not None else []
    name_cues = baseline.get("nameCues", []) if baseline is not None else []
    rows = read_store(store)
    final_rows = [row for row in rows if row[2]]
    scored_rows = final_rows or rows
    source_texts = [row[0] or "" for row in scored_rows]
    translated = [row[1] or "" for row in scored_rows]

    cue_texts = read_cues(ground_truth)
    ground_tokens = [token for cue in cue_texts for token in tokenize(cue)]
    app_tokens = [
        token for text in source_texts for token in tokenize(text)
    ]
    matches, substitutions, deletions, insertions = levenshtein_counts(
        ground_tokens, app_tokens
    )
    ground_count = len(ground_tokens)

    normalized_sources = [normalize(text) for text in source_texts]
    prefix_duplicates = sum(
        1
        for first, second in zip(normalized_sources, normalized_sources[1:])
        if len(first.split()) >= 2 and second.startswith(first)
    )

    empty_translations = sum(
        1
        for source, target in zip(source_texts, translated)
        if source.strip() and not target.strip()
    )
    replacement_characters = sum(text.count("�") for text in translated)
    cjk_translations = sum(
        1 for text in translated if re.search(r"[一-鿿]", text)
    )

    short_retention = short_cue_retention(cue_texts, app_tokens, short_cue_max_tokens)
    required_retention = required_cue_retention(required_cues, app_tokens)
    name_retention = name_cue_retention(name_cues, app_tokens)

    result = {
        "schemaVersion": 1,
        "store": str(store),
        "groundTruth": str(ground_truth),
        "cueCount": len(cue_texts),
        "groundTruthTokens": ground_count,
        "appRows": len(rows),
        "appFinalRows": len(final_rows),
        "appTokens": len(app_tokens),
        "matches": matches,
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "sourceCoverage": (ground_count - deletions) / ground_count
        if ground_count
        else None,
        "exactMatchRate": matches / ground_count if ground_count else None,
        "wordErrorRate": (substitutions + deletions + insertions) / ground_count
        if ground_count
        else None,
        **short_retention,
        **required_retention,
        **name_retention,
        "prefixDuplicatePairs": prefix_duplicates,
        "emptyTranslationRows": empty_translations,
        "rowsWithoutTranslation": sum(
            1
            for source, target in zip(source_texts, translated)
            if source.strip() and not target.strip()
        ),
        "replacementCharacters": replacement_characters,
        "cjkTranslationRows": cjk_translations,
    }
    raw_texts = (
        read_raw_asr_final_texts(asr_raw)
        if asr_raw is not None and asr_raw.exists()
        else None
    )
    result["missingCueAttribution"] = missing_cue_attribution(
        required_retention["requiredCueMissing"],
        short_retention["missingShortCues"],
        raw_texts,
    )
    if marker and marker.exists():
        result["marker"] = json.loads(marker.read_text(encoding="utf-8"))
    if diagnostics and diagnostics.exists():
        result["diagnostics"] = diagnostics_metrics(diagnostics)
    if baseline is not None:
        result["baselineName"] = baseline.get("name")
        result["baselineRegressions"] = baseline_regressions(result, baseline)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", required=True, type=Path)
    parser.add_argument("--ground-truth", required=True, type=Path)
    parser.add_argument("--marker", type=Path)
    parser.add_argument("--diagnostics", type=Path)
    parser.add_argument("--asr-raw", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    baseline = (
        json.loads(args.baseline.read_text(encoding="utf-8"))
        if args.baseline
        else None
    )
    result = score(
        args.store,
        args.ground_truth,
        args.marker,
        args.diagnostics,
        baseline,
        args.asr_raw,
    )
    payload = json.dumps(result, indent=2, ensure_ascii=False)
    if args.out:
        args.out.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
