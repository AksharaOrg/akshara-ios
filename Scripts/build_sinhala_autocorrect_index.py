#!/usr/bin/env python3
"""Compile an Akshara Dictionary spelling export into the keyboard artifact.

The checked-in lock file pins the upstream revision. Release automation must
provide a generated `redistributable` export directory (with manifest.json,
sinhala-spelling.tsv, and optionally sinhala-frequency.tsv) from that revision.
This script deliberately never falls back to corpus word lists.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import unicodedata
from pathlib import Path

MAGIC = b"AKSHARA_AUTOCORRECT_V1\0"


def read_lock(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key] = value
    required = {"repository", "revision", "profile", "selection", "maximum_verified_words"}
    missing = required - values.keys()
    if missing:
        raise ValueError(f"lock file missing: {', '.join(sorted(missing))}")
    return values


def read_frequency(path: Path) -> dict[str, tuple[int, int]]:
    if not path.exists():
        return {}
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].split("\t") != ["normalized", "source", "raw_count", "rank"]:
        raise ValueError("unexpected sinhala-frequency.tsv header")
    result: dict[str, tuple[int, int]] = {}
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 4:
            raise ValueError(f"malformed frequency row: {line!r}")
        word = unicodedata.normalize("NFC", fields[0])
        try:
            rank = int(fields[3])
            if rank < 1:
                raise ValueError("frequency rank must be positive")
            # Smaller rank is more frequent; turn it into a stable positive score.
            score = max(1, 1_000_000 - rank)
            existing = result.get(word)
            if existing is None or rank < existing[0]:
                result[word] = (rank, score)
        except ValueError as error:
            raise ValueError(f"invalid frequency rank: {line!r}") from error
    return result


def verified_words(path: Path) -> list[str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].split("\t") != ["lemma", "status", "confidence", "tags"]:
        raise ValueError("unexpected sinhala-spelling.tsv header")
    words: set[str] = set()
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) != 4:
            raise ValueError(f"malformed spelling row: {line!r}")
        word, status, confidence, tags = fields
        word = unicodedata.normalize("NFC", word)
        if status != "accepted" or "verified" not in tags.split(","):
            continue
        if float(confidence) < 0.8:
            continue
        if not word or not all("\u0d80" <= scalar <= "\u0dff" for scalar in word):
            continue
        words.add(word)
    if not words:
        raise ValueError("the export has no accepted verified Sinhala spellings")
    return sorted(words)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--export-dir", type=Path, required=True)
    parser.add_argument("--lock", type=Path, default=Path(__file__).with_name("SinhalaDictionary.lock"))
    parser.add_argument("--output", type=Path, default=Path("AksharaKeyboard/Resources/SinhalaAutocorrect.lexicon"))
    parser.add_argument("--metadata", type=Path, default=Path("AksharaKeyboard/Resources/SinhalaAutocorrectMetadata.json"))
    parser.add_argument("--source-revision", required=True, help="Git commit that generated --export-dir")
    args = parser.parse_args()

    lock = read_lock(args.lock)
    if args.source_revision != lock["revision"]:
        raise ValueError("export revision does not match Scripts/SinhalaDictionary.lock")
    manifest_path = args.export_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("profile") != lock["profile"]:
        raise ValueError("export manifest is not the locked redistributable profile")

    verified = verified_words(args.export_dir / "sinhala-spelling.tsv")
    frequency = read_frequency(args.export_dir / "sinhala-frequency.tsv")
    if lock["selection"] != "lowest_frequency_rank":
        raise ValueError(f"unsupported dictionary selection rule: {lock['selection']}")
    try:
        limit = int(lock["maximum_verified_words"])
    except ValueError as error:
        raise ValueError("maximum_verified_words must be an integer") from error
    if limit < 1:
        raise ValueError("maximum_verified_words must be positive")
    ranked = [(frequency[word][0], word) for word in verified if word in frequency]
    if len(ranked) < limit:
        raise ValueError("the export has too few ranked verified Sinhala spellings")
    words = [word for _, word in sorted(ranked)[:limit]]
    payload = bytearray(MAGIC)
    payload.extend(struct.pack("<I", len(words)))
    for word in words:
        encoded = word.encode("utf-8")
        if len(encoded) > 65535:
            raise ValueError(f"word too long: {word!r}")
        payload.extend(struct.pack("<H", len(encoded)))
        payload.extend(encoded)
        payload.extend(struct.pack("<I", frequency[word][1]))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(payload)
    digest = hashlib.sha256(payload).hexdigest()
    metadata = {
        "format": "AKSHARA_AUTOCORRECT_V1",
        "repository": lock["repository"],
        "revision": lock["revision"],
        "profile": lock["profile"],
        "wordCount": len(words),
        "availableVerifiedWordCount": len(verified),
        "selection": {
            "kind": lock["selection"],
            "maximumVerifiedWords": limit,
        },
        "sha256": digest,
        "licence": manifest.get("licence"),
        "sources": manifest.get("sources", []),
    }
    args.metadata.write_text(json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {len(words)} verified words to {args.output} ({digest})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
